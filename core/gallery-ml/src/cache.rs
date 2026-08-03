//! `gallery-cache.sqlite` — the derived-data store.
//!
//! Everything in here is recomputable and is never treated as truth (overview
//! standing decision 1). Deleting the file costs a re-run, not data: the
//! durable output is the sidecar.
//!
//! # Schema
//!
//! ```sql
//! CREATE TABLE meta       (key TEXT PRIMARY KEY, value TEXT NOT NULL);
//! CREATE TABLE ml_work    (path TEXT PRIMARY KEY, content_hash BLOB,
//!                          state INTEGER NOT NULL, model_pack TEXT,
//!                          error_code INTEGER NOT NULL DEFAULT 0,
//!                          retry_count INTEGER NOT NULL DEFAULT 0,
//!                          tag_count INTEGER NOT NULL DEFAULT 0,
//!                          updated_at INTEGER NOT NULL,
//!                          file_size INTEGER, file_mtime INTEGER,
//!                          decoder_version INTEGER);
//! CREATE TABLE embeddings (content_hash BLOB, model TEXT, dim INTEGER,
//!                          vec BLOB, PRIMARY KEY (content_hash, model));
//! ```
//!
//! **Deviation from the overview sketch**, deliberately: `ml_work` is keyed by
//! `path`, not by `content_hash`. The overview's own state machine has a
//! `hashing` state, which only means anything if a row can exist *before* its
//! hash does — and `enqueue(paths)` is handed paths, not hashes. Two copies of
//! the same photo also need two rows: each has its own sidecar to write. The
//! content hash is still what the embedding cache is keyed by, which is where
//! it earns its keep — the second copy of a file gets a cache hit and never
//! runs inference.
//!
//! # Concurrency
//!
//! One `Connection` behind a mutex, WAL journaling, `NORMAL` synchronous. The
//! core is the single writer by design; worker threads contend for the lock
//! only at row boundaries (a hash lookup, a state update), never while
//! decoding or running inference.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use crate::error::{ErrorCode, MlResult};

/// Schema version stored in `meta`. Bump when [`MIGRATIONS`] grows.
pub const SCHEMA_VERSION: u32 = 2;

/// `meta` key holding the applied schema version.
pub const META_SCHEMA_VERSION: &str = "schema_version";

/// Ordered, append-only DDL. Index *n* takes the schema from version *n* to
/// *n + 1*, so a migration is added by pushing onto the end and bumping
/// [`SCHEMA_VERSION`] — never by editing an existing entry.
const MIGRATIONS: &[&str] = &[
    // 0 → 1
    r#"
    CREATE TABLE meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    CREATE TABLE ml_work (
        path         TEXT PRIMARY KEY,
        content_hash BLOB,
        state        INTEGER NOT NULL,
        model_pack   TEXT,
        error_code   INTEGER NOT NULL DEFAULT 0,
        retry_count  INTEGER NOT NULL DEFAULT 0,
        tag_count    INTEGER NOT NULL DEFAULT 0,
        updated_at   INTEGER NOT NULL
    );
    CREATE INDEX ml_work_state ON ml_work (state);
    CREATE INDEX ml_work_hash  ON ml_work (content_hash);
    CREATE TABLE embeddings (
        content_hash BLOB NOT NULL,
        model        TEXT NOT NULL,
        dim          INTEGER NOT NULL,
        vec          BLOB NOT NULL,
        PRIMARY KEY (content_hash, model)
    );
    "#,
    // 1 → 2: remember *what* a terminal row was decided about.
    //
    // `file_size`/`file_mtime` are stamped when a row goes `done`, so a later
    // run can notice an in-place edit with one stat per row and no hashing —
    // without them a file edited in place was never re-tagged (the row is
    // `done`, and `done` is not claimable).
    //
    // `decoder_version` is stamped when a row is `skipped`, so shipping a
    // decoder for a format v1 refuses re-opens those rows instead of leaving
    // them terminal for the life of the cache.
    r#"
    ALTER TABLE ml_work ADD COLUMN file_size       INTEGER;
    ALTER TABLE ml_work ADD COLUMN file_mtime      INTEGER;
    ALTER TABLE ml_work ADD COLUMN decoder_version INTEGER;
    "#,
];

/// Lifecycle of one photo in the work queue.
///
/// Discriminants are persisted, so they are append-only in the same way
/// [`ErrorCode`]'s are.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(i64)]
pub enum WorkState {
    /// Enqueued, nothing done yet.
    Pending = 0,
    /// Being hashed / processed right now. A row left here by an app kill is
    /// reclaimed as [`WorkState::Pending`] at the next [`CacheDb::open`].
    Hashing = 1,
    /// Tagged successfully under `model_pack`.
    Done = 2,
    /// Failed; see `error_code` and `retry_count`.
    Failed = 3,
    /// Was `Done`, but under a model pack that is no longer current.
    Stale = 4,
    /// Not an image format this build can decode. Not a failure — re-running
    /// will not help, and it must not show up in a "3 photos failed" summary.
    Skipped = 5,
}

