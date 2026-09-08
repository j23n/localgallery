//! Pack root enumeration. [`gallery_ml::resolve_model_pack`] is the rule.

use std::fs;
use std::path::{Path, PathBuf};

use gallery_ml::{resolve_model_pack, PackSource};
use serde::Deserialize;

const MANIFEST: &str = "manifest.json";

/// Where we look for versioned pack directories.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackRoots {
    /// `/usr/share/localgallery/pack` and a source-tree `build/pack`.
    pub bundled: Vec<PathBuf>,
    /// `$XDG_DATA_HOME/localgallery/pack` (or the iOS imported root).
    pub imported: Vec<PathBuf>,
}

/// A resolved pack, plus the cheap facts Settings can show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PackStatus {
    /// Directory that holds `manifest.json`.
    pub directory: PathBuf,
    /// Last path component (the version name used for resolution).
    pub name: String,
    /// Bundled vs user-imported.
    pub source: PackSource,
    /// `pack_version` from the manifest, if present.
    pub version: String,
    /// Whether the manifest declares face models.
    pub has_faces: bool,
}

impl PackStatus {
    /// Source as Settings shows it.
    pub fn source_label(&self) -> &'static str {
        match self.source {
            PackSource::Bundled => "Bundled",
            PackSource::Imported => "Imported",
        }
    }
}

/// Default search roots, plus `$LOCALGALLERY_PACK` when set.
pub fn default_roots() -> PackRoots {
    let mut bundled = vec![PathBuf::from("/usr/share/localgallery/pack")];
    if let Ok(cwd) = std::env::current_dir() {
        bundled.push(cwd.join("build/pack"));
        bundled.push(cwd.join("../build/pack"));
    }
    bundled.push(
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("build")
            .join("pack"),
    );

    let mut imported = vec![data_pack_root()];
    if let Ok(extra) = std::env::var("LOCALGALLERY_PACK") {
        if !extra.is_empty() {
            imported.insert(0, PathBuf::from(extra));
        }
    }

    PackRoots { bundled, imported }
}

/// `$XDG_DATA_HOME/localgallery/pack`.
pub fn data_pack_root() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("share"))
        })
        .unwrap_or_else(|| PathBuf::from("."))
        .join("localgallery")
        .join("pack")
}

/// Newest usable pack under the default roots.
pub fn discover_pack() -> Option<PackStatus> {
    resolve_in(&default_roots())
}

/// Resolve against explicit roots (tests / iOS injected lists).
pub fn resolve_in(roots: &PackRoots) -> Option<PackStatus> {
    let bundled = collect_candidates(&roots.bundled);
    let imported = collect_candidates(&roots.imported);
    let picked = resolve_model_pack(&names_of(&bundled), &names_of(&imported))?;
    let pool = match picked.source {
        PackSource::Imported => &imported,
        PackSource::Bundled => &bundled,
    };
    let directory = pool
        .iter()
        .find(|p| file_name(p) == picked.name.as_str())?
        .clone();
    let peek = peek_manifest(&directory)?;
    Some(PackStatus {
        directory,
        name: picked.name,
        source: picked.source,
        version: peek.pack_version.unwrap_or_default(),
        has_faces: peek.faces.is_some(),
    })
}

/// Whether this binary was built with the ONNX tagging/faces path.
pub fn ml_enabled() -> bool {
    cfg!(feature = "ml")
}

fn names_of(dirs: &[PathBuf]) -> Vec<String> {
    dirs.iter().map(|p| file_name(p).to_string()).collect()
}

fn file_name(path: &Path) -> &str {
    path.file_name()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
}

fn collect_candidates(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for root in roots {
        if has_manifest(root) {
            out.push(root.clone());
            continue;
        }
        let Ok(entries) = fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() && has_manifest(&path) {
                out.push(path);
            }
        }
    }
    out
}

fn has_manifest(dir: &Path) -> bool {
    dir.join(MANIFEST).is_file()
}

#[derive(Debug, Deserialize)]
struct ManifestPeek {
    #[serde(default)]
    pack_version: Option<String>,
    #[serde(default)]
    faces: Option<serde_json::Value>,
}

fn peek_manifest(dir: &Path) -> Option<ManifestPeek> {
    let bytes = fs::read(dir.join(MANIFEST)).ok()?;
    serde_json::from_slice(&bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_manifest(dir: &Path, version: &str, faces: bool) {
        fs::create_dir_all(dir).unwrap();
        let faces_json = if faces {
            r#", "faces": {"detector": {}}"#
        } else {
            ""
        };
        fs::write(
            dir.join(MANIFEST),
            format!(r#"{{"schema":1,"pack_version":"{version}"{faces_json}}}"#),
        )
        .unwrap();
    }

    #[test]
    fn newest_imported_beats_older_bundled() {
        let tmp = tempfile::tempdir().unwrap();
        let bundled = tmp.path().join("bundled");
        let imported = tmp.path().join("imported");
        write_manifest(&bundled.join("pack-v1.9"), "v1.9", false);
        write_manifest(&imported.join("pack-v1.10"), "v1.10", true);
        let status = resolve_in(&PackRoots {
            bundled: vec![bundled],
            imported: vec![imported],
        })
        .expect("pack");
        assert_eq!(status.name, "pack-v1.10");
        assert_eq!(status.source, PackSource::Imported);
        assert!(status.has_faces);
    }
}
