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
//! -- Phase 1
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
//! -- Phase 2
//! CREATE TABLE face_work  (… identical shape to ml_work, face_count instead
//!                          of tag_count …);
//! CREATE TABLE face_scans (content_hash BLOB, model TEXT, face_count INTEGER,
//!                          image_w INTEGER, image_h INTEGER,
//!                          PRIMARY KEY (content_hash, model));
//! CREATE TABLE faces      (content_hash BLOB, face_idx INTEGER, model TEXT,
//!                          bbox BLOB, landmarks BLOB, score REAL,
//!                          quality REAL, dim INTEGER, embedding BLOB,
//!                          image_w INTEGER, image_h INTEGER,
//!                          PRIMARY KEY (content_hash, face_idx));
//! CREATE TABLE clusters   (cluster_id INTEGER PRIMARY KEY, centroid BLOB,
//!                          dim INTEGER, size INTEGER, state INTEGER,
//!                          person_name TEXT, updated_at INTEGER);
//! CREATE TABLE cluster_members (content_hash BLOB, face_idx INTEGER,
//!                          cluster_id INTEGER,
//!                          PRIMARY KEY (content_hash, face_idx));
//! CREATE TABLE cluster_merge_proposals (a INTEGER, b INTEGER, similarity REAL,
//!                          proposed_at INTEGER, PRIMARY KEY (a, b));
//! ```
//!
//! **Deviation from the overview sketch**, deliberately: the work queues are
//! keyed by `path`, not by `content_hash`. The overview's own state machine has
//! a `hashing` state, which only means anything if a row can exist *before* its
//! hash does — and `enqueue(paths)` is handed paths, not hashes. Two copies of
//! the same photo also need two rows: each has its own sidecar to write. The
//! content hash is still what the *result* caches (`embeddings`, `faces`,
//! `face_scans`) are keyed by, which is where it earns its keep — the second
//! copy of a file gets a cache hit and never runs inference.
//!
//! # Two queues, one shape
//!
//! Tagging and faces are independent pipelines over the same library: a face
//! run must be resumable without regard to whether tagging is done, a pack that
//! ships no face models must leave `ml_work` alone, and a face-model swap must
//! not re-tag anything. So `face_work` is its own table with its own states,
//! retries and staleness — but *identical* mechanics, down to the
//! conditional-claim discipline. Rather than copy 300 lines of SQL with one
//! word changed, both are driven through [`Queue`], a compile-time constant
//! naming the table and its result-count column. Every SQL string is built from
//! `&'static str`s only; nothing user-supplied ever reaches `format!`.
//!
//! # Concurrency
//!
//! One `Connection` behind a mutex, WAL journaling, `NORMAL` synchronous. The
//! core is the single writer by design; worker threads contend for the lock
//! only at row boundaries (a hash lookup, a state update), never while
//! decoding or running inference.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, params_from_iter, Connection, OptionalExtension};

use crate::error::{ErrorCode, MlResult};

/// Schema version stored in `meta`. Bump when [`MIGRATIONS`] grows.
pub const SCHEMA_VERSION: u32 = 3;

/// `meta` key holding the applied schema version.
pub const META_SCHEMA_VERSION: &str = "schema_version";

/// `meta` key holding the face-model identity the `faces`/`clusters` rows were
/// produced under. A change invalidates every cluster (see
/// [`CacheDb::reset_face_results`]).
pub const META_FACE_PACK: &str = "face_pack";

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
    // 2 → 3: faces.
    //
    // `face_work` is `ml_work`'s shape with `face_count` in place of
    // `tag_count`; see the module docs for why it is a second table rather
    // than a second column.
    //
    // `face_scans` is to `faces` what a `done` row is to a sidecar: proof that
    // these bytes were *looked at* under this model. Without it a photo with no
    // faces is indistinguishable from a photo never processed, and every run
    // would re-detect every faceless photo in the library.
    //
    // Embeddings live in `faces` rather than in `embeddings`: at 512 f32 they
    // are 2 KB each, a handful per photo, and they are only ever read together
    // with the geometry they belong to.
    //
    // `cluster_members` is keyed by the face, not by the cluster: a face
    // belongs to at most one cluster, and that is the invariant the primary key
    // should be enforcing. `ON DELETE CASCADE` is deliberate — dropping a
    // cluster must not leave members pointing at nothing.
    r#"
    CREATE TABLE face_work (
        path            TEXT PRIMARY KEY,
        content_hash    BLOB,
        state           INTEGER NOT NULL,
        model_pack      TEXT,
        error_code      INTEGER NOT NULL DEFAULT 0,
        retry_count     INTEGER NOT NULL DEFAULT 0,
        face_count      INTEGER NOT NULL DEFAULT 0,
        updated_at      INTEGER NOT NULL,
        file_size       INTEGER,
        file_mtime      INTEGER,
        decoder_version INTEGER
    );
    CREATE INDEX face_work_state ON face_work (state);
    CREATE INDEX face_work_hash  ON face_work (content_hash);

    CREATE TABLE face_scans (
        content_hash BLOB NOT NULL,
        model        TEXT NOT NULL,
        face_count   INTEGER NOT NULL,
        image_w      INTEGER NOT NULL,
        image_h      INTEGER NOT NULL,
        PRIMARY KEY (content_hash, model)
    );

    CREATE TABLE faces (
        content_hash BLOB NOT NULL,
        face_idx     INTEGER NOT NULL,
        model        TEXT NOT NULL,
        bbox         BLOB NOT NULL,
        landmarks    BLOB NOT NULL,
        score        REAL NOT NULL,
        quality      REAL NOT NULL,
        dim          INTEGER NOT NULL,
        embedding    BLOB NOT NULL,
        image_w      INTEGER NOT NULL,
        image_h      INTEGER NOT NULL,
        PRIMARY KEY (content_hash, face_idx)
    );

    CREATE TABLE clusters (
        cluster_id  INTEGER PRIMARY KEY AUTOINCREMENT,
        centroid    BLOB NOT NULL,
        dim         INTEGER NOT NULL,
        size        INTEGER NOT NULL DEFAULT 0,
        state       INTEGER NOT NULL DEFAULT 0,
        person_name TEXT,
        updated_at  INTEGER NOT NULL
    );

    CREATE TABLE cluster_members (
        content_hash BLOB NOT NULL,
        face_idx     INTEGER NOT NULL,
        cluster_id   INTEGER NOT NULL,
        PRIMARY KEY (content_hash, face_idx),
        FOREIGN KEY (cluster_id) REFERENCES clusters (cluster_id) ON DELETE CASCADE
    );
    CREATE INDEX cluster_members_cluster ON cluster_members (cluster_id);

    CREATE TABLE cluster_merge_proposals (
        a           INTEGER NOT NULL,
        b           INTEGER NOT NULL,
        similarity  REAL NOT NULL,
        proposed_at INTEGER NOT NULL,
        PRIMARY KEY (a, b)
    );
    "#,
];