impl WorkState {
    /// The persisted integer.
    pub fn as_i64(self) -> i64 {
        self as i64
    }

    /// Inverse of [`WorkState::as_i64`]; unknown values read as
    /// [`WorkState::Pending`] so a downgrade re-does work rather than losing it.
    pub fn from_i64(v: i64) -> WorkState {
        match v {
            1 => WorkState::Hashing,
            2 => WorkState::Done,
            3 => WorkState::Failed,
            4 => WorkState::Stale,
            5 => WorkState::Skipped,
            _ => WorkState::Pending,
        }
    }
}

/// Queue counts, as reported to the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// Rows waiting to be processed, including `stale` and retryable `failed`.
    pub pending: u64,
    /// Rows tagged under the current pack.
    pub done: u64,
    /// Rows that failed and are out of retries.
    pub failed: u64,
    /// Rows skipped as an unsupported format.
    pub skipped: u64,
    /// Rows that ended up with at least one tag written.
    pub tagged: u64,
}

/// The file identity a `done` row was decided against.
///
/// Recorded by [`CacheDb::finish_done`] and compared by the engine at the start
/// of every run: one `stat` per row, no hashing, and an in-place edit stops
/// being invisible.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoneRowStat {
    /// Absolute image path.
    pub path: String,
    /// Size in bytes at the time it was tagged.
    pub size: u64,
    /// Last-modified time in whole seconds, when the platform reported one.
    pub modified_unix: Option<i64>,
}

/// One row of the work queue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkItem {
    /// Absolute image path, as handed to [`CacheDb::enqueue`].
    pub path: String,
    /// SHA-256 of the file bytes, once computed.
    pub content_hash: Option<[u8; 32]>,
    /// Current state.
    pub state: WorkState,
    /// Pack version that produced the current result.
    pub model_pack: Option<String>,
    /// Last failure classification.
    pub error_code: ErrorCode,
    /// How many times this row has failed.
    pub retry_count: u32,
}

/// How many times a row is retried before it counts as permanently failed.
///
/// There is no time-based backoff: runs are user-initiated and the natural
/// spacing between them is the backoff. The counter exists so a systematically
/// bad file stops costing a full decode on every "Tag now".
pub const MAX_RETRIES: u32 = 3;

/// The cache database.
#[derive(Debug)]
pub struct CacheDb {
    conn: Mutex<Connection>,
}

impl CacheDb {
    /// Open (creating if needed) the cache DB at `path`, run migrations, and
    /// reclaim rows a previous process abandoned mid-flight.
    ///
    /// The path is caller-supplied with no default — same rule as Swift's
    /// `GalleryPaths` — so a missed injection fails loudly instead of writing
    /// somewhere plausible.
    pub fn open(path: impl AsRef<Path>) -> MlResult<CacheDb> {
        if let Some(parent) = path.as_ref().parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        let conn = Connection::open(path)?;
        Self::from_connection(conn)
    }

    /// An in-memory database. Tests only; nothing persists.
    pub fn open_in_memory() -> MlResult<CacheDb> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(conn: Connection) -> MlResult<CacheDb> {
        // `journal_mode` returns a row, so it needs `query_row`, not `execute`.
        let _: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;

        let db = CacheDb {
            conn: Mutex::new(conn),
        };
        db.migrate()?;
        db.reclaim_abandoned()?;
        Ok(db)
    }

