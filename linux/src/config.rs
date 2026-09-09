//! XDG paths and the small JSON prefs file.

use std::cell::RefCell;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::persist;

thread_local! {
    static CACHE_DIR_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
    static CONFIG_PATH_OVERRIDE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

const APP_ID: &str = "localgallery";

/// On-disk preferences. The library folder is the only one that matters in v1.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    /// Absolute path of the folder the user picked, if any.
    ///
    /// Stored as a UTF-8 string when possible; non-UTF-8 Unix paths use
    /// `{"unix_bytes":[…]}` so a tab or a non-Unicode name is not dropped.
    #[serde(default, skip_serializing_if = "Option::is_none", with = "path_serde")]
    pub library_root: Option<PathBuf>,
}

/// How [`Config::load_from`] finished.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigLoad {
    /// No file yet.
    Missing,
    /// Decoded the file.
    Loaded(Config),
    /// Bytes were present but not a config. The fallback is empty prefs.
    Corrupt {
        /// Parse / IO detail.
        detail: String,
        /// Safe empty config.
        fallback: Config,
    },
}

impl ConfigLoad {
    /// Config to run with. Corrupt files fall back to defaults.
    pub fn into_config(self) -> Config {
        match self {
            ConfigLoad::Missing | ConfigLoad::Corrupt { .. } => Config::default(),
            ConfigLoad::Loaded(c) => c,
        }
    }

    /// User-facing line when the file existed but could not be decoded.
    pub fn corruption_message(&self) -> Option<String> {
        match self {
            ConfigLoad::Corrupt { detail, .. } => {
                Some(format!("config file is corrupt; starting empty ({detail})"))
            }
            _ => None,
        }
    }
}

impl Config {
    /// `~/.config/localgallery/config.json` (or `$XDG_CONFIG_HOME`).
    pub fn path() -> PathBuf {
        CONFIG_PATH_OVERRIDE.with(|slot| {
            if let Some(path) = slot.borrow().clone() {
                return path;
            }
            dirs::config_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(APP_ID)
                .join("config.json")
        })
    }

    /// Load from the XDG path, tightening modes on a readable file.
    pub fn load() -> Self {
        Self::load_from(&Self::path()).into_config()
    }

    /// Load and keep a distinct missing / loaded / corrupt outcome.
    pub fn load_report() -> ConfigLoad {
        Self::load_from(&Self::path())
    }

    /// Load a specific file. Used by tests and [`Self::load_report`].
    pub fn load_from(path: &Path) -> ConfigLoad {
        match persist::read_private(path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => ConfigLoad::Missing,
            Err(e) => ConfigLoad::Corrupt {
                detail: e.to_string(),
                fallback: Config::default(),
            },
            Ok(bytes) => match serde_json::from_slice::<Config>(&bytes) {
                Ok(cfg) => ConfigLoad::Loaded(cfg),
                Err(e) => ConfigLoad::Corrupt {
                    detail: e.to_string(),
                    fallback: Config::default(),
                },
            },
        }
    }

    /// Create the directory if needed and write the file atomically.
    pub fn save(&self) -> std::io::Result<()> {
        self.save_to(&Self::path())
    }

    /// Atomic write of this config to `path`.
    pub fn save_to(&self, path: &Path) -> std::io::Result<()> {
        let bytes = serde_json::to_vec_pretty(self).expect("config is serialisable");
        persist::write_atomic(path, &bytes)
    }
}

/// `~/.cache/localgallery`, created `0700` when missing.
pub fn cache_dir() -> PathBuf {
    CACHE_DIR_OVERRIDE.with(|slot| {
        if let Some(dir) = slot.borrow().clone() {
            let _ = persist::ensure_private_dir(&dir);
            return dir;
        }
        let dir = dirs::cache_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(APP_ID);
        let _ = persist::ensure_private_dir(&dir);
        dir
    })
}

