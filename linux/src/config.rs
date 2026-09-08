//! XDG paths and the small JSON prefs file.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

const APP_ID: &str = "localgallery";

/// On-disk preferences. The library folder is the only one that matters in v1.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    /// Absolute path of the folder the user picked, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub library_root: Option<String>,
}

impl Config {
    /// `~/.config/localgallery/config.json` (or `$XDG_CONFIG_HOME`).
    pub fn path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(APP_ID)
            .join("config.json")
    }

    /// Load, or an empty config when the file is missing or unreadable.
    pub fn load() -> Self {
        let path = Self::path();
        fs::read(&path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    /// Create the directory if needed and write the file.
    pub fn save(&self) -> std::io::Result<()> {
        let path = Self::path();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(
            path,
            serde_json::to_vec_pretty(self).expect("config is serialisable"),
        )
    }
}

/// `~/.cache/localgallery`.
pub fn cache_dir() -> PathBuf {
    dirs::cache_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(APP_ID)
}

/// Snapshot written after each successful scan.
pub fn snapshot_path() -> PathBuf {
    cache_dir().join("library_snapshot.json")
}

/// Tagging / faces work queue and embeddings (`gallery-cache.sqlite`).
pub fn ml_cache_path() -> PathBuf {
    cache_dir().join("gallery-cache.sqlite")
}

/// Nominatim haversine cache (version 3 — not the old Apple JSON).
pub fn geo_cache_path() -> PathBuf {
    cache_dir().join("nominatim-cache.json")
}

/// Reverse-geocode URL. `$LOCALGALLERY_NOMINATIM` overrides the public OSM instance.
pub fn nominatim_endpoint() -> String {
    std::env::var("LOCALGALLERY_NOMINATIM")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| gallery_geo::DEFAULT_ENDPOINT.to_string())
}

/// Whether `root` exists and is a directory.
pub fn root_is_available(root: &Path) -> bool {
    root.is_dir()
}
