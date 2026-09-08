//! People review crops from a *display* thumbnail + MWG / detector box.
//! Naming goes through [`gallery_session::people::name_cluster`], not a
//! sidecar-only write.

use gallery_model::photo::{FaceRegion, PhotoFile};

use crate::decode::RgbFrame;

/// One unnamed box the review list can show (sidecar MWG, no cluster yet).
#[derive(Debug, Clone, PartialEq)]
pub struct UnnamedFace {
    /// Photo that carries the rectangle.
    pub path: String,
    /// Stable photo id (thumb cache key).
    pub photo_id: String,
    /// Index into `PhotoFile.face_regions`.
    pub region_index: usize,
    /// The rectangle, still unnamed.
    pub region: FaceRegion,
}

/// Unnamed MWG boxes across the library, photo order.
pub fn unnamed_faces(photos: &[PhotoFile]) -> Vec<UnnamedFace> {
    let mut out = Vec::new();
    for photo in photos {
        for (i, region) in photo.face_regions.iter().enumerate() {
            if region
                .name
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .is_none()
            {
                out.push(UnnamedFace {
                    path: photo.path().to_string(),
                    photo_id: photo.id.to_string(),
                    region_index: i,
                    region: region.clone(),
                });
            }
        }
    }
    out
}

/// First named region on `photo` whose leaf matches `person` (case-insensitive).
pub fn named_region_for<'a>(photo: &'a PhotoFile, person: &str) -> Option<&'a FaceRegion> {
    let want = person.trim();
    photo.face_regions.iter().find(|r| {
        r.name
            .as_deref()
            .is_some_and(|n| n.eq_ignore_ascii_case(want))
    })
}

/// Crop `frame` to the MWG box, with a little padding for an avatar.
pub fn crop_region(frame: &RgbFrame, region: &FaceRegion) -> Option<RgbFrame> {
    if frame.width == 0 || frame.height == 0 {
        return None;
    }
    let w = frame.width as f64;
    let h = frame.height as f64;
    let pad = 0.15;
    let rw = region.width.max(0.0);
    let rh = region.height.max(0.0);
    let x0 = ((region.center_x - rw * (0.5 + pad)) * w).floor();
    let y0 = ((region.center_y - rh * (0.5 + pad)) * h).floor();
    let x1 = ((region.center_x + rw * (0.5 + pad)) * w).ceil();
    let y1 = ((region.center_y + rh * (0.5 + pad)) * h).ceil();
    crop_pixels(frame, x0, y0, x1, y1)
}

/// Crop a detector box `[x0,y0,x1,y1]` in original pixels onto a display thumb.
pub fn crop_bbox(frame: &RgbFrame, bbox: [f32; 4], image_w: u32, image_h: u32) -> Option<RgbFrame> {
    if frame.width == 0 || frame.height == 0 || image_w == 0 || image_h == 0 {
        return None;
    }
    let sx = frame.width as f64 / image_w as f64;
    let sy = frame.height as f64 / image_h as f64;
    let pad_x = (bbox[2] - bbox[0]) as f64 * 0.15 * sx;
    let pad_y = (bbox[3] - bbox[1]) as f64 * 0.15 * sy;
    let x0 = bbox[0] as f64 * sx - pad_x;
    let y0 = bbox[1] as f64 * sy - pad_y;
    let x1 = bbox[2] as f64 * sx + pad_x;
    let y1 = bbox[3] as f64 * sy + pad_y;
    crop_pixels(frame, x0, y0, x1, y1)
}

fn crop_pixels(frame: &RgbFrame, x0: f64, y0: f64, x1: f64, y1: f64) -> Option<RgbFrame> {
    let w = frame.width as f64;
    let h = frame.height as f64;
    let x0 = x0.clamp(0.0, w - 1.0) as u32;
    let y0 = y0.clamp(0.0, h - 1.0) as u32;
    let x1 = x1.clamp((x0 + 1) as f64, w) as u32;
    let y1 = y1.clamp((y0 + 1) as f64, h) as u32;
    let cw = x1.saturating_sub(x0);
    let ch = y1.saturating_sub(y0);
    if cw == 0 || ch == 0 {
        return None;
    }
    let mut rgb = Vec::with_capacity((cw * ch * 3) as usize);
    let stride = frame.width as usize * 3;
    for y in y0..y1 {
        let row = y as usize * stride;
        let start = row + x0 as usize * 3;
        let end = row + x1 as usize * 3;
        rgb.extend_from_slice(&frame.rgb[start..end]);
    }
    Some(RgbFrame {
        width: cw,
        height: ch,
        rgb,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn region(name: Option<&str>, cx: f64, cy: f64) -> FaceRegion {
        FaceRegion {
            name: name.map(str::to_string),
            center_x: cx,
            center_y: cy,
            width: 0.2,
            height: 0.2,
        }
    }

    #[test]
    fn unnamed_faces_skip_named_boxes() {
        let mut photo = PhotoFile::new("/p.jpg", "p", 1);
        photo.face_regions = vec![region(Some("Ada"), 0.3, 0.3), region(None, 0.7, 0.4)];
        let found = unnamed_faces(&[photo]);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].region_index, 1);
    }

    #[test]
    fn crop_region_stays_inside_the_frame() {
        let mut rgb = vec![0u8; 10 * 8 * 3];
        rgb[(4 * 10 + 5) * 3] = 255;
        let frame = RgbFrame {
            width: 10,
            height: 8,
            rgb,
        };
        let crop = crop_region(&frame, &region(None, 0.5, 0.5)).expect("crop");
        assert!(crop.width >= 1 && crop.height >= 1);
        assert_eq!(crop.rgb.len(), (crop.width * crop.height * 3) as usize);
    }
}