/// One of the two work queues. See the module docs.
///
/// Both fields are compile-time literals — they are interpolated into SQL, and
/// nothing else in this module ever is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Queue {
    table: &'static str,
    count_col: &'static str,
}

/// The Phase 1 tagging queue.
const TAGGING: Queue = Queue {
    table: "ml_work",
    count_col: "tag_count",
};

/// The Phase 2 face queue.
const FACES: Queue = Queue {
    table: "face_work",
    count_col: "face_count",
};

/// Lifecycle of one photo in a work queue.
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
    /// Processed successfully under `model_pack`.
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

/// What a cluster is to the user.
///
/// Persisted discriminants; append-only.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default)]
#[repr(i64)]
pub enum ClusterState {
    /// Nobody has named it. Free to be reshaped by the periodic full pass.
    #[default]
    Unlabeled = 0,
    /// A person's name is attached; new faces joining it are auto-tagged. The
    /// full pass never touches these.
    Named = 1,
    /// The user said "not a person" (or "don't care"). Kept so the faces do not
    /// come back as a new cluster on every pass.
    Ignored = 2,
}

impl ClusterState {
    /// The persisted integer.
    pub fn as_i64(self) -> i64 {
        self as i64
    }

    /// Inverse of [`ClusterState::as_i64`]; unknown values read as
    /// [`ClusterState::Unlabeled`].
    pub fn from_i64(v: i64) -> ClusterState {
        match v {
            1 => ClusterState::Named,
            2 => ClusterState::Ignored,
            _ => ClusterState::Unlabeled,
        }
    }
}

/// Queue counts, as reported to the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Stats {
    /// Rows waiting to be processed, including `stale` and retryable `failed`.
    pub pending: u64,
    /// Rows processed under the current pack.
    pub done: u64,
    /// Rows that failed and are out of retries.
    pub failed: u64,
    /// Rows skipped as an unsupported format.
    pub skipped: u64,
    /// Rows whose result count is non-zero: tags written for the tagging queue,
    /// faces found for the face queue.
    pub tagged: u64,
}

/// What the face tables hold, as reported to the UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct FaceLibraryStats {
    /// Stored face rows.
    pub faces: u64,
    /// Faces that belong to a cluster.
    pub assigned: u64,
    /// Clusters in each state.
    pub unlabeled_clusters: u64,
    /// Clusters a person's name is attached to.
    pub named_clusters: u64,
    /// Clusters the user dismissed.
    pub ignored_clusters: u64,
    /// Outstanding merge proposals.
    pub merge_proposals: u64,
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
    /// Size in bytes at the time it was processed.
    pub size: u64,
    /// Last-modified time in whole seconds, when the platform reported one.
    pub modified_unix: Option<i64>,
}

/// One row of a work queue.
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

/// One detected, aligned and embedded face.
///
/// Keyed by the *content* hash, not by path: two copies of a photo share the
/// detection, exactly as they share an embedding.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredFace {
    /// SHA-256 of the photo's bytes.
    pub content_hash: [u8; 32],
    /// Position within the photo's detection list; see
    /// [`crate::face::detect`] for the ordering that makes this stable.
    pub face_idx: u32,
    /// `[x0, y0, x1, y1]` in original-image pixels, post-EXIF-orientation.
    pub bbox: [f32; 4],
    /// Five landmarks in the same coordinate space, ArcFace order.
    pub landmarks: [[f32; 2]; 5],
    /// Raw detector confidence.
    pub score: f32,
    /// Composite quality; see [`crate::face::quality`].
    pub quality: f32,
    /// L2-normalized face embedding.
    pub embedding: Vec<f32>,
    /// Oriented image width the coordinates are relative to.
    pub image_w: u32,
    /// Oriented image height.
    pub image_h: u32,
}

/// One cluster row.
#[derive(Debug, Clone, PartialEq)]
pub struct ClusterRow {
    /// Stable identity; handed to the UI and never reused.
    pub id: i64,
    /// L2-normalized mean of the member embeddings.
    pub centroid: Vec<f32>,
    /// Member count, denormalized so the cluster list is one query.
    pub size: u32,
    /// Unlabeled / named / ignored.
    pub state: ClusterState,
    /// The person's name, when `state` is [`ClusterState::Named`].
    pub person_name: Option<String>,
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
        db.face_reclaim_abandoned()?;
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
}

// ---------------------------------------------------------------------------
// Work queues
//
// One implementation, two tables. The `q_*` free functions hold the SQL; the
// `CacheDb` methods below are the two named views onto it.
// ---------------------------------------------------------------------------

fn q_reclaim_abandoned(conn: &Connection, q: Queue) -> MlResult<usize> {
    Ok(conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, updated_at = ?2 WHERE state = ?3",
            q.table
        ),
        params![
            WorkState::Pending.as_i64(),
            now_unix(),
            WorkState::Hashing.as_i64()
        ],
    )?)
}

fn q_reopen_skipped(conn: &Connection, q: Queue, current: u32) -> MlResult<usize> {
    Ok(conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, error_code = 0, retry_count = 0, updated_at = ?2
             WHERE state = ?3 AND (decoder_version IS NULL OR decoder_version <> ?4)",
            q.table
        ),
        params![
            WorkState::Pending.as_i64(),
            now_unix(),
            WorkState::Skipped.as_i64(),
            current as i64
        ],
    )?)
}

fn q_done_rows_with_stat(conn: &Connection, q: Queue) -> MlResult<Vec<DoneRowStat>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT path, file_size, file_mtime FROM {} WHERE state = ?1
         AND file_size IS NOT NULL",
        q.table
    ))?;
    let rows = stmt.query_map(params![WorkState::Done.as_i64()], |r| {
        Ok(DoneRowStat {
            path: r.get(0)?,
            size: r.get::<_, i64>(1)?.max(0) as u64,
            modified_unix: r.get(2)?,
        })
    })?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

fn q_mark_stale(conn: &Connection, q: Queue, path: &str) -> MlResult<usize> {
    Ok(conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, updated_at = ?2 WHERE path = ?3 AND state = ?4",
            q.table
        ),
        params![
            WorkState::Stale.as_i64(),
            now_unix(),
            path,
            WorkState::Done.as_i64()
        ],
    )?)
}

fn q_enqueue(conn: &mut Connection, q: Queue, paths: &[String]) -> MlResult<usize> {
    let tx = conn.transaction()?;
    let now = now_unix();
    let mut inserted = 0usize;
    {
        let mut stmt = tx.prepare(&format!(
            "INSERT INTO {} (path, state, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(path) DO NOTHING",
            q.table
        ))?;
        for path in paths {
            inserted += stmt.execute(params![path, WorkState::Pending.as_i64(), now])?;
        }
    }
    tx.commit()?;
    Ok(inserted)
}

