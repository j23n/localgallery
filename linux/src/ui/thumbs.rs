//! Grid tiles come from the XDG thumbnail cache. The viewer decodes the file.
//! Decode runs on a bounded pool; the same key is never in flight twice.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc::Receiver;

use gtk::gdk_pixbuf::{Colorspace, Pixbuf};
use gtk::prelude::*;
use gtk::{gdk, glib, Picture};

use crate::decode::RgbFrame;
use crate::display::grid_thumb_size;
use crate::thumbs::{
    complete_action, frame_cost, job_key, result_channel, CompleteAction, DecodePool, FlightBook,
    PoolJob, PoolKind, PoolResult, ReadyCache, DEFAULT_WORKERS,
};
use gallery_model::photo::FaceRegion;

/// Shared decode queue. Poll [`Self::drain`] on the GTK thread.
#[derive(Clone)]
pub struct ThumbCache {
    pool: Rc<DecodePool>,
    rx: Rc<RefCell<Receiver<PoolResult>>>,
    flight: Rc<RefCell<FlightBook>>,
    waiting: Rc<RefCell<HashMap<String, Vec<Picture>>>>,
    ready: Rc<RefCell<ReadyCache<gdk::Texture>>>,
}

impl ThumbCache {
    pub fn new() -> Self {
        Self::with_workers(DEFAULT_WORKERS)
    }

    fn with_workers(workers: usize) -> Self {
        let (tx, rx) = result_channel();
        ThumbCache {
            pool: Rc::new(DecodePool::spawn(workers, tx)),
            rx: Rc::new(RefCell::new(rx)),
            flight: Rc::new(RefCell::new(FlightBook::new(workers))),
            waiting: Rc::new(RefCell::new(HashMap::new())),
            ready: Rc::new(RefCell::new(ReadyCache::product())),
        }
    }

    /// Call from the GTK thread until it returns false (channel empty).
    pub fn drain(&self) -> bool {
        let mut progressed = false;
        while let Ok(msg) = self.rx.borrow().try_recv() {
            progressed = true;
            self.flight.borrow_mut().finish(&msg.key);
            let waiters = self
                .waiting
                .borrow_mut()
                .remove(&msg.key)
                .unwrap_or_default();
            let Some(frame) = msg.frame else {
                continue;
            };
            let Some(pixbuf) = pixbuf_from_rgb(&frame) else {
                continue;
            };
            let tex = gdk::Texture::for_pixbuf(&pixbuf);
            self.ready
                .borrow_mut()
                .insert(msg.key.clone(), tex.clone(), frame_cost(&frame));
            if complete_action(waiters.len()) == CompleteAction::Deliver {
                for picture in waiters {
                    picture.set_paintable(Some(&tex));
                }
            }
        }
        progressed
    }

    /// Gallery tile: XDG `large` (1×) or `x-large` (2×).
    pub fn bind_grid(&self, picture: &Picture, path: &str, id: &str, scale: u32) {
        let size = grid_thumb_size(scale);
        self.enqueue(picture, path, id, PoolKind::Grid { size });
    }

    /// Viewer: original file, long side = window × scale, at most 2000.
    pub fn bind_viewer(&self, picture: &Picture, path: &str, id: &str, max_side: u32) {
        self.enqueue(picture, path, id, PoolKind::Viewer { max_side });
    }

    /// Drop waiters for a recycled list item so a late decode cannot paint it.
    pub fn unbind(&self, picture: &Picture) {
        self.detach(picture);
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
            PoolKind::Face {
                size: grid_thumb_size(scale),
                region: region.clone(),
            },
        );
    }
}

impl ThumbCache {
    fn enqueue(&self, picture: &Picture, path: &str, id: &str, kind: PoolKind) {
        let key = job_key(id, &kind);
        self.detach(picture);
        if let Some(tex) = self.ready.borrow_mut().get_cloned(&key) {
            picture.set_paintable(Some(&tex));
            return;
        }
        picture.set_paintable(Option::<&gdk::Paintable>::None);
        self.waiting
            .borrow_mut()
            .entry(key.clone())
            .or_default()
            .push(picture.clone());
        if !self.flight.borrow_mut().try_start(&key) {
            return;
        }
        self.pool.submit(PoolJob {
            key,
            path: path.to_string(),
            kind,
        });
    }

    fn detach(&self, picture: &Picture) {
        for waiters in self.waiting.borrow_mut().values_mut() {
            waiters.retain(|p| p != picture);
        }
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
