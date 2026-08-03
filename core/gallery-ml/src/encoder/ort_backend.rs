//! ONNX Runtime backend.
//!
//! # Session pool
//!
//! `ort::Session::run` takes `&mut self`, but [`super::ImageEncoder::embed`]
//! takes `&self` and is called from every worker at once. Rather than put one
//! session behind a mutex — which would serialize inference and defeat the
//! engine's whole parallelism story — this holds `slots` independent sessions
//! and hands each caller the first one it can lock. Sessions are cheap to keep
//! and expensive to build, so they are all built up front, at
//! [`OrtEncoder::new`], where a failure is a clean run-level error.
//!
//! Each session is single-threaded internally (`with_intra_threads(1)`,
//! `with_parallel_execution(false)`), so `slots` really is the total inference
//! thread count.
//!
//! # Determinism knobs
//!
//! * CPU execution provider only. The pyke prebuilt for `aarch64-apple-ios-sim`
//!   also carries CoreML, and it is deliberately never registered: an ANE/GPU
//!   path would give a different answer on a different chip, which is the one
//!   thing the doctrine forbids.
//! * `with_deterministic_compute(true)` — asks ORT for reduction orders that
//!   do not depend on scheduling.
//! * Graph optimization is pinned explicitly rather than left at the default,
//!   so an ORT upgrade that changes the default cannot silently move scores.
//!   `Level3` is used: it is CPU-EP-internal, deterministic for a fixed build,
//!   and roughly doubles throughput. The cross-*build* drift it can introduce
//!   is exactly what the tagger's hysteresis margin absorbs.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::Tensor as OrtTensor;

use crate::error::{MlError, MlResult};
use crate::preprocess::Tensor;

use super::ImageEncoder;

/// ONNX Runtime image encoder.
pub struct OrtEncoder {
    slots: Vec<Mutex<Session>>,
    next: AtomicUsize,
    input_name: String,
    output_name: String,
    input_size: u32,
    embedding_dim: usize,
}

impl std::fmt::Debug for OrtEncoder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OrtEncoder")
            .field("slots", &self.slots.len())
            .field("input_size", &self.input_size)
            .field("embedding_dim", &self.embedding_dim)
            .finish()
    }
}

impl OrtEncoder {
    /// Build `slots` sessions from `model_bytes`.
    ///
    /// `slots` is clamped to at least 1. `input_size` and `embedding_dim` come
    /// from the pack manifest and are trusted: the ONNX graph's own shapes are
    /// frequently symbolic (`batch`, `channels`), so they cannot be the source
    /// of truth. A mismatch surfaces as a shape error on the first `embed`.
    pub fn new(
        model_bytes: &[u8],
        input_name: &str,
        output_name: &str,
        input_size: u32,
        embedding_dim: usize,
        slots: usize,
    ) -> MlResult<OrtEncoder> {
        let slots = slots.max(1);
        let mut sessions = Vec::with_capacity(slots);
        for _ in 0..slots {
            sessions.push(Mutex::new(build_session(model_bytes)?));
        }
        Ok(OrtEncoder {
            slots: sessions,
            next: AtomicUsize::new(0),
            input_name: input_name.to_string(),
            output_name: output_name.to_string(),
            input_size,
            embedding_dim,
        })
    }
}

/// `ort::Error<R>` is generic over the builder it consumed, so a single
/// closure cannot be reused across the chain below. A generic function can.
fn inference<E: std::fmt::Display>(e: E) -> MlError {
    MlError::Inference {
        detail: e.to_string(),
    }
}

fn build_session(model_bytes: &[u8]) -> MlResult<Session> {
    Session::builder()
        .map_err(inference)?
        .with_intra_threads(1)
        .map_err(inference)?
        .with_inter_threads(1)
        .map_err(inference)?
        .with_parallel_execution(false)
        .map_err(inference)?
        .with_deterministic_compute(true)
        .map_err(inference)?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(inference)?
        .commit_from_memory(model_bytes)
        .map_err(inference)
}

impl ImageEncoder for OrtEncoder {
    fn embed(&self, tensor: &Tensor) -> MlResult<Vec<f32>> {
        let shape: Vec<i64> = tensor.shape.iter().map(|d| *d as i64).collect();
        let input = OrtTensor::from_array((shape, tensor.data.clone())).map_err(|e| {
            MlError::Inference {
                detail: format!("building input tensor: {e}"),
            }
        })?;

        let mut session = self.acquire();
        let outputs = session
            .run(ort::inputs![self.input_name.as_str() => input])
            .map_err(|e| MlError::Inference {
                detail: e.to_string(),
            })?;
        let value = outputs
            .get(self.output_name.as_str())
            .ok_or_else(|| MlError::Inference {
                detail: format!("model has no output named {:?}", self.output_name),
            })?;
        let (_, data) = value
            .try_extract_tensor::<f32>()
            .map_err(|e| MlError::Inference {
                detail: format!("output {:?} is not f32: {e}", self.output_name),
            })?;

        if data.len() != self.embedding_dim {
            return Err(MlError::Inference {
                detail: format!(
                    "output {:?} has {} values, manifest says embedding_dim {}",
                    self.output_name,
                    data.len(),
                    self.embedding_dim
                ),
            });
        }
        Ok(data.to_vec())
    }

    fn input_size(&self) -> u32 {
        self.input_size
    }

    fn embedding_dim(&self) -> usize {
        self.embedding_dim
    }

    fn backend_name(&self) -> &'static str {
        "ort"
    }
}

impl OrtEncoder {
    /// Take the first free session; if every one is busy, block on a rotating
    /// slot so callers spread out instead of all queueing behind slot 0.
    ///
    /// A poisoned mutex is recovered rather than propagated: the panic that
    /// poisoned it happened inside ORT, on a different photo, and the session
    /// itself is still a valid handle.
    fn acquire(&self) -> std::sync::MutexGuard<'_, Session> {
        for slot in &self.slots {
            if let Ok(guard) = slot.try_lock() {
                return guard;
            }
        }
        let i = self.next.fetch_add(1, Ordering::Relaxed) % self.slots.len();
        match self.slots[i].lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}