fn q_mark_stale_for_pack(conn: &Connection, q: Queue, pack: &str) -> MlResult<usize> {
    Ok(conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, updated_at = ?2
             WHERE state = ?3 AND (model_pack IS NULL OR model_pack <> ?4)",
            q.table
        ),
        params![
            WorkState::Stale.as_i64(),
            now_unix(),
            WorkState::Done.as_i64(),
            pack
        ],
    )?)
}

fn q_claimable(
    conn: &Connection,
    q: Queue,
    limit: usize,
    root_prefix: Option<&str>,
) -> MlResult<Vec<WorkItem>> {
    // `substr(path, 1, length(?)) = ?` rather than LIKE/GLOB: both of those
    // give `%`, `_`, `[` and `*` meaning, and a library folder may contain
    // any of them.
    let sql = format!(
        "SELECT path, content_hash, state, model_pack, error_code, retry_count
         FROM {}
         WHERE (state IN (?1, ?2) OR (state = ?3 AND retry_count < ?4))
           AND (?6 IS NULL OR substr(path, 1, length(?6)) = ?6)
         ORDER BY updated_at, path
         LIMIT ?5",
        q.table
    );
    let mut stmt = conn.prepare(&sql)?;
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

fn q_item(conn: &Connection, q: Queue, path: &str) -> MlResult<Option<WorkItem>> {
    Ok(conn
        .query_row(
            &format!(
                "SELECT path, content_hash, state, model_pack, error_code, retry_count
                 FROM {} WHERE path = ?1",
                q.table
            ),
            params![path],
            row_to_item,
        )
        .optional()?)
}

fn q_begin(conn: &Connection, q: Queue, path: &str) -> MlResult<bool> {
    let n = conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, updated_at = ?2
             WHERE path = ?3 AND state IN (?4, ?5, ?6)",
            q.table
        ),
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

fn q_set_content_hash(conn: &Connection, q: Queue, path: &str, hash: &[u8; 32]) -> MlResult<bool> {
    let n = conn.execute(
        &format!(
            "UPDATE {} SET content_hash = ?1, updated_at = ?2 WHERE path = ?3 AND state = ?4",
            q.table
        ),
        params![
            hash.as_slice(),
            now_unix(),
            path,
            WorkState::Hashing.as_i64()
        ],
    )?;
    Ok(n > 0)
}

fn q_finish_done(
    conn: &Connection,
    q: Queue,
    path: &str,
    pack: &str,
    count: usize,
    stat: Option<(u64, Option<i64>)>,
) -> MlResult<bool> {
    let n = conn.execute(
        &format!(
            "UPDATE {}
             SET state = ?1, model_pack = ?2, {} = ?3, error_code = 0,
                 retry_count = 0, updated_at = ?4, file_size = ?6, file_mtime = ?7
             WHERE path = ?5 AND state = ?8",
            q.table, q.count_col
        ),
        params![
            WorkState::Done.as_i64(),
            pack,
            count as i64,
            now_unix(),
            path,
            stat.map(|(size, _)| size as i64),
            stat.and_then(|(_, mtime)| mtime),
            WorkState::Hashing.as_i64()
        ],
    )?;
    Ok(n > 0)
}

fn q_finish_failed(conn: &Connection, q: Queue, path: &str, code: ErrorCode) -> MlResult<bool> {
    let n = conn.execute(
        &format!(
            "UPDATE {}
             SET state = ?1, error_code = ?2, retry_count = retry_count + 1, updated_at = ?3
             WHERE path = ?4 AND state = ?5",
            q.table
        ),
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

fn q_finish_skipped(
    conn: &Connection,
    q: Queue,
    path: &str,
    decoder_version: u32,
) -> MlResult<bool> {
    let n = conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, error_code = ?2, updated_at = ?3,
                 decoder_version = ?5
             WHERE path = ?4 AND state = ?6",
            q.table
        ),
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

fn q_release(conn: &Connection, q: Queue, path: &str) -> MlResult<()> {
    conn.execute(
        &format!(
            "UPDATE {} SET state = ?1, updated_at = ?2 WHERE path = ?3 AND state = ?4",
            q.table
        ),
        params![
            WorkState::Pending.as_i64(),
            now_unix(),
            path,
            WorkState::Hashing.as_i64()
        ],
    )?;
    Ok(())
}

fn q_stats(conn: &Connection, q: Queue) -> MlResult<Stats> {
    let mut stats = Stats::default();
    let mut stmt = conn.prepare(&format!(
        "SELECT state, COUNT(*), SUM({} > 0) FROM {} GROUP BY state",
        q.count_col, q.table
    ))?;
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
            WorkState::Pending | WorkState::Hashing | WorkState::Stale => stats.pending += count,
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
        &format!(
            "SELECT COUNT(*) FROM {} WHERE state = ?1 AND retry_count < ?2",
            q.table
        ),
        params![WorkState::Failed.as_i64(), MAX_RETRIES],
        |r| r.get::<_, i64>(0).map(|v| v as u64),
    )?;
    stats.pending += retryable;
    stats.failed -= retryable.min(stats.failed);
    Ok(stats)
}

fn q_reset(conn: &Connection, q: Queue) -> MlResult<()> {
    conn.execute(&format!("DELETE FROM {}", q.table), [])?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Tagging queue (Phase 1 API, unchanged)
// ---------------------------------------------------------------------------

impl CacheDb {
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
        q_reclaim_abandoned(&self.lock(), TAGGING)
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
        q_reopen_skipped(&self.lock(), TAGGING, current)
    }

    /// Every `done` row that recorded a stat, so a run can spot in-place edits.
    ///
    /// Rows written before the stat columns existed are **omitted**: there is
    /// no baseline to compare against, and re-tagging the whole library on a
    /// schema upgrade would be a worse answer than leaving them until the next
    /// real change.
    pub fn done_rows_with_stat(&self) -> MlResult<Vec<DoneRowStat>> {
        q_done_rows_with_stat(&self.lock(), TAGGING)
    }

    /// Demote one `done` row to `stale` because its bytes moved under us.
    pub fn mark_stale(&self, path: &str) -> MlResult<usize> {
        q_mark_stale(&self.lock(), TAGGING, path)
    }

    /// Add `paths` to the queue, idempotently, in one transaction.
    ///
    /// A path already present keeps its state — re-enqueuing a `done` photo
    /// must not re-tag it. Returns how many rows were newly inserted.
    pub fn enqueue(&self, paths: &[String]) -> MlResult<usize> {
        q_enqueue(&mut self.lock(), TAGGING, paths)
    }

    /// Mark every `done` row whose `model_pack` differs from `pack` as stale.
    ///
    /// "A pack upgrade marks affected `ml_work` rows stale rather than wiping
    /// them" (overview, model packs) — the embeddings stay, so a downgrade back
    /// to the old pack is nearly free.
    pub fn mark_stale_for_pack(&self, pack: &str) -> MlResult<usize> {
        q_mark_stale_for_pack(&self.lock(), TAGGING, pack)
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
        q_claimable(&self.lock(), TAGGING, limit, root_prefix)
    }

    /// One row by path.
    pub fn item(&self, path: &str) -> MlResult<Option<WorkItem>> {
        q_item(&self.lock(), TAGGING, path)
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
        q_begin(&self.lock(), TAGGING, path)
    }

    /// Record the content hash of a row being processed.
    ///
    /// Returns whether the row is still ours; see [`CacheDb::begin`].
    pub fn set_content_hash(&self, path: &str, hash: &[u8; 32]) -> MlResult<bool> {
        q_set_content_hash(&self.lock(), TAGGING, path, hash)
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
        q_finish_done(&self.lock(), TAGGING, path, pack, tag_count, stat)
    }

    /// Mark a row failed, incrementing its retry counter.
    pub fn finish_failed(&self, path: &str, code: ErrorCode) -> MlResult<bool> {
        q_finish_failed(&self.lock(), TAGGING, path, code)
    }

    /// Mark a row as a format this build does not handle, stamping the decoder
    /// generation that said so (see [`CacheDb::reopen_skipped_for_decoder`]).
    pub fn finish_skipped(&self, path: &str, decoder_version: u32) -> MlResult<bool> {
        q_finish_skipped(&self.lock(), TAGGING, path, decoder_version)
    }

    /// Release a claimed row back to `pending` without counting a failure.
    /// Used when a run is cancelled with photos in flight.
    pub fn release(&self, path: &str) -> MlResult<()> {
        q_release(&self.lock(), TAGGING, path)
    }

    /// Queue counts.
    pub fn stats(&self) -> MlResult<Stats> {
        q_stats(&self.lock(), TAGGING)
    }

    /// Drop every queue row, keeping cached embeddings.
    ///
    /// This is "re-tag everything" without paying for inference again.
    pub fn reset_queue(&self) -> MlResult<()> {
        q_reset(&self.lock(), TAGGING)
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
        Ok(decode_vec(dim, &bytes))
    }

    /// Store an embedding, replacing any previous one for the same key.
    pub fn put_embedding(&self, hash: &[u8; 32], model: &str, vec: &[f32]) -> MlResult<()> {
        self.lock().execute(
            "INSERT INTO embeddings (content_hash, model, dim, vec) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(content_hash, model) DO UPDATE
             SET dim = excluded.dim, vec = excluded.vec",
            params![hash.as_slice(), model, vec.len() as i64, encode_vec(vec)],
        )?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Face queue (Phase 2) — same mechanics, own table
// ---------------------------------------------------------------------------

impl CacheDb {
    /// [`CacheDb::reclaim_abandoned`] for the face queue.
    pub fn face_reclaim_abandoned(&self) -> MlResult<usize> {
        q_reclaim_abandoned(&self.lock(), FACES)
    }

    /// [`CacheDb::reopen_skipped_for_decoder`] for the face queue.
    pub fn face_reopen_skipped_for_decoder(&self, current: u32) -> MlResult<usize> {
        q_reopen_skipped(&self.lock(), FACES, current)
    }

    /// [`CacheDb::done_rows_with_stat`] for the face queue.
    pub fn face_done_rows_with_stat(&self) -> MlResult<Vec<DoneRowStat>> {
        q_done_rows_with_stat(&self.lock(), FACES)
    }

    /// [`CacheDb::mark_stale`] for the face queue.
    pub fn face_mark_stale(&self, path: &str) -> MlResult<usize> {
        q_mark_stale(&self.lock(), FACES, path)
    }

    /// [`CacheDb::enqueue`] for the face queue.
    pub fn face_enqueue(&self, paths: &[String]) -> MlResult<usize> {
        q_enqueue(&mut self.lock(), FACES, paths)
    }

    /// [`CacheDb::mark_stale_for_pack`] for the face queue.
    pub fn face_mark_stale_for_pack(&self, pack: &str) -> MlResult<usize> {
        q_mark_stale_for_pack(&self.lock(), FACES, pack)
    }

    /// [`CacheDb::claimable`] for the face queue.
    pub fn face_claimable(
        &self,
        limit: usize,
        root_prefix: Option<&str>,
    ) -> MlResult<Vec<WorkItem>> {
        q_claimable(&self.lock(), FACES, limit, root_prefix)
    }

    /// [`CacheDb::item`] for the face queue.
    pub fn face_item(&self, path: &str) -> MlResult<Option<WorkItem>> {
        q_item(&self.lock(), FACES, path)
    }

    /// [`CacheDb::begin`] for the face queue.
    pub fn face_begin(&self, path: &str) -> MlResult<bool> {
        q_begin(&self.lock(), FACES, path)
    }

    /// [`CacheDb::set_content_hash`] for the face queue.
    pub fn face_set_content_hash(&self, path: &str, hash: &[u8; 32]) -> MlResult<bool> {
        q_set_content_hash(&self.lock(), FACES, path, hash)
    }

    /// [`CacheDb::finish_done`] for the face queue.
    pub fn face_finish_done(
        &self,
        path: &str,
        pack: &str,
        face_count: usize,
        stat: Option<(u64, Option<i64>)>,
    ) -> MlResult<bool> {
        q_finish_done(&self.lock(), FACES, path, pack, face_count, stat)
    }

    /// [`CacheDb::finish_failed`] for the face queue.
    pub fn face_finish_failed(&self, path: &str, code: ErrorCode) -> MlResult<bool> {
        q_finish_failed(&self.lock(), FACES, path, code)
    }

    /// [`CacheDb::finish_skipped`] for the face queue.
    pub fn face_finish_skipped(&self, path: &str, decoder_version: u32) -> MlResult<bool> {
        q_finish_skipped(&self.lock(), FACES, path, decoder_version)
    }

    /// [`CacheDb::release`] for the face queue.
    pub fn face_release(&self, path: &str) -> MlResult<()> {
        q_release(&self.lock(), FACES, path)
    }

    /// [`CacheDb::stats`] for the face queue. `tagged` counts photos that have
    /// at least one face.
    pub fn face_stats(&self) -> MlResult<Stats> {
        q_stats(&self.lock(), FACES)
    }

    /// Drop every face queue row, keeping detections and clusters.
    pub fn face_reset_queue(&self) -> MlResult<()> {
        q_reset(&self.lock(), FACES)
    }
}

// ---------------------------------------------------------------------------
// Face results and clusters
// ---------------------------------------------------------------------------

impl CacheDb {
    /// How many faces `hash` was found to have under `model`, or `None` if
    /// these bytes have never been through the detector.
    ///
    /// The distinction is the whole reason `face_scans` exists: without it, a
    /// photo with no faces and a photo never looked at are the same empty
    /// query, and every run re-detects every faceless photo in the library.
    pub fn face_scan(&self, hash: &[u8; 32], model: &str) -> MlResult<Option<(usize, u32, u32)>> {
        let conn = self.lock();
        Ok(conn
            .query_row(
                "SELECT face_count, image_w, image_h FROM face_scans
                 WHERE content_hash = ?1 AND model = ?2",
                params![hash.as_slice(), model],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?.max(0) as usize,
                        r.get::<_, i64>(1)?.max(0) as u32,
                        r.get::<_, i64>(2)?.max(0) as u32,
                    ))
                },
            )
            .optional()?)
    }

    /// Replace every stored face for `hash` with `faces`, and record the scan.
    ///
    /// One transaction: a half-written detection list would make `face_scan`
    /// lie about what is in `faces`. Members of clusters pointing at faces that
    /// disappear are dropped with them.
    pub fn put_faces(
        &self,
        hash: &[u8; 32],
        model: &str,
        image_w: u32,
        image_h: u32,
        faces: &[StoredFace],
    ) -> MlResult<()> {
        let mut conn = self.lock();
        let tx = conn.transaction()?;
        tx.execute(
            "DELETE FROM cluster_members WHERE content_hash = ?1",
            params![hash.as_slice()],
        )?;
        tx.execute(
            "DELETE FROM faces WHERE content_hash = ?1",
            params![hash.as_slice()],
        )?;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO faces (content_hash, face_idx, model, bbox, landmarks, score,
                                    quality, dim, embedding, image_w, image_h)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            )?;
            for face in faces {
                stmt.execute(params![
                    hash.as_slice(),
                    face.face_idx as i64,
                    model,
                    encode_vec(&face.bbox),
                    encode_vec(&flatten_landmarks(&face.landmarks)),
                    f64::from(face.score),
                    f64::from(face.quality),
                    face.embedding.len() as i64,
                    encode_vec(&face.embedding),
                    i64::from(image_w),
                    i64::from(image_h),
                ])?;
            }
        }
        tx.execute(
            "INSERT INTO face_scans (content_hash, model, face_count, image_w, image_h)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(content_hash, model) DO UPDATE
             SET face_count = excluded.face_count, image_w = excluded.image_w,
                 image_h = excluded.image_h",
            params![
                hash.as_slice(),
                model,
                faces.len() as i64,
                i64::from(image_w),
                i64::from(image_h)
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Every stored face for one photo, ordered by `face_idx`.
    pub fn faces_for_hash(&self, hash: &[u8; 32]) -> MlResult<Vec<StoredFace>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(&format!(
            "SELECT {FACE_COLUMNS} FROM faces WHERE content_hash = ?1 ORDER BY face_idx"
        ))?;
        let rows = stmt.query_map(params![hash.as_slice()], row_to_face)?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect())
    }

    /// Faces that no cluster claims, in the fixed `(content_hash, face_idx)`
    /// order the incremental assignment pass walks.
    pub fn unassigned_faces(&self) -> MlResult<Vec<StoredFace>> {
        self.query_faces(
            "SELECT {cols} FROM faces
             WHERE NOT EXISTS (SELECT 1 FROM cluster_members m
                               WHERE m.content_hash = faces.content_hash
                                 AND m.face_idx = faces.face_idx)
             ORDER BY content_hash, face_idx",
        )
    }

    /// Faces belonging to a cluster nobody has named or dismissed, plus faces
    /// belonging to no cluster at all — the input to the full re-cluster pass.
    ///
    /// Named and ignored clusters are excluded by construction: "never touches
    /// named clusters except to propose merges" (Phase 2 plan).
    pub fn unlabeled_faces(&self) -> MlResult<Vec<StoredFace>> {
        self.query_faces(
            "SELECT {cols} FROM faces
             WHERE NOT EXISTS (SELECT 1 FROM cluster_members m
                               JOIN clusters c ON c.cluster_id = m.cluster_id
                               WHERE m.content_hash = faces.content_hash
                                 AND m.face_idx = faces.face_idx
                                 AND c.state <> 0)
             ORDER BY content_hash, face_idx",
        )
    }

    fn query_faces(&self, sql_template: &str) -> MlResult<Vec<StoredFace>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(&sql_template.replace("{cols}", FACE_COLUMNS))?;
        let rows = stmt.query_map([], row_to_face)?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect())
    }

    /// Every cluster, in id order.
    pub fn clusters(&self) -> MlResult<Vec<ClusterRow>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT cluster_id, dim, centroid, size, state, person_name
             FROM clusters ORDER BY cluster_id",
        )?;
        let rows = stmt.query_map([], |r| {
            let dim: i64 = r.get(1)?;
            let bytes: Vec<u8> = r.get(2)?;
            Ok(ClusterRow {
                id: r.get(0)?,
                centroid: decode_vec(dim, &bytes).unwrap_or_default(),
                size: r.get::<_, i64>(3)?.max(0) as u32,
                state: ClusterState::from_i64(r.get(4)?),
                person_name: r.get(5)?,
            })
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Create a cluster around `centroid` and return its new id.
    pub fn create_cluster(&self, centroid: &[f32]) -> MlResult<i64> {
        let conn = self.lock();
        conn.execute(
            "INSERT INTO clusters (centroid, dim, size, state, updated_at)
             VALUES (?1, ?2, 0, ?3, ?4)",
            params![
                encode_vec(centroid),
                centroid.len() as i64,
                ClusterState::Unlabeled.as_i64(),
                now_unix()
            ],
        )?;
        Ok(conn.last_insert_rowid())
    }

    /// Overwrite a cluster's centroid and member count.
    pub fn set_cluster_centroid(&self, id: i64, centroid: &[f32], size: u32) -> MlResult<()> {
        self.lock().execute(
            "UPDATE clusters SET centroid = ?1, dim = ?2, size = ?3, updated_at = ?4
             WHERE cluster_id = ?5",
            params![
                encode_vec(centroid),
                centroid.len() as i64,
                i64::from(size),
                now_unix(),
                id
            ],
        )?;
        Ok(())
    }

    /// Name a cluster, or clear its name and put it back in play.
    ///
    /// Naming is the only thing that makes a cluster durable; everything else
    /// about it is recomputable.
    pub fn set_cluster_state(
        &self,
        id: i64,
        state: ClusterState,
        person_name: Option<&str>,
    ) -> MlResult<()> {
        self.lock().execute(
            "UPDATE clusters SET state = ?1, person_name = ?2, updated_at = ?3
             WHERE cluster_id = ?4",
            params![state.as_i64(), person_name, now_unix(), id],
        )?;
        Ok(())
    }

    /// Point a face at a cluster, moving it if it already belonged to another.
    pub fn set_cluster_member(&self, id: i64, hash: &[u8; 32], face_idx: u32) -> MlResult<()> {
        self.lock().execute(
            "INSERT INTO cluster_members (content_hash, face_idx, cluster_id)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(content_hash, face_idx) DO UPDATE SET cluster_id = excluded.cluster_id",
            params![hash.as_slice(), i64::from(face_idx), id],
        )?;
        Ok(())
    }

    /// The `(content_hash, face_idx)` pairs of one cluster, in stable order.
    pub fn cluster_members(&self, id: i64) -> MlResult<Vec<([u8; 32], u32)>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT content_hash, face_idx FROM cluster_members
             WHERE cluster_id = ?1 ORDER BY content_hash, face_idx",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            let hash: Vec<u8> = r.get(0)?;
            Ok((hash, r.get::<_, i64>(1)?.max(0) as u32))
        })?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter_map(|(h, i)| <[u8; 32]>::try_from(h.as_slice()).ok().map(|h| (h, i)))
            .collect())
    }

    /// The member embeddings of one cluster, in stable order.
    ///
    /// Exists so the incremental pass can keep a running *sum* per cluster
    /// rather than a normalized centroid: adding a face to a cluster changes
    /// its mean, and recovering the mean from a unit-length centroid plus a
    /// count is not possible.
    pub fn cluster_member_embeddings(&self, id: i64) -> MlResult<Vec<Vec<f32>>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT f.dim, f.embedding FROM cluster_members m
             JOIN faces f ON f.content_hash = m.content_hash AND f.face_idx = m.face_idx
             WHERE m.cluster_id = ?1
             ORDER BY m.content_hash, m.face_idx",
        )?;
        let rows = stmt.query_map(params![id], |r| {
            let dim: i64 = r.get(0)?;
            let bytes: Vec<u8> = r.get(1)?;
            Ok(decode_vec(dim, &bytes))
        })?;
        Ok(rows
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .flatten()
            .collect())
    }

    /// Delete clusters by id, cascading their memberships away.
    pub fn delete_clusters(&self, ids: &[i64]) -> MlResult<usize> {
        if ids.is_empty() {
            return Ok(0);
        }
        let placeholders = vec!["?"; ids.len()].join(", ");
        Ok(self.lock().execute(
            &format!("DELETE FROM clusters WHERE cluster_id IN ({placeholders})"),
            params_from_iter(ids.iter()),
        )?)
    }

    /// Record (or refresh) a merge proposal between two clusters.
    ///
    /// Stored, never applied: "merge proposals surface in the UI rather than
    /// auto-merging when either is named" (Phase 2 plan). The pair is
    /// normalized so `(7, 3)` and `(3, 7)` are one row.
    pub fn put_merge_proposal(&self, a: i64, b: i64, similarity: f32) -> MlResult<()> {
        let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
        self.lock().execute(
            "INSERT INTO cluster_merge_proposals (a, b, similarity, proposed_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(a, b) DO UPDATE
             SET similarity = excluded.similarity, proposed_at = excluded.proposed_at",
            params![lo, hi, f64::from(similarity), now_unix()],
        )?;
        Ok(())
    }

    /// Outstanding merge proposals, strongest first.
    pub fn merge_proposals(&self) -> MlResult<Vec<(i64, i64, f32)>> {
        let conn = self.lock();
        let mut stmt = conn.prepare(
            "SELECT a, b, similarity FROM cluster_merge_proposals
             ORDER BY similarity DESC, a, b",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get::<_, f64>(2)? as f32))
        })?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    /// Drop every merge proposal.
    ///
    /// Proposals are advisory and derived from the current centroids, so they
    /// are rebuilt wholesale rather than diffed.
    pub fn clear_merge_proposals(&self) -> MlResult<()> {
        self.lock()
            .execute("DELETE FROM cluster_merge_proposals", [])?;
        Ok(())
    }

    /// Drop proposals that name a cluster which no longer exists.
    pub fn prune_merge_proposals(&self) -> MlResult<usize> {
        Ok(self.lock().execute(
            "DELETE FROM cluster_merge_proposals
             WHERE a NOT IN (SELECT cluster_id FROM clusters)
                OR b NOT IN (SELECT cluster_id FROM clusters)",
            [],
        )?)
    }

    /// Face-table counts.
    pub fn face_library_stats(&self) -> MlResult<FaceLibraryStats> {
        let conn = self.lock();
        let count = |sql: &str| -> MlResult<u64> {
            Ok(conn.query_row(sql, [], |r| r.get::<_, i64>(0).map(|v| v as u64))?)
        };
        let mut stats = FaceLibraryStats {
            faces: count("SELECT COUNT(*) FROM faces")?,
            assigned: count("SELECT COUNT(*) FROM cluster_members")?,
            ..FaceLibraryStats::default()
        };
        let mut stmt = conn.prepare("SELECT state, COUNT(*) FROM clusters GROUP BY state")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                ClusterState::from_i64(r.get(0)?),
                r.get::<_, i64>(1)? as u64,
            ))
        })?;
        for row in rows {
            let (state, count) = row?;
            match state {
                ClusterState::Unlabeled => stats.unlabeled_clusters = count,
                ClusterState::Named => stats.named_clusters = count,
                ClusterState::Ignored => stats.ignored_clusters = count,
            }
        }
        stats.merge_proposals = count("SELECT COUNT(*) FROM cluster_merge_proposals")?;
        Ok(stats)
    }

    /// Throw away every face, scan, cluster and proposal.
    ///
    /// Called when the face models change: the embeddings live in a different
    /// space, so a cluster built from the old ones means nothing. Named
    /// clusters go too — the durable record of a naming is the *sidecar*, not
    /// this table (standing decision 4), so nothing is lost that the sidecar
    /// pipeline cannot put back.
    pub fn reset_face_results(&self) -> MlResult<()> {
        let mut conn = self.lock();
        let tx = conn.transaction()?;
        for table in [
            "cluster_merge_proposals",
            "cluster_members",
            "clusters",
            "faces",
            "face_scans",
        ] {
            tx.execute(&format!("DELETE FROM {table}"), [])?;
        }
        // `clusters` is AUTOINCREMENT: without this a fresh cluster would reuse
        // ids the UI may still be holding from before the reset.
        tx.execute("DELETE FROM sqlite_sequence WHERE name = 'clusters'", [])
            .ok();
        tx.commit()?;
        Ok(())
    }
}

