//! Content hashing.
//!
//! `content_hash` is the SHA-256 of the file bytes, not the path-based
//! `StableUUID` (overview, cache DB): a photo that moves keeps its embedding,
//! and two devices that see the same bytes agree without talking.
//!
//! Hashing is streamed. A run touches every photo in the library and the
//! common case — a re-run — never needs the pixels, only the hash, so pulling
//! whole files into memory to hash them would be the wrong trade twice over.

use std::io::Read;

use sha2::{Digest, Sha256};

use gallery_vfs::{Vfs, VfsError};

use crate::error::MlResult;

/// Chunk size for streaming reads.
///
/// 256 KiB: large enough that syscall overhead disappears, small enough that
/// four concurrent workers cost 1 MiB of buffers rather than the file sizes.
const CHUNK: usize = 256 * 1024;

/// SHA-256 of `path`'s bytes, read through `vfs` in bounded chunks.
///
/// `cancel` is polled once per chunk so a cancelled run stops inside a large
/// file rather than at the end of it — "cancellation must actually stop file
/// IO" (overview, FFI rules).
pub fn content_hash(
    vfs: &dyn Vfs,
    path: &str,
    cancel: &dyn Fn() -> bool,
) -> MlResult<Option<[u8; 32]>> {
    let mut reader = vfs.open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; CHUNK];
    loop {
        if cancel() {
            return Ok(None);
        }
        let n = reader
            .read(&mut buf)
            .map_err(|e| VfsError::from_io(path, &e))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(Some(hasher.finalize().into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gallery_vfs::MemVfs;

    fn never() -> bool {
        false
    }

    #[test]
    fn matches_a_one_shot_digest() {
        let vfs = MemVfs::new();
        let bytes: Vec<u8> = (0..(CHUNK * 2 + 17)).map(|i| (i % 251) as u8).collect();
        vfs.write_atomic("/a.jpg", &bytes).unwrap();
        let got = content_hash(&vfs, "/a.jpg", &never).unwrap().unwrap();
        let want: [u8; 32] = Sha256::digest(&bytes).into();
        assert_eq!(got, want);
    }

    #[test]
    fn an_empty_file_hashes_to_the_empty_digest() {
        let vfs = MemVfs::new();
        vfs.write_atomic("/a.jpg", b"").unwrap();
        let got = content_hash(&vfs, "/a.jpg", &never).unwrap().unwrap();
        assert_eq!(got, <[u8; 32]>::from(Sha256::digest(b"")));
    }

    #[test]
    fn cancellation_returns_none_rather_than_a_wrong_hash() {
        let vfs = MemVfs::new();
        vfs.write_atomic("/a.jpg", b"hello").unwrap();
        assert!(content_hash(&vfs, "/a.jpg", &|| true).unwrap().is_none());
    }

    #[test]
    fn a_missing_file_is_an_error() {
        let vfs = MemVfs::new();
        assert!(content_hash(&vfs, "/nope.jpg", &never).is_err());
    }
}
