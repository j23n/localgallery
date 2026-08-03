//! Typed errors for sidecar read/write.

use std::fmt;

use gallery_vfs::VfsError;

/// Result alias for this crate.
pub type MetaResult<T> = Result<T, MetaError>;

/// Why a sidecar could not be read or written.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetaError {
    /// The XMP packet is not parseable at all.
    MalformedXml {
        /// Parser message; for logs only.
        detail: String,
    },
    /// Not UTF-8, or a UTF-16 packet the writer refuses to transcode.
    UnsupportedEncoding {
        /// What was wrong with the encoding.
        detail: String,
    },
    /// The document has no `rdf:RDF` element and none could be created.
    NotAnXmpPacket {
        /// What was missing.
        detail: String,
    },
    /// A requested tag is not usable (empty, empty path segment, control chars).
    InvalidTag {
        /// The offending tag, verbatim.
        tag: String,
        /// Why it was rejected.
        reason: String,
    },
    /// Somebody else wrote the sidecar between our read and our write.
    ///
    /// The whole write path is read-modify-write, so renaming our result into
    /// place would discard the other writer's changes wholesale. **Retryable**:
    /// a fresh read-modify-write on the new bytes is the correct response, and
    /// nothing has been written when this is returned.
    ConcurrentModification {
        /// The sidecar that changed underneath us.
        path: String,
    },
    /// The underlying filesystem said no.
    Vfs(VfsError),
}

impl MetaError {
    /// Whether re-running the same operation could succeed.
    ///
    /// Only [`MetaError::ConcurrentModification`] qualifies: every other
    /// variant describes something about the input that a retry would meet
    /// again unchanged.
    pub fn is_retryable(&self) -> bool {
        matches!(self, MetaError::ConcurrentModification { .. })
    }
}

impl From<VfsError> for MetaError {
    fn from(e: VfsError) -> Self {
        MetaError::Vfs(e)
    }
}

impl fmt::Display for MetaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MetaError::MalformedXml { detail } => write!(f, "malformed XMP: {detail}"),
            MetaError::UnsupportedEncoding { detail } => {
                write!(f, "unsupported XMP encoding: {detail}")
            }
            MetaError::NotAnXmpPacket { detail } => write!(f, "not an XMP packet: {detail}"),
            MetaError::InvalidTag { tag, reason } => {
                write!(f, "invalid tag {tag:?}: {reason}")
            }
            MetaError::ConcurrentModification { path } => {
                write!(f, "sidecar changed underneath us: {path}")
            }
            MetaError::Vfs(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for MetaError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            MetaError::Vfs(e) => Some(e),
            _ => None,
        }
    }
}