const FACE_COLUMNS: &str = "content_hash, face_idx, bbox, landmarks, score, quality, dim, \
                            embedding, image_w, image_h";

fn row_to_face(r: &rusqlite::Row<'_>) -> rusqlite::Result<Option<StoredFace>> {
    let hash: Vec<u8> = r.get(0)?;
    let Ok(content_hash) = <[u8; 32]>::try_from(hash.as_slice()) else {
        return Ok(None);
    };
    let bbox_bytes: Vec<u8> = r.get(2)?;
    let lm_bytes: Vec<u8> = r.get(3)?;
    let dim: i64 = r.get(6)?;
    let emb_bytes: Vec<u8> = r.get(7)?;
    let (Some(bbox), Some(landmarks), Some(embedding)) = (
        decode_vec(4, &bbox_bytes),
        decode_vec(10, &lm_bytes),
        decode_vec(dim, &emb_bytes),
    ) else {
        // A truncated blob is a corrupt row, not a hard error: drop it and let
        // the engine re-detect over the top.
        return Ok(None);
    };
    Ok(Some(StoredFace {
        content_hash,
        face_idx: r.get::<_, i64>(1)?.max(0) as u32,
        bbox: [bbox[0], bbox[1], bbox[2], bbox[3]],
        landmarks: [
            [landmarks[0], landmarks[1]],
            [landmarks[2], landmarks[3]],
            [landmarks[4], landmarks[5]],
            [landmarks[6], landmarks[7]],
            [landmarks[8], landmarks[9]],
        ],
        score: r.get::<_, f64>(4)? as f32,
        quality: r.get::<_, f64>(5)? as f32,
        embedding,
        image_w: r.get::<_, i64>(8)?.max(0) as u32,
        image_h: r.get::<_, i64>(9)?.max(0) as u32,
    }))
}

