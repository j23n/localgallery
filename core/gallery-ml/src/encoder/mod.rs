//! The inference seam.
//!
//! [`ImageEncoder`] is deliberately the narrowest trait that still lets the
//! backend be swapped: tensor in, embedding out. It exists because the
//! onnxruntime cross-compile is the one dependency in this program with a
//! plausible failure mode nobody controls (overview, cross-cutting risks:
//! "`tract` escape hatch behind the inference trait").
//!
//! # Which backend ships
//!
//! `ort` (ONNX Runtime 1.28 via `ort` 2.0.0-rc.13), CPU execution provider
//! only, and it is the crate default. pyke publishes a prebuilt static
//! `libonnxruntime.a` for `aarch64-apple-ios-sim`, so the escape hatch stayed
//! shut; `cargo build -p gallery-ml --target aarch64-apple-ios-sim` links.
//!
//! # Threading
//!
//! Intra-op threads are pinned to 1 and inter-op parallelism is off, per the
//! overview's model-pack rules. Parallelism lives one level up, across photos,
//! in [`crate::TaggingEngine`]. Two reasons, both about determinism: a
//! multi-threaded GEMM reduces in nondeterministic order, and a thread pool
//! per session times four workers is a thread explosion on a phone.
//!
//! ORT's `Session::run` takes `&mut self`, so a shared session would have to
//! be behind a mutex — which would serialize exactly the parallelism the
//! engine is built for. [`ort_backend::OrtEncoder`] therefore holds a small
//! pool of sessions, one per worker.

#[cfg(feature = "ort-backend")]
pub mod ort_backend;

#[cfg(feature = "ort-backend")]
pub use ort_backend::OrtEncoder;

use crate::error::MlResult;
use crate::preprocess::Tensor;

/// Turns a preprocessed tensor into an embedding vector.
///
/// Implementations must be `Send + Sync`: the engine shares one encoder across
/// its worker threads and calls [`ImageEncoder::embed`] from all of them
/// concurrently.
pub trait ImageEncoder: Send + Sync {
    /// Run the encoder. The returned vector is **not** required to be
    /// normalized — [`crate::tagger`] normalizes before scoring.
    fn embed(&self, tensor: &Tensor) -> MlResult<Vec<f32>>;

    /// Square input edge the encoder expects, in pixels.
    fn input_size(&self) -> u32;

    /// Length of the embeddings this encoder produces.
    fn embedding_dim(&self) -> usize;

    /// Short identifier for logs and error messages.
    fn backend_name(&self) -> &'static str;
}