/// Redirect config and cache paths. Tests only; `None` restores XDG.
#[cfg(test)]
pub(crate) fn override_paths(config: Option<PathBuf>, cache: Option<PathBuf>) {
    CONFIG_PATH_OVERRIDE.with(|slot| *slot.borrow_mut() = config);
    CACHE_DIR_OVERRIDE.with(|slot| *slot.borrow_mut() = cache);
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

/// Load the geocode cache. Stale versions are empty; corrupt files are
/// reported separately so a derived miss can start clean.
pub fn load_geo_cache() -> (gallery_geo::GeoCache, Option<String>) {
    let path = geo_cache_path();
    let _ = persist::tighten_file_mode(&path);
    match gallery_geo::GeoCache::try_load(&path) {
        Ok(cache) => (cache, None),
        Err(gallery_geo::GeoCacheError::Missing)
        | Err(gallery_geo::GeoCacheError::StaleVersion { .. }) => {
            (gallery_geo::GeoCache::new(), None)
        }
        Err(e) => (
            gallery_geo::GeoCache::new(),
            Some(format!("geocode cache: {e}")),
        ),
    }
}

/// Persist the geocode cache with the same atomic write as config/snapshot.
pub fn save_geo_cache(cache: &gallery_geo::GeoCache) -> std::io::Result<()> {
    persist::write_atomic(&geo_cache_path(), &cache.encode())
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

mod path_serde {
    use std::path::PathBuf;

    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    #[derive(Serialize, Deserialize)]
    #[serde(untagged)]
    enum Wire {
        Utf8(String),
        Unix { unix_bytes: Vec<u8> },
    }

    pub fn serialize<S: Serializer>(
        value: &Option<PathBuf>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match value {
            None => serializer.serialize_none(),
            Some(path) => match path.to_str() {
                Some(s) => Wire::Utf8(s.to_string()).serialize(serializer),
                None => {
                    #[cfg(unix)]
                    {
                        use std::os::unix::ffi::OsStrExt;
                        Wire::Unix {
                            unix_bytes: path.as_os_str().as_bytes().to_vec(),
                        }
                        .serialize(serializer)
                    }
                    #[cfg(not(unix))]
                    {
                        Wire::Utf8(path.to_string_lossy().into_owned()).serialize(serializer)
                    }
                }
            },
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<PathBuf>, D::Error> {
        let Some(wire) = Option::<Wire>::deserialize(deserializer)? else {
            return Ok(None);
        };
        match wire {
            Wire::Utf8(s) => Ok(Some(PathBuf::from(s))),
            Wire::Unix { unix_bytes } => {
                #[cfg(unix)]
                {
                    use std::os::unix::ffi::OsStringExt;
                    Ok(Some(PathBuf::from(std::ffi::OsString::from_vec(
                        unix_bytes,
                    ))))
                }
                #[cfg(not(unix))]
                {
                    let _ = unix_bytes;
                    Ok(None)
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    use std::os::unix::ffi::OsStringExt;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn missing_file_is_distinct_from_corrupt() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        assert_eq!(Config::load_from(&path), ConfigLoad::Missing);

        std::fs::write(&path, b"not-json").unwrap();
        match Config::load_from(&path) {
            ConfigLoad::Corrupt { fallback, .. } => assert_eq!(fallback, Config::default()),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn utf8_root_round_trips_as_a_plain_string() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let cfg = Config {
            library_root: Some(PathBuf::from("/lib/vacation photos")),
        };
        cfg.save_to(&path).unwrap();
        let text = String::from_utf8(std::fs::read(&path).unwrap()).unwrap();
        assert!(text.contains("/lib/vacation photos"));
        assert!(!text.contains("unix_bytes"));
        match Config::load_from(&path) {
            ConfigLoad::Loaded(loaded) => assert_eq!(loaded, cfg),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn legacy_string_root_still_loads() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        std::fs::write(&path, r#"{"library_root":"/old/lib"}"#).unwrap();
        match Config::load_from(&path) {
            ConfigLoad::Loaded(cfg) => {
                assert_eq!(cfg.library_root.as_deref(), Some(Path::new("/old/lib")));
            }
            other => panic!("{other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_root_round_trips_as_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let root = PathBuf::from(std::ffi::OsString::from_vec(vec![
            b'/', b'l', b'i', b'b', b'/', 0xff, 0xfe,
        ]));
        let cfg = Config {
            library_root: Some(root.clone()),
        };
        cfg.save_to(&path).unwrap();
        let text = String::from_utf8(std::fs::read(&path).unwrap()).unwrap();
        assert!(text.contains("unix_bytes"));
        match Config::load_from(&path) {
            ConfigLoad::Loaded(loaded) => assert_eq!(loaded.library_root, Some(root)),
            other => panic!("{other:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn save_uses_private_modes() {
        let dir = tempfile::tempdir().unwrap();
        let nested = dir.path().join("localgallery");
        let path = nested.join("config.json");
        Config {
            library_root: Some(PathBuf::from("/lib")),
        }
        .save_to(&path)
        .unwrap();
        let file_mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        let dir_mode = std::fs::metadata(&nested).unwrap().permissions().mode() & 0o777;
        assert_eq!(file_mode, persist::FILE_MODE);
        assert_eq!(dir_mode, persist::DIR_MODE);
    }
}