fn flatten_landmarks(lm: &[[f32; 2]; 5]) -> [f32; 10] {
    let mut out = [0.0f32; 10];
    for (i, p) in lm.iter().enumerate() {
        out[i * 2] = p[0];
        out[i * 2 + 1] = p[1];
    }
    out
}

/// Little-endian f32 blob.
fn encode_vec(v: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(v.len() * 4);
    for x in v {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    bytes
}

/// Inverse of [`encode_vec`]; `None` when the blob's length disagrees with the
/// declared dimension, which is a corrupt row rather than an error.
fn decode_vec(dim: i64, bytes: &[u8]) -> Option<Vec<f32>> {
    let dim = usize::try_from(dim).ok()?;
    if bytes.len() != dim * 4 {
        return None;
    }
    Some(
        bytes
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            .collect(),
    )
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

    fn face(hash: [u8; 32], idx: u32, embedding: Vec<f32>) -> StoredFace {
        StoredFace {
            content_hash: hash,
            face_idx: idx,
            bbox: [1.0, 2.0, 3.0, 4.0],
            landmarks: [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0], [7.0, 8.0], [9.0, 10.0]],
            score: 0.9,
            quality: 0.5,
            embedding,
            image_w: 100,
            image_h: 200,
        }
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

    /// A v1 file must gain the v2 columns and the v3 tables, and keep its rows.
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
        // And the Phase 2 tables exist and are empty.
        assert_eq!(db.face_stats().unwrap(), Stats::default());
        assert_eq!(
            db.face_library_stats().unwrap(),
            FaceLibraryStats::default()
        );
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

    #[test]
    fn cluster_states_round_trip() {
        for s in [
            ClusterState::Unlabeled,
            ClusterState::Named,
            ClusterState::Ignored,
        ] {
            assert_eq!(ClusterState::from_i64(s.as_i64()), s);
        }
        assert_eq!(ClusterState::from_i64(42), ClusterState::Unlabeled);
    }

    // -----------------------------------------------------------------------
    // Phase 2
    // -----------------------------------------------------------------------

    /// The two queues share an implementation but must not share *rows*: a
    /// tagged photo is not a face-scanned photo, and vice versa.
    #[test]
    fn the_two_queues_are_independent() {
        let db = db();
        db.enqueue(&["/a.jpg".into()]).unwrap();
        db.face_enqueue(&["/a.jpg".into(), "/b.jpg".into()])
            .unwrap();
        claim_and_finish(&db, "/a.jpg", "pack-1", 3);

        assert_eq!(db.stats().unwrap().done, 1);
        assert_eq!(db.stats().unwrap().pending, 0);
        // Faces have not run at all.
        assert_eq!(db.face_stats().unwrap().pending, 2);
        assert_eq!(db.face_stats().unwrap().done, 0);
        assert_eq!(
            db.face_item("/b.jpg").unwrap().unwrap().state,
            WorkState::Pending
        );
        assert!(db.item("/b.jpg").unwrap().is_none());

        // And resetting one leaves the other alone.
        db.reset_queue().unwrap();
        assert_eq!(db.stats().unwrap().pending, 0);
        assert_eq!(db.face_stats().unwrap().pending, 2);
    }

    /// The face queue inherits the whole conditional-claim discipline, not a
    /// simplified copy of it.
    #[test]
    fn the_face_queue_refuses_terminal_writes_for_rows_it_lost() {
        let db = db();
        db.face_enqueue(&["/a.jpg".into()]).unwrap();
        assert!(db.face_begin("/a.jpg").unwrap());
        assert!(!db.face_begin("/a.jpg").unwrap());

        db.face_reset_queue().unwrap();
        db.face_enqueue(&["/a.jpg".into()]).unwrap();
        assert!(!db.face_set_content_hash("/a.jpg", &h(1)).unwrap());
        assert!(!db.face_finish_done("/a.jpg", "p", 2, None).unwrap());
        assert!(!db.face_finish_failed("/a.jpg", ErrorCode::Io).unwrap());
        assert!(!db.face_finish_skipped("/a.jpg", 1).unwrap());
        assert_eq!(
            db.face_item("/a.jpg").unwrap().unwrap().state,
            WorkState::Pending
        );
    }

    #[test]
    fn face_rows_round_trip_with_their_geometry() {
        let db = db();
        let faces = vec![face(h(1), 0, vec![1.0, 0.0]), face(h(1), 1, vec![0.0, 1.0])];
        db.put_faces(&h(1), "m", 640, 480, &faces).unwrap();
        let read = db.faces_for_hash(&h(1)).unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(read[0].bbox, [1.0, 2.0, 3.0, 4.0]);
        assert_eq!(read[0].landmarks[4], [9.0, 10.0]);
        assert_eq!(read[1].embedding, vec![0.0, 1.0]);
        assert_eq!(read[0].image_w, 640);
        assert_eq!(db.face_scan(&h(1), "m").unwrap(), Some((2, 640, 480)));
    }

    /// The distinction the whole table exists for.
    #[test]
    fn a_photo_with_no_faces_is_recorded_as_scanned() {
        let db = db();
        assert_eq!(db.face_scan(&h(1), "m").unwrap(), None);
        db.put_faces(&h(1), "m", 10, 10, &[]).unwrap();
        assert_eq!(db.face_scan(&h(1), "m").unwrap(), Some((0, 10, 10)));
        // Under a different model it is unscanned again.
        assert_eq!(db.face_scan(&h(1), "m2").unwrap(), None);
    }

    #[test]
    fn re_detecting_replaces_the_previous_faces_and_their_memberships() {
        let db = db();
        db.put_faces(&h(1), "m", 10, 10, &[face(h(1), 0, vec![1.0])])
            .unwrap();
        let id = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_member(id, &h(1), 0).unwrap();
        assert_eq!(db.cluster_members(id).unwrap().len(), 1);

        db.put_faces(&h(1), "m", 10, 10, &[]).unwrap();
        assert!(db.faces_for_hash(&h(1)).unwrap().is_empty());
        assert!(db.cluster_members(id).unwrap().is_empty());
    }

    #[test]
    fn unassigned_faces_come_back_in_a_fixed_order() {
        let db = db();
        db.put_faces(
            &h(2),
            "m",
            1,
            1,
            &[face(h(2), 1, vec![1.0]), face(h(2), 0, vec![1.0])],
        )
        .unwrap();
        db.put_faces(&h(1), "m", 1, 1, &[face(h(1), 0, vec![1.0])])
            .unwrap();
        let keys: Vec<_> = db
            .unassigned_faces()
            .unwrap()
            .iter()
            .map(|f| (f.content_hash[0], f.face_idx))
            .collect();
        assert_eq!(keys, vec![(1, 0), (2, 0), (2, 1)]);

        let id = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_member(id, &h(2), 0).unwrap();
        let keys: Vec<_> = db
            .unassigned_faces()
            .unwrap()
            .iter()
            .map(|f| (f.content_hash[0], f.face_idx))
            .collect();
        assert_eq!(keys, vec![(1, 0), (2, 1)]);
    }

    /// The full re-cluster pass may reshape unlabeled clusters but must not see
    /// a face a human already accounted for.
    #[test]
    fn unlabeled_faces_exclude_named_and_ignored_clusters() {
        let db = db();
        for i in 0..3u8 {
            db.put_faces(&h(i), "m", 1, 1, &[face(h(i), 0, vec![1.0])])
                .unwrap();
        }
        let named = db.create_cluster(&[1.0]).unwrap();
        let ignored = db.create_cluster(&[1.0]).unwrap();
        let plain = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_state(named, ClusterState::Named, Some("Alice"))
            .unwrap();
        db.set_cluster_state(ignored, ClusterState::Ignored, None)
            .unwrap();
        db.set_cluster_member(named, &h(0), 0).unwrap();
        db.set_cluster_member(ignored, &h(1), 0).unwrap();
        db.set_cluster_member(plain, &h(2), 0).unwrap();

        let hashes: Vec<u8> = db
            .unlabeled_faces()
            .unwrap()
            .iter()
            .map(|f| f.content_hash[0])
            .collect();
        assert_eq!(hashes, vec![2]);
    }

    #[test]
    fn a_face_belongs_to_exactly_one_cluster() {
        let db = db();
        db.put_faces(&h(1), "m", 1, 1, &[face(h(1), 0, vec![1.0])])
            .unwrap();
        let a = db.create_cluster(&[1.0]).unwrap();
        let b = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_member(a, &h(1), 0).unwrap();
        db.set_cluster_member(b, &h(1), 0).unwrap();
        assert!(db.cluster_members(a).unwrap().is_empty());
        assert_eq!(db.cluster_members(b).unwrap().len(), 1);
    }

    #[test]
    fn deleting_a_cluster_takes_its_memberships_with_it() {
        let db = db();
        db.put_faces(&h(1), "m", 1, 1, &[face(h(1), 0, vec![1.0])])
            .unwrap();
        let id = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_member(id, &h(1), 0).unwrap();
        assert_eq!(db.delete_clusters(&[id]).unwrap(), 1);
        assert_eq!(db.unassigned_faces().unwrap().len(), 1);
        assert_eq!(db.delete_clusters(&[]).unwrap(), 0);
    }

    #[test]
    fn clusters_round_trip_their_centroid_and_naming() {
        let db = db();
        let id = db.create_cluster(&[0.6, 0.8]).unwrap();
        db.set_cluster_centroid(id, &[0.0, 1.0], 4).unwrap();
        db.set_cluster_state(id, ClusterState::Named, Some("Alice"))
            .unwrap();
        let rows = db.clusters().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].centroid, vec![0.0, 1.0]);
        assert_eq!(rows[0].size, 4);
        assert_eq!(rows[0].state, ClusterState::Named);
        assert_eq!(rows[0].person_name.as_deref(), Some("Alice"));
    }

    #[test]
    fn merge_proposals_are_normalized_and_pruned() {
        let db = db();
        let a = db.create_cluster(&[1.0]).unwrap();
        let b = db.create_cluster(&[1.0]).unwrap();
        db.put_merge_proposal(b, a, 0.7).unwrap();
        db.put_merge_proposal(a, b, 0.9).unwrap();
        assert_eq!(db.merge_proposals().unwrap(), vec![(a, b, 0.9)]);
        db.delete_clusters(&[b]).unwrap();
        assert_eq!(db.prune_merge_proposals().unwrap(), 1);
        assert!(db.merge_proposals().unwrap().is_empty());
    }

    /// A face-model swap invalidates the embedding space, so everything derived
    /// from it goes — including the cluster id sequence, which the UI holds.
    #[test]
    fn resetting_face_results_clears_everything_derived() {
        let db = db();
        db.put_faces(&h(1), "m", 1, 1, &[face(h(1), 0, vec![1.0])])
            .unwrap();
        let a = db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_member(a, &h(1), 0).unwrap();
        db.put_merge_proposal(a, a + 1, 0.9).unwrap();
        db.face_enqueue(&["/a.jpg".into()]).unwrap();

        db.reset_face_results().unwrap();
        assert_eq!(
            db.face_library_stats().unwrap(),
            FaceLibraryStats::default()
        );
        assert_eq!(db.face_scan(&h(1), "m").unwrap(), None);
        // The queue is untouched — it is the thing that will refill the tables.
        assert_eq!(db.face_stats().unwrap().pending, 1);
        // Ids start over rather than colliding with what the UI last saw.
        assert_eq!(db.create_cluster(&[1.0]).unwrap(), a);
    }

    #[test]
    fn face_library_stats_count_each_cluster_state() {
        let db = db();
        for i in 0..3u8 {
            db.put_faces(&h(i), "m", 1, 1, &[face(h(i), 0, vec![1.0])])
                .unwrap();
        }
        let named = db.create_cluster(&[1.0]).unwrap();
        let ignored = db.create_cluster(&[1.0]).unwrap();
        db.create_cluster(&[1.0]).unwrap();
        db.set_cluster_state(named, ClusterState::Named, Some("A"))
            .unwrap();
        db.set_cluster_state(ignored, ClusterState::Ignored, None)
            .unwrap();
        db.set_cluster_member(named, &h(0), 0).unwrap();

        let s = db.face_library_stats().unwrap();
        assert_eq!(s.faces, 3);
        assert_eq!(s.assigned, 1);
        assert_eq!(s.named_clusters, 1);
        assert_eq!(s.ignored_clusters, 1);
        assert_eq!(s.unlabeled_clusters, 1);
    }

    #[test]
    fn a_corrupt_face_blob_drops_the_row_rather_than_the_query() {
        let db = db();
        db.put_faces(&h(1), "m", 1, 1, &[face(h(1), 0, vec![1.0, 2.0])])
            .unwrap();
        {
            let conn = db.lock();
            conn.execute(
                "UPDATE faces SET embedding = ?1 WHERE content_hash = ?2",
                params![vec![0u8, 1, 2], h(1).as_slice()],
            )
            .unwrap();
        }
        assert!(db.faces_for_hash(&h(1)).unwrap().is_empty());
    }
}
