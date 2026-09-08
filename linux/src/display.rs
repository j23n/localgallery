//! Display-pixel policy. Not used for tagging or faces.
//!
//! Grid tiles are XDG thumbnail buckets. The viewer decodes the original,
//! capped at the same 2000 px long side as iOS
//! (`ThumbnailService.generateFullImage`). Analysis stays on
//! `ANALYSIS_MAX_LONG_SIDE` (2048) in the core and never reads these pixels.

use crate::xdg_thumb::ThumbSize;

/// iOS viewer long-side cap. Sharp on a phone, cheaper than a 12 MP decode.
pub const VIEWER_MAX_LONG_SIDE: u32 = 2000;

/// XDG bucket for a gallery tile at this GTK/Wayland scale.
///
/// 1× → `large` (256). 2× (Comet) → `x-large` (512). Never a private size,
/// never `xx-large` (that is still smaller than a laptop viewer).
pub fn grid_thumb_size(scale: u32) -> ThumbSize {
    if scale >= 2 {
        ThumbSize::XLarge
    } else {
        ThumbSize::Large
    }
}

/// Viewer decode long side in **device** pixels: window × scale, at most
/// [`VIEWER_MAX_LONG_SIDE`].
pub fn viewer_long_side(logical_width: u32, logical_height: u32, scale: u32) -> u32 {
    let scale = scale.max(1);
    let physical = logical_width.max(logical_height).saturating_mul(scale);
    physical.clamp(1, VIEWER_MAX_LONG_SIDE)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid_uses_xdg_large_or_x_large() {
        assert_eq!(grid_thumb_size(1), ThumbSize::Large);
        assert_eq!(grid_thumb_size(2), ThumbSize::XLarge);
        assert_eq!(grid_thumb_size(3), ThumbSize::XLarge);
    }

    #[test]
    fn comet_viewer_is_the_panel_not_2048() {
        // 540×620 logical @ 2× → 1240 device px.
        assert_eq!(viewer_long_side(540, 620, 2), 1240);
    }

    #[test]
    fn laptop_viewer_matches_ios_cap() {
        assert_eq!(viewer_long_side(1200, 800, 1), 1200);
        assert_eq!(viewer_long_side(1200, 800, 2), VIEWER_MAX_LONG_SIDE);
    }
}
