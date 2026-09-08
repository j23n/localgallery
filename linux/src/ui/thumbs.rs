//! Grid tiles come from the XDG thumbnail cache. The viewer decodes the file.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;

use gtk::gdk_pixbuf::{Colorspace, Pixbuf};
use gtk::prelude::*;
use gtk::{gdk, glib, Picture};

use crate::decode::{decode_limited, RgbFrame};
use crate::display::grid_thumb_size;
use crate::faces::crop_region;
use crate::xdg_thumb;
use gallery_model::photo::FaceRegion;

struct ThumbMsg {
    key: String,
    frame: RgbFrame,
}

/// Shared decode queue. Poll [`Self::drain`] on the GTK thread.
#[derive(Clone)]
pub struct ThumbCache {
    tx: Sender<ThumbMsg>,
    rx: Rc<RefCell<Receiver<ThumbMsg>>>,
    waiting: Rc<RefCell<HashMap<String, Vec<Picture>>>>,
    ready: Rc<RefCell<HashMap<String, gdk::Texture>>>,
}

impl ThumbCache {
    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel();
        ThumbCache {
            tx,
            rx: Rc::new(RefCell::new(rx)),
            waiting: Rc::new(RefCell::new(HashMap::new())),
            ready: Rc::new(RefCell::new(HashMap::new())),
        }
    }

    /// Call from the GTK thread until it returns false (channel empty).
    pub fn drain(&self) -> bool {
        let mut progressed = false;
        while let Ok(msg) = self.rx.borrow().try_recv() {
            progressed = true;
            if let Some(pixbuf) = pixbuf_from_rgb(&msg.frame) {
                let tex = gdk::Texture::for_pixbuf(&pixbuf);
                self.ready.borrow_mut().insert(msg.key.clone(), tex.clone());
                if let Some(pictures) = self.waiting.borrow_mut().remove(&msg.key) {
                    for picture in pictures {
                        picture.set_paintable(Some(&tex));
                    }
                }
            }
        }
        progressed
    }

    /// Gallery tile: XDG `large` (1×) or `x-large` (2×).
    pub fn bind_grid(&self, picture: &Picture, path: &str, id: &str, scale: u32) {
        let size = grid_thumb_size(scale);
        self.enqueue(picture, path, id, Job::Grid { size });
    }

    /// Viewer: original file, long side = window × scale, at most 2000.
    pub fn bind_viewer(&self, picture: &Picture, path: &str, id: &str, max_side: u32) {
        self.enqueue(picture, path, id, Job::Viewer { max_side });
    }

    /// Face crop from the display thumbnail + an MWG rectangle.
    pub fn bind_face(
        &self,
        picture: &Picture,
        path: &str,
        id: &str,
        scale: u32,
        region: &FaceRegion,
    ) {
        self.enqueue(
            picture,
            path,
            id,
            Job::Face {
                size: grid_thumb_size(scale),
                region: region.clone(),
            },
        );
    }
}

#[derive(Clone)]
enum Job {
    Grid {
        size: crate::xdg_thumb::ThumbSize,
    },
    Viewer {
        max_side: u32,
    },
    Face {
        size: crate::xdg_thumb::ThumbSize,
        region: FaceRegion,
    },
}

impl ThumbCache {
    fn enqueue(&self, picture: &Picture, path: &str, id: &str, job: Job) {
        let key = match &job {
            Job::Grid { size } => format!("{id}:xdg:{}", size.dir_name()),
            Job::Viewer { max_side } => format!("{id}:view:{max_side}"),
            Job::Face { size, region } => format!(
                "{id}:face:{}:{:.3}:{:.3}",
                size.dir_name(),
                region.center_x,
                region.center_y
            ),
        };
        if let Some(tex) = self.ready.borrow().get(&key).cloned() {
            picture.set_paintable(Some(&tex));
            return;
        }
        picture.set_paintable(Option::<&gdk::Paintable>::None);
        self.waiting
            .borrow_mut()
            .entry(key.clone())
            .or_default()
            .push(picture.clone());
        let tx = self.tx.clone();
        let path = path.to_string();
        thread::spawn(move || {
            let frame = match job {
                Job::Grid { size } => {
                    xdg_thumb::load_or_make(&xdg_thumb::cache_root(), &path, size)
                }
                Job::Viewer { max_side } => decode_limited(&path, max_side),
                Job::Face { size, region } => {
                    xdg_thumb::load_or_make(&xdg_thumb::cache_root(), &path, size)
                        .and_then(|frame| crop_region(&frame, &region))
                }
            };
            if let Some(frame) = frame {
                let _ = tx.send(ThumbMsg { key, frame });
            }
        });
    }
}

fn pixbuf_from_rgb(frame: &RgbFrame) -> Option<Pixbuf> {
    let expect = frame.width as usize * frame.height as usize * 3;
    if frame.rgb.len() != expect {
        return None;
    }
    Some(Pixbuf::from_bytes(
        &glib::Bytes::from(&frame.rgb),
        Colorspace::Rgb,
        false,
        8,
        frame.width as i32,
        frame.height as i32,
        frame.width as i32 * 3,
    ))
}
