//! What the host should do after sidecars landed.

/// Paths that changed, and whether a tree walk is still required.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SidecarRefreshPlan {
    /// Image paths whose `.xmp` was written.
    pub paths: Vec<String>,
    /// `true` when the host must walk the tree (new sidecar *files* a
    /// path-patch would miss). Analysis that reports every write sets this
    /// `false`.
    pub needs_walk: bool,
}

/// Build a plan from the paths a run wrote.
pub fn refresh_plan(written_paths: impl IntoIterator<Item = impl Into<String>>) -> SidecarRefreshPlan {
    let mut paths: Vec<String> = written_paths.into_iter().map(Into::into).collect();
    paths.sort();
    paths.dedup();
    SidecarRefreshPlan {
        needs_walk: false,
        paths,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_dedups_paths() {
        let plan = refresh_plan(["/a.jpg", "/b.jpg", "/a.jpg"]);
        assert_eq!(plan.paths, vec!["/a.jpg".to_string(), "/b.jpg".to_string()]);
        assert!(!plan.needs_walk);
    }
}
