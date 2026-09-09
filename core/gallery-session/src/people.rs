//! People review over the face cache. Writes go through [`gallery_ml::FaceEngine`].

use gallery_ml::{CacheDb, ClusterRow, ClusterState, FaceThumb};

/// Unlabeled clusters waiting for a name.
pub fn unlabeled_clusters(
    cache_db: impl AsRef<std::path::Path>,
) -> Result<Vec<ClusterRow>, String> {
    let db = CacheDb::open(cache_db).map_err(|e| e.to_string())?;
    let rows = db.clusters().map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .filter(|c| c.state == ClusterState::Unlabeled)
        .collect())
}

/// Best crop for a cluster card.
pub fn cluster_thumb(
    cache_db: impl AsRef<std::path::Path>,
    cluster_id: i64,
) -> Result<Option<FaceThumb>, String> {
    let db = CacheDb::open(cache_db).map_err(|e| e.to_string())?;
    Ok(db
        .cluster_face_thumbs(cluster_id, 1)
        .map_err(|e| e.to_string())?
        .into_iter()
        .next())
}

/// Name a cluster. Loads the face engine (ONNX) so sidecars stay aligned
/// with the cache.
///
/// Without the `ml` feature this always errors — the host must refuse to
/// name rather than write a sidecar-only fork.
#[cfg(feature = "ml")]
pub fn name_cluster(
    cache_db: impl AsRef<std::path::Path>,
    pack_dir: impl AsRef<std::path::Path>,
    cluster_id: i64,
    name: &str,
    root_prefix: Option<&str>,
) -> Result<Vec<String>, String> {
    use gallery_ml::FaceEngine;
    use gallery_vfs::StdVfs;
    use std::sync::Arc;

    let engine =
        FaceEngine::open(cache_db, pack_dir, Arc::new(StdVfs)).map_err(|e| e.to_string())?;
    let plan = engine
        .name_cluster(cluster_id, name, None, root_prefix)
        .map_err(|e| e.to_string())?;
    Ok(plan.written)
}

/// Without ONNX: always an error. See the `ml` variant.
#[cfg(not(feature = "ml"))]
pub fn name_cluster(
    _cache_db: impl AsRef<std::path::Path>,
    _pack_dir: impl AsRef<std::path::Path>,
    _cluster_id: i64,
    _name: &str,
    _root_prefix: Option<&str>,
) -> Result<Vec<String>, String> {
    Err("This build has no ONNX. Rebuild with --features ml to name people.".into())
}