    fn migrate(&self) -> MlResult<()> {
        let conn = self.lock();
        let current: u32 = conn
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                params![META_SCHEMA_VERSION],
                |r| r.get::<_, String>(0),
            )
            .optional()
            // A brand-new file has no `meta` table at all; that read fails with
            // "no such table", which is version 0 rather than an error.
            .unwrap_or(None)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);

        if current > SCHEMA_VERSION {
            // A newer build wrote this file. Refuse rather than corrupt it —
            // the caller can delete the cache, which costs only a re-run.
            return Err(crate::error::MlError::Cache {
                detail: format!("cache schema {current} is newer than {SCHEMA_VERSION}"),
            });
        }
        for sql in MIGRATIONS.iter().skip(current as usize) {
            conn.execute_batch(sql)?;
        }
        conn.execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![META_SCHEMA_VERSION, SCHEMA_VERSION.to_string()],
        )?;
        Ok(())
    }

    /// Release every `hashing` row back to `pending`.
    ///
    /// A `hashing` row can only exist because something died holding it: a
    /// killed process, or a worker thread that panicked mid-photo. Called at
    /// [`CacheDb::open`] **and** at the start of every run — the app holds one
    /// session for its whole lifetime, so "at open" alone stranded a row for
    /// the rest of the process.
    ///
    /// Safe to call between runs only: a run in flight owns its `hashing` rows.
    pub fn reclaim_abandoned(&self) -> MlResult<usize> {
        let conn = self.lock();
        Ok(conn.execute(
            "UPDATE ml_work SET state = ?1, updated_at = ?2 WHERE state = ?3",
            params![
                WorkState::Pending.as_i64(),
                now_unix(),
                WorkState::Hashing.as_i64()
            ],
        )?)
    }

    /// Re-open `skipped` rows decided by a different decoder generation.
    ///
    /// "Unsupported format" is a statement about *this build*, not about the
    /// file. Shipping a HEIC decoder must not require the user to find a
    /// "reset" button before a single HEIC gets tagged. Rows with no recorded
    /// version predate the column and are re-opened once, after which they
    /// carry `current` and settle.
    ///
    /// Returns how many rows were re-opened.
    pub fn reopen_skipped_for_decoder(&self, current: u32) -> MlResult<usize> {
        let conn = self.lock();
        Ok(conn.execute(
            "UPDATE ml_work SET state = ?1, error_code = 0, retry_count = 0, updated_at = ?2
             WHERE state = ?3 AND (decoder_version IS NULL OR decoder_version <> ?4)",
            params![
                WorkState::Pending.as_i64(),
                now_unix(),
                WorkState::Skipped.as_i64(),
                current as i64
            ],
        )?)
    }

    /// Every `done` row that recorded a stat, so a run can spot in-place edits.
    ///
    /// Rows written before the stat columns existed are **omitted**: there is
    /// no baseline to compare against, and re-tagging the whole library on a
    /// schema upgrade would be a worse answer than leaving them until the next
    /// real change.
    pub fn done_rows_with_stat(&self) -> MlResult<Vec<DoneRowStat>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT path, file_size, file_mtime FROM ml_work WHERE state = ?1
             AND file_size IS NOT NULL",
        )?;
        let rows = stmt.query_map(params![WorkState::Done.as_i64()], |r| {
            Ok(DoneRowStat {
                path: r.get(0)?,
                size: r.get::<_, i64>(1)?.max(0) as u64,
                modified_unix: r.get(2)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Demote one `done` row to `stale` because its bytes moved under us.
    pub fn mark_stale(&self, path: &str) -> MlResult<usize> {
        let conn = self.lock();
        Ok(conn.execute(
            "UPDATE ml_work SET state = ?1, updated_at = ?2 WHERE path = ?3 AND state = ?4",
            params![
                WorkState::Stale.as_i64(),
                now_unix(),
                path,
                WorkState::Done.as_i64()
            ],
        )?)
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Connection> {
        match self.conn.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Read a `meta` value.
    pub fn meta(&self, key: &str) -> MlResult<Option<String>> {
        Ok(self
            .lock()
            .query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// Write a `meta` value.
    pub fn set_meta(&self, key: &str, value: &str) -> MlResult<()> {
        self.lock().execute(
            "INSERT INTO meta (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// Add `paths` to the queue, idempotently, in one transaction.
    ///
    /// A path already present keeps its state — re-enqueuing a `done` photo
    /// must not re-tag it. Returns how many rows were newly inserted.
    pub fn enqueue(&self, paths: &[String]) -> MlResult<usize> {
        let mut conn = self.lock();
        let tx = conn.transaction()?;
        let now = now_unix();
        let mut inserted = 0usize;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO ml_work (path, state, updated_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(path) DO NOTHING",
            )?;
            for path in paths {
                inserted += stmt.execute(params![path, WorkState::Pending.as_i64(), now])?;
            }
        }
        tx.commit()?;
        Ok(inserted)
    }

    /// Mark every `done` row whose `model_pack` differs from `pack` as stale.
    ///
    /// "A pack upgrade marks affected `ml_work` rows stale rather than wiping
    /// them" (overview, model packs) — the embeddings stay, so a downgrade back
    /// to the old pack is nearly free.
    pub fn mark_stale_for_pack(&self, pack: &str) -> MlResult<usize> {
        let conn = self.lock();
        Ok(conn.execute(
            "UPDATE ml_work SET state = ?1, updated_at = ?2
             WHERE state = ?3 AND (model_pack IS NULL OR model_pack <> ?4)",
            params![
                WorkState::Stale.as_i64(),
                now_unix(),
                WorkState::Done.as_i64(),
                pack
            ],
        )?)
    }

    /// Paths that a run should process, oldest-enqueued first.
    ///
    /// Includes `pending`, `stale`, and `failed` rows that have retries left.
    /// `limit` of 0 means "everything".
    ///
    /// `root_prefix`, when given, restricts the result to paths under that
    /// directory. There is one cache DB per app, keyed by absolute path, so
    /// switching the library root leaves the old root's rows sitting `pending`
    /// forever — and processing them would tag files outside the library the
    /// user is looking at. Filtering *here* rather than failing them later is
    /// deliberate: an out-of-scope row is not a failure and must not burn a
    /// retry. It simply waits, in case the user switches back.
    pub fn claimable(&self, limit: usize, root_prefix: Option<&str>) -> MlResult<Vec<WorkItem>> {
        let conn = self.lock();
        // `substr(path, 1, length(?)) = ?` rather than LIKE/GLOB: both of those
        // give `%`, `_`, `[` and `*` meaning, and a library folder may contain
        // any of them.
        let sql = "SELECT path, content_hash, state, model_pack, error_code, retry_count
                   FROM ml_work
                   WHERE (state IN (?1, ?2) OR (state = ?3 AND retry_count < ?4))
                     AND (?6 IS NULL OR substr(path, 1, length(?6)) = ?6)
                   ORDER BY updated_at, path
                   LIMIT ?5";
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map(
            params![
                WorkState::Pending.as_i64(),
                WorkState::Stale.as_i64(),
                WorkState::Failed.as_i64(),
                MAX_RETRIES,
                if limit == 0 { -1i64 } else { limit as i64 },
                root_prefix,
            ],
            row_to_item,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// One row by path.
    pub fn item(&self, path: &str) -> MlResult<Option<WorkItem>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT path, content_hash, state, model_pack, error_code, retry_count
                 FROM ml_work WHERE path = ?1",
                params![path],
                row_to_item,
            )
            .optional()?)
    }

    /// Move a row to `hashing`, claiming it for this worker.
    ///
    /// Returns whether the claim succeeded. It fails when the row is no longer
    /// in a claimable state — the realistic case is
    /// [`CacheDb::reset_queue`] landing between `claimable` and here, after
    /// which the row either does not exist or is a *different*, freshly
    /// enqueued row. A worker that did not win the claim must do nothing at
    /// all: no decode, and above all no sidecar write on behalf of a row it
    /// does not own.
    pub fn begin(&self, path: &str) -> MlResult<bool> {
        let n = self.lock().execute(
            "UPDATE ml_work SET state = ?1, updated_at = ?2
             WHERE path = ?3 AND state IN (?4, ?5, ?6)",
            params![
                WorkState::Hashing.as_i64(),
                now_unix(),
                path,
                WorkState::Pending.as_i64(),
                WorkState::Stale.as_i64(),
                WorkState::Failed.as_i64()
            ],
        )?;
        Ok(n > 0)
    }

    /// Record the content hash of a row being processed.
    ///
    /// Returns whether the row is still ours; see [`CacheDb::begin`].
    pub fn set_content_hash(&self, path: &str, hash: &[u8; 32]) -> MlResult<bool> {
        let n = self.lock().execute(
            "UPDATE ml_work SET content_hash = ?1, updated_at = ?2
             WHERE path = ?3 AND state = ?4",
            params![
                hash.as_slice(),
                now_unix(),
                path,
                WorkState::Hashing.as_i64()
            ],
        )?;
        Ok(n > 0)
    }

    /// Mark a row tagged under `pack` with `tag_count` tags, clearing any
    /// previous failure and stamping the file stat the decision was made
    /// against (see [`CacheDb::done_rows_with_stat`]).
    ///
    /// Only a row this run still holds is written; returns whether one was.
    pub fn finish_done(
        &self,
        path: &str,
        pack: &str,
        tag_count: usize,
        stat: Option<(u64, Option<i64>)>,
    ) -> MlResult<bool> {
        let n = self.lock().execute(
            "UPDATE ml_work
             SET state = ?1, model_pack = ?2, tag_count = ?3, error_code = 0,
                 retry_count = 0, updated_at = ?4, file_size = ?6, file_mtime = ?7
             WHERE path = ?5 AND state = ?8",
            params![
                WorkState::Done.as_i64(),
                pack,
                tag_count as i64,
                now_unix(),
                path,
                stat.map(|(size, _)| size as i64),
                stat.and_then(|(_, mtime)| mtime),
                WorkState::Hashing.as_i64()
            ],
        )?;
        Ok(n > 0)
    }

    /// Mark a row failed, incrementing its retry counter.
    pub fn finish_failed(&self, path: &str, code: ErrorCode) -> MlResult<bool> {
        let n = self.lock().execute(
            "UPDATE ml_work
             SET state = ?1, error_code = ?2, retry_count = retry_count + 1, updated_at = ?3
             WHERE path = ?4 AND state = ?5",
            params![
                WorkState::Failed.as_i64(),
                code.as_i64(),
                now_unix(),
                path,
                WorkState::Hashing.as_i64()
            ],
        )?;
        Ok(n > 0)
    }

    /// Mark a row as a format this build does not handle, stamping the decoder
    /// generation that said so (see [`CacheDb::reopen_skipped_for_decoder`]).
    pub fn finish_skipped(&self, path: &str, decoder_version: u32) -> MlResult<bool> {
        let n = self.lock().execute(
            "UPDATE ml_work SET state = ?1, error_code = ?2, updated_at = ?3,
                 decoder_version = ?5
             WHERE path = ?4 AND state = ?6",
            params![
                WorkState::Skipped.as_i64(),
                ErrorCode::UnsupportedFormat.as_i64(),
                now_unix(),
                path,
                decoder_version as i64,
                WorkState::Hashing.as_i64()
            ],
        )?;
        Ok(n > 0)
    }

    /// Release a claimed row back to `pending` without counting a failure.
    /// Used when a run is cancelled with photos in flight.
    pub fn release(&self, path: &str) -> MlResult<()> {
        self.lock().execute(
            "UPDATE ml_work SET state = ?1, updated_at = ?2 WHERE path = ?3 AND state = ?4",
            params![
                WorkState::Pending.as_i64(),
                now_unix(),
                path,
                WorkState::Hashing.as_i64()
            ],
        )?;
        Ok(())
    }

    /// Cached embedding for `(content_hash, model)`.
    pub fn embedding(&self, hash: &[u8; 32], model: &str) -> MlResult<Option<Vec<f32>>> {
        let conn = self.lock();
        let row: Option<(i64, Vec<u8>)> = conn
            .query_row(
                "SELECT dim, vec FROM embeddings WHERE content_hash = ?1 AND model = ?2",
                params![hash.as_slice(), model],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((dim, bytes)) = row else {
            return Ok(None);
        };
        let dim = dim.max(0) as usize;
        if bytes.len() != dim * 4 {
            // A truncated blob is a corrupt cache entry, not a hard error:
            // report a miss and let the caller recompute over the top of it.
            return Ok(None);
        }
        Ok(Some(
            bytes
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect(),
        ))
    }

    /// Store an embedding, replacing any previous one for the same key.
    pub fn put_embedding(&self, hash: &[u8; 32], model: &str, vec: &[f32]) -> MlResult<()> {
        let mut bytes = Vec::with_capacity(vec.len() * 4);
        for v in vec {
            bytes.extend_from_slice(&v.to_le_bytes());
        }
        self.lock().execute(
            "INSERT INTO embeddings (content_hash, model, dim, vec) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(content_hash, model) DO UPDATE
             SET dim = excluded.dim, vec = excluded.vec",
            params![hash.as_slice(), model, vec.len() as i64, bytes],
        )?;
        Ok(())
    }

    /// Queue counts.
    pub fn stats(&self) -> MlResult<Stats> {
        let conn = self.lock();
        let mut stats = Stats::default();
        let mut stmt =
            conn.prepare("SELECT state, COUNT(*), SUM(tag_count > 0) FROM ml_work GROUP BY state")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                WorkState::from_i64(r.get(0)?),
                r.get::<_, i64>(1)? as u64,
                r.get::<_, Option<i64>>(2)?.unwrap_or(0) as u64,
            ))
        })?;
        for row in rows {
            let (state, count, tagged) = row?;
            match state {
                WorkState::Pending | WorkState::Hashing | WorkState::Stale => {
                    stats.pending += count
                }
                WorkState::Done => {
                    stats.done += count;
                    stats.tagged += tagged;
                }
                WorkState::Failed => stats.failed += count,
                WorkState::Skipped => stats.skipped += count,
            }
        }
        // A `failed` row with retries left is still work to do; count it in
        // both places so "pending" matches what a run would actually attempt.
        let retryable: u64 = conn.query_row(
            "SELECT COUNT(*) FROM ml_work WHERE state = ?1 AND retry_count < ?2",
            params![WorkState::Failed.as_i64(), MAX_RETRIES],
            |r| r.get::<_, i64>(0).map(|v| v as u64),
        )?;
        stats.pending += retryable;
        stats.failed -= retryable.min(stats.failed);
        Ok(stats)
    }

    /// Drop every queue row, keeping cached embeddings.
    ///
    /// This is "re-tag everything" without paying for inference again.
    pub fn reset_queue(&self) -> MlResult<()> {
        self.lock().execute("DELETE FROM ml_work", [])?;
        Ok(())
    }
}

fn row_to_item(r: &rusqlite::Row<'_>) -> rusqlite::Result<WorkItem> {
    let hash: Option<Vec<u8>> = r.get(1)?;
    Ok(WorkItem {
        path: r.get(0)?,
        content_hash: hash.and_then(|h| <[u8; 32]>::try_from(h.as_slice()).ok()),
        state: WorkState::from_i64(r.get(2)?),
        model_pack: r.get(3)?,
        error_code: ErrorCode::from_i64(r.get(4)?),
        retry_count: r.get::<_, i64>(5)?.max(0) as u32,
    })
}

/// Whole seconds since the Unix epoch; 0 if the clock is before 1970.
fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> CacheDb {
        CacheDb::open_in_memory().unwrap()
    }

    fn h(b: u8) -> [u8; 32] {
        [b; 32]
    }

    /// `begin` + `finish_done`, the transition a run actually performs. The
    /// terminal writes are state-predicated, so a test cannot jump straight to
    /// them any more — and should not: an unclaimed row reaching `done` is the
    /// bug the predicate exists to stop.
    fn claim_and_finish(db: &CacheDb, path: &str, pack: &str, tags: usize) {
        assert!(db.begin(path).unwrap(), "{path} was not claimable");
        assert!(db
            .finish_done(path, pack, tags, Some((10, Some(20))))
            .unwrap());
    }

    fn claim_and_fail(db: &CacheDb, path: &str, code: ErrorCode) {
        assert!(db.begin(path).unwrap(), "{path} was not claimable");
        assert!(db.finish_failed(path, code).unwrap());
    }

    fn claim_and_skip(db: &CacheDb, path: &str, decoder: u32) {
        assert!(db.begin(path).unwrap(), "{path} was not claimable");
        assert!(db.finish_skipped(path, decoder).unwrap());
    }

    fn claimable_paths(db: &CacheDb) -> Vec<String> {
        db.claimable(0, None)
            .unwrap()
            .into_iter()
            .map(|i| i.path)
            .collect()
    }

    #[test]
    fn open_records_the_schema_version() {
        let db = db();
        assert_eq!(
            db.meta(META_SCHEMA_VERSION).unwrap().as_deref(),
            Some(SCHEMA_VERSION.to_string().as_str())
        );
    }

    #[test]
    fn migrations_are_idempotent_across_reopens() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("gallery-cache.sqlite");
        {
            let db = CacheDb::open(&path).unwrap();
            db.enqueue(&["/a.jpg".into()]).unwrap();
        }
        let db = CacheDb::open(&path).unwrap();
        assert_eq!(db.stats().unwrap().pending, 1);
    }

    #[test]
    fn a_newer_schema_is_refused_rather_than_downgraded() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        {
            let db = CacheDb::open(&path).unwrap();
            db.set_meta(META_SCHEMA_VERSION, "999").unwrap();
        }
        assert!(CacheDb::open(&path).is_err());
    }

    /// A v1 file must gain the v2 columns and keep its rows.
    #[test]
    fn a_v1_cache_migrates_forward_without_losing_rows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        {
            // Hand-build the 0 → 1 schema, then claim it is at version 1.
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.execute_batch(MIGRATIONS[0]).unwrap();
            conn.execute(
                "INSERT INTO meta (key, value) VALUES (?1, '1')",
                params![META_SCHEMA_VERSION],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO ml_work (path, state, updated_at) VALUES ('/old.jpg', 2, 0)",
                [],
            )
            .unwrap();
        }
        let db = CacheDb::open(&path).unwrap();
        assert_eq!(
            db.meta(META_SCHEMA_VERSION).unwrap().as_deref(),
            Some(SCHEMA_VERSION.to_string().as_str())
        );
        assert_eq!(db.item("/old.jpg").unwrap().unwrap().state, WorkState::Done);
        // No recorded stat, so the re-stat pass has no baseline and leaves it.
        assert!(db.done_rows_with_stat().unwrap().is_empty());
    }

    #[test]
    fn enqueue_is_idempotent_and_preserves_state() {
        let db = db();
        assert_eq!(db.enqueue(&["/a.jpg".into(), "/b.jpg".into()]).unwrap(), 2);
        claim_and_finish(&db, "/a.jpg", "pack-1", 3);
        assert_eq!(db.enqueue(&["/a.jpg".into(), "/c.jpg".into()]).unwrap(), 1);
        assert_eq!(db.item("/a.jpg").unwrap().unwrap().state, WorkState::Done);
    }

    #[test]
    fn claimable_covers_pending_stale_and_retryable_failures() {
        let db = db();
        db.enqueue(&[
            "/pending.jpg".into(),
            "/done.jpg".into(),
            "/stale.jpg".into(),
            "/failed.jpg".into(),
            "/dead.jpg".into(),
            "/skipped.jpg".into(),
        ])
        .unwrap();
        claim_and_finish(&db, "/done.jpg", "pack-1", 1);
        claim_and_finish(&db, "/stale.jpg", "pack-0", 1);
        db.mark_stale_for_pack("pack-1").unwrap();
        claim_and_fail(&db, "/failed.jpg", ErrorCode::Decode);
        for _ in 1..MAX_RETRIES {
            claim_and_fail(&db, "/dead.jpg", ErrorCode::Decode);
        }
        claim_and_fail(&db, "/dead.jpg", ErrorCode::Decode);
        claim_and_skip(&db, "/skipped.jpg", 1);

        let paths = claimable_paths(&db);
        assert!(paths.contains(&"/pending.jpg".to_string()));
        assert!(paths.contains(&"/stale.jpg".to_string()));
        assert!(paths.contains(&"/failed.jpg".to_string()));
        assert!(!paths.contains(&"/done.jpg".to_string()));
        assert!(!paths.contains(&"/dead.jpg".to_string()));
        assert!(!paths.contains(&"/skipped.jpg".to_string()));
    }

    /// One cache DB serves every library the user ever picks. Rows belonging
    /// to a root that is not the current one must sit out the run — not fail,
    /// not burn a retry, and above all not get tagged.
    #[test]
    fn claimable_can_be_scoped_to_the_current_library_root() {
        let db = db();
        db.enqueue(&[
            "/Users/me/Photos/a.jpg".into(),
            "/Users/me/Photos/sub/b.jpg".into(),
            "/Users/me/Other/c.jpg".into(),
            // A sibling whose name merely *starts* with the root's name.
            "/Users/me/PhotosOld/d.jpg".into(),
        ])
        .unwrap();

        let scoped: Vec<String> = db
            .claimable(0, Some("/Users/me/Photos/"))
            .unwrap()
            .into_iter()
            .map(|i| i.path)
            .collect();
        assert_eq!(
            scoped,
            vec![
                "/Users/me/Photos/a.jpg".to_string(),
                "/Users/me/Photos/sub/b.jpg".to_string()
            ]
        );
        // Out-of-scope rows are untouched, not failed.
        for path in ["/Users/me/Other/c.jpg", "/Users/me/PhotosOld/d.jpg"] {
            let item = db.item(path).unwrap().unwrap();
            assert_eq!(item.state, WorkState::Pending);
            assert_eq!(item.retry_count, 0);
        }
        assert_eq!(
            claimable_paths(&db).len(),
            4,
            "unscoped still sees them all"
        );
    }

    /// Glob and LIKE metacharacters are legal in folder names.
    #[test]
    fn root_scoping_treats_the_prefix_as_literal_text() {
        let db = db();
        db.enqueue(&["/lib/100%_[a]/x.jpg".into(), "/lib/1000_ab/y.jpg".into()])
            .unwrap();
        let scoped: Vec<String> = db
            .claimable(0, Some("/lib/100%_[a]/"))
            .unwrap()
            .into_iter()
            .map(|i| i.path)
            .collect();
        assert_eq!(scoped, vec!["/lib/100%_[a]/x.jpg".to_string()]);
    }

    #[test]
    fn a_pack_change_stales_only_rows_from_other_packs() {
        let db = db();
        db.enqueue(&["/a.jpg".into(), "/b.jpg".into()]).unwrap();
        claim_and_finish(&db, "/a.jpg", "pack-1", 1);
        claim_and_finish(&db, "/b.jpg", "pack-2", 1);
        assert_eq!(db.mark_stale_for_pack("pack-1").unwrap(), 1);
        assert_eq!(db.item("/a.jpg").unwrap().unwrap().state, WorkState::Done);
        assert_eq!(db.item("/b.jpg").unwrap().unwrap().state, WorkState::Stale);
    }

    #[test]
    fn abandoned_hashing_rows_are_reclaimed_on_open() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.sqlite");
        {
            let db = CacheDb::open(&path).unwrap();
            db.enqueue(&["/a.jpg".into()]).unwrap();
            db.begin("/a.jpg").unwrap();
            assert_eq!(
                db.item("/a.jpg").unwrap().unwrap().state,
                WorkState::Hashing
            );
        }
        let db = CacheDb::open(&path).unwrap();
        assert_eq!(
            db.item("/a.jpg").unwrap().unwrap().state,
            WorkState::Pending
        );
    }

    #[test]
    fn reclaiming_is_available_between_runs_not_only_at_open() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        db.begin("/a.jpg").unwrap();
        assert_eq!(db.reclaim_abandoned().unwrap(), 1);
        assert_eq!(claimable_paths(&db), vec!["/a.jpg".to_string()]);
    }

    /// A row this run no longer owns must not be claimable *or* finishable.
    #[test]
    fn a_reset_between_claim_and_finish_loses_the_row() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        assert!(db.begin("/a.jpg").unwrap());

        // "Reset Tagging Data" mid-run, then the library is re-enqueued.
        db.reset_queue().unwrap();
        db.enqueue(&["/a.jpg".into()]).unwrap();

        // The in-flight worker's terminal writes must all miss: the row it
        // holds is gone, and the row that exists is a fresh, untouched one.
        assert!(!db.set_content_hash("/a.jpg", &h(3)).unwrap());
        assert!(!db.finish_done("/a.jpg", "p", 4, None).unwrap());
        assert!(!db.finish_failed("/a.jpg", ErrorCode::Io).unwrap());
        assert!(!db.finish_skipped("/a.jpg", 1).unwrap());

        let item = db.item("/a.jpg").unwrap().unwrap();
        assert_eq!(item.state, WorkState::Pending);
        assert_eq!(item.retry_count, 0);
        assert_eq!(item.content_hash, None);
    }

    #[test]
    fn a_second_claim_of_a_claimed_row_is_refused() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        assert!(db.begin("/a.jpg").unwrap());
        assert!(!db.begin("/a.jpg").unwrap());
    }

    #[test]
    fn a_done_row_records_the_stat_it_was_decided_against() {
        let db = db();
        db.enqueue(&["/a.jpg".into(), "/b.jpg".into()]).unwrap();
        db.begin("/a.jpg").unwrap();
        db.finish_done("/a.jpg", "p", 1, Some((4096, Some(1_700_000_000))))
            .unwrap();
        // A row finished with no stat available (the file vanished) records
        // nothing and stays out of the re-stat pass.
        db.begin("/b.jpg").unwrap();
        db.finish_done("/b.jpg", "p", 1, None).unwrap();

        assert_eq!(
            db.done_rows_with_stat().unwrap(),
            vec![DoneRowStat {
                path: "/a.jpg".to_string(),
                size: 4096,
                modified_unix: Some(1_700_000_000),
            }]
        );

        assert_eq!(db.mark_stale("/a.jpg").unwrap(), 1);
        assert_eq!(db.item("/a.jpg").unwrap().unwrap().state, WorkState::Stale);
        // `mark_stale` only demotes `done` rows.
        assert_eq!(db.mark_stale("/a.jpg").unwrap(), 0);
    }

    #[test]
    fn skipped_rows_reopen_when_the_decoder_generation_changes() {
        let db = db();
        db.enqueue(&["/a.heic".into()]).unwrap();
        claim_and_skip(&db, "/a.heic", 1);
        assert!(claimable_paths(&db).is_empty());

        // Same decoder: nothing to redo.
        assert_eq!(db.reopen_skipped_for_decoder(1).unwrap(), 0);
        assert!(claimable_paths(&db).is_empty());

        // A build that decodes more formats re-opens it, retry budget intact.
        assert_eq!(db.reopen_skipped_for_decoder(2).unwrap(), 1);
        assert_eq!(claimable_paths(&db), vec!["/a.heic".to_string()]);
        assert_eq!(db.item("/a.heic").unwrap().unwrap().retry_count, 0);
    }

    #[test]
    fn embeddings_round_trip_and_are_keyed_by_model() {
        let db = db();
        db.put_embedding(&h(1), "pack-1", &[1.0, -2.5, 3.25])
            .unwrap();
        assert_eq!(
            db.embedding(&h(1), "pack-1").unwrap(),
            Some(vec![1.0, -2.5, 3.25])
        );
        assert_eq!(db.embedding(&h(1), "pack-2").unwrap(), None);
        assert_eq!(db.embedding(&h(2), "pack-1").unwrap(), None);
        db.put_embedding(&h(1), "pack-1", &[9.0]).unwrap();
        assert_eq!(db.embedding(&h(1), "pack-1").unwrap(), Some(vec![9.0]));
    }

    #[test]
    fn stats_split_pending_done_failed_skipped_tagged() {
        let db = db();
        db.enqueue(&[
            "/a.jpg".into(),
            "/b.jpg".into(),
            "/c.jpg".into(),
            "/d.jpg".into(),
            "/e.jpg".into(),
        ])
        .unwrap();
        claim_and_finish(&db, "/a.jpg", "p", 2);
        claim_and_finish(&db, "/b.jpg", "p", 0);
        claim_and_skip(&db, "/c.jpg", 1);
        for _ in 0..MAX_RETRIES {
            claim_and_fail(&db, "/d.jpg", ErrorCode::Decode);
        }
        let s = db.stats().unwrap();
        assert_eq!(s.done, 2);
        assert_eq!(s.tagged, 1);
        assert_eq!(s.skipped, 1);
        assert_eq!(s.failed, 1);
        assert_eq!(s.pending, 1);
    }

    #[test]
    fn a_retryable_failure_counts_as_pending_not_failed() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        claim_and_fail(&db, "/a.jpg", ErrorCode::Io);
        let s = db.stats().unwrap();
        assert_eq!(s.pending, 1);
        assert_eq!(s.failed, 0);
    }

    #[test]
    fn release_only_touches_rows_this_run_claimed() {
        let db = db();
        db.enqueue(&["/a.jpg".into(), "/b.jpg".into()]).unwrap();
        db.begin("/a.jpg").unwrap();
        claim_and_finish(&db, "/b.jpg", "p", 1);
        db.release("/a.jpg").unwrap();
        db.release("/b.jpg").unwrap();
        assert_eq!(
            db.item("/a.jpg").unwrap().unwrap().state,
            WorkState::Pending
        );
        assert_eq!(db.item("/b.jpg").unwrap().unwrap().state, WorkState::Done);
    }

    #[test]
    fn a_corrupt_embedding_blob_reads_as_a_miss() {
        let db = db();
        {
            let conn = db.lock();
            conn.execute(
                "INSERT INTO embeddings (content_hash, model, dim, vec) VALUES (?1, ?2, ?3, ?4)",
                params![h(7).as_slice(), "p", 4i64, vec![0u8, 1, 2]],
            )
            .unwrap();
        }
        assert_eq!(db.embedding(&h(7), "p").unwrap(), None);
    }

    #[test]
    fn resetting_the_queue_keeps_embeddings() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        db.put_embedding(&h(1), "p", &[1.0]).unwrap();
        db.reset_queue().unwrap();
        assert_eq!(db.stats().unwrap().pending, 0);
        assert_eq!(db.embedding(&h(1), "p").unwrap(), Some(vec![1.0]));
    }

    #[test]
    fn work_states_round_trip() {
        for s in [
            WorkState::Pending,
            WorkState::Hashing,
            WorkState::Done,
            WorkState::Failed,
            WorkState::Stale,
            WorkState::Skipped,
        ] {
            assert_eq!(WorkState::from_i64(s.as_i64()), s);
        }
        assert_eq!(WorkState::from_i64(42), WorkState::Pending);
    }
}
