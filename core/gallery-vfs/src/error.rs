//! Typed VFS errors.
//!
//! Errors cross the FFI boundary as enums, never strings (overview §"FFI
//! rules"), so the variants here are deliberately coarse and closed. The
//! `message` carried by [`VfsError::Io`] is for logs only — never match on it.

use std::fmt;
use std::io;

/// Result alias for every fallible [`crate::Vfs`] operation.
pub type VfsResult<T> = Result<T, VfsError>;

/// Why a filesystem operation failed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VfsError {
    /// The path does not exist.
    NotFound { path: String },
    /// The caller lacks permission (on iOS: usually a lapsed security scope).
    PermissionDenied { path: String },
    /// A directory was required but the path is a file (or vice versa).
    NotADirectory { path: String },
    /// The path already exists and the operation refused to clobber it.
    AlreadyExists { path: String },
    /// The path is not usable (empty, no parent directory, non-UTF-8, …).
    InvalidPath { path: String, reason: String },
    /// Anything else the platform reported.
    Io { path: String, message: String },
}

impl VfsError {
    /// Classify a [`std::io::Error`] raised while operating on `path`.
    pub fn from_io(path: &str, err: &io::Error) -> Self {
        match err.kind() {
            io::ErrorKind::NotFound => VfsError::NotFound {
                path: path.to_string(),
            },
            io::ErrorKind::PermissionDenied => VfsError::PermissionDenied {
                path: path.to_string(),
            },
            io::ErrorKind::AlreadyExists => VfsError::AlreadyExists {
                path: path.to_string(),
            },
            _ => VfsError::Io {
                path: path.to_string(),
                message: err.to_string(),
            },
        }
    }

    /// The path the failure relates to.
    pub fn path(&self) -> &str {
        match self {
            VfsError::NotFound { path }
            | VfsError::PermissionDenied { path }
            | VfsError::NotADirectory { path }
            | VfsError::AlreadyExists { path }
            | VfsError::InvalidPath { path, .. }
            | VfsError::Io { path, .. } => path,
        }
    }
}

impl fmt::Display for VfsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            VfsError::NotFound { path } => write!(f, "not found: {path}"),
            VfsError::PermissionDenied { path } => write!(f, "permission denied: {path}"),
            VfsError::NotADirectory { path } => write!(f, "not a directory: {path}"),
            VfsError::AlreadyExists { path } => write!(f, "already exists: {path}"),
            VfsError::InvalidPath { path, reason } => {
                write!(f, "invalid path {path}: {reason}")
            }
            VfsError::Io { path, message } => write!(f, "io error on {path}: {message}"),
        }
    }
}

impl std::error::Error for VfsError {}
