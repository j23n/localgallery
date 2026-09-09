//! Adaptive application window: header switcher on a laptop, bottom bar on the Comet.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::thread;

use adw::prelude::*;
use gtk::gdk;
use gtk::gio;
use gtk::glib;
use gtk::{Align, Orientation};

use gallery_index::TagSuggestion;
use gallery_meta::sidecar::{sidecar_exists, sidecar_path};
use gallery_model::photo::{FaceRegion, PhotoFile, PhotoFolder, StableId};
use gallery_vfs::StdVfs;

use super::cards;
use super::thumbs::ThumbCache;
use crate::config::{self, Config};
use crate::display::viewer_long_side;
use crate::faces::{self, UnnamedFace};
use crate::host::{
    collection_groups, commit_analysis_state, event_folders, find_folder, leaf_tags,
    library_availability, overlay_sidecars, reapply_sidecars, CollectionGroup, LibraryAvailability,
    LibraryState,
};
use crate::ops::{apply_begin, apply_done, OpKind, OpLedger, OpToken, SurfaceFlags};
use crate::row::PhotoRow;
use crate::time;
use crate::watch::{self, MuteGate, UnmuteAction, WatchHandle};
use gallery_geo::Nominatim;
use gallery_session::{self as session, AnalysisSummary};

const APP_TITLE: &str = "LocalGallery";

#[derive(Clone)]
pub struct Window {
    inner: Rc<Inner>,
}

struct Inner {
    window: adw::ApplicationWindow,
    toast: adw::ToastOverlay,
    banner: adw::Banner,
    search_bar: gtk::SearchBar,
    search_entry: gtk::SearchEntry,
    header: adw::HeaderBar,
    back: gtk::Button,
    switcher: adw::ViewSwitcher,
    switcher_bar: adw::ViewSwitcherBar,
    stack: adw::ViewStack,
    folders_nav: adw::NavigationView,
    photos_nav: adw::NavigationView,
    collections_nav: adw::NavigationView,
    thumbs: ThumbCache,
    state: RefCell<Option<LibraryState>>,
    root: RefCell<Option<PathBuf>>,
    cancel: RefCell<Option<Arc<AtomicBool>>>,
    ops: RefCell<OpLedger>,
    surface: RefCell<SurfaceFlags>,
    mute_watch: Arc<MuteGate>,
    watch: RefCell<Option<WatchHandle>>,
    watch_rx: RefCell<Option<Receiver<()>>>,
    watch_root: RefCell<Option<PathBuf>>,
    last_analysis: RefCell<Option<AnalysisSummary>>,
    required_tags: RefCell<Vec<TagSuggestion>>,
    compact: Cell<bool>,
    short: Cell<bool>,
    viewer_open: Cell<bool>,
}

impl Window {
    pub fn present(app: &adw::Application, comet: bool) {
        let this = Self::build(app, comet);
        this.inner.window.present();
        this.install_actions();
        this.start_thumb_pump();
        this.start_watch_pump();
        this.reload_from_config();
    }

    fn build(app: &adw::Application, comet: bool) -> Self {
        let window = adw::ApplicationWindow::new(app);
        window.set_title(Some(APP_TITLE));
        window.set_width_request(360);
        window.set_height_request(294);
        if comet {
            window.set_default_size(540, 620);
        } else {
            window.set_default_size(1200, 800);
        }

        let stack = adw::ViewStack::new();
        let folders_nav = adw::NavigationView::new();
        let photos_nav = adw::NavigationView::new();
        let collections_nav = adw::NavigationView::new();
        folders_nav.add(&nav_status(
            "No Folder",
            "Choose a folder of photos to browse.",
            "folder-open-symbolic",
        ));
        photos_nav.add(&nav_status(
            "No Photos",
            "Open a library folder to see every photo here.",
            "image-x-generic-symbolic",
        ));
        collections_nav.add(&nav_status(
            "No Collections",
            "Tags from sidecars show up here after a scan.",
            "view-grid-symbolic",
        ));

        let folders_page = stack.add_titled(&folders_nav, Some("folders"), "Folders");
        folders_page.set_icon_name(Some("folder-symbolic"));
        let photos_page = stack.add_titled(&photos_nav, Some("photos"), "Photos");
        photos_page.set_icon_name(Some("image-x-generic-symbolic"));
        let collections_page =
            stack.add_titled(&collections_nav, Some("collections"), "Collections");
        collections_page.set_icon_name(Some("view-grid-symbolic"));

        let switcher = adw::ViewSwitcher::new();
        switcher.set_stack(Some(&stack));
        switcher.set_policy(adw::ViewSwitcherPolicy::Wide);

        let switcher_bar = adw::ViewSwitcherBar::new();
        switcher_bar.set_stack(Some(&stack));

        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&switcher));

        let back = gtk::Button::from_icon_name("go-previous-symbolic");
        back.set_tooltip_text(Some("Back"));
        back.set_visible(false);
        header.pack_start(&back);

        let search_button = gtk::ToggleButton::new();
        search_button.set_icon_name("system-search-symbolic");
        search_button.set_tooltip_text(Some("Search"));
        header.pack_end(&search_button);

        let menu_button = gtk::MenuButton::new();
        menu_button.set_icon_name("open-menu-symbolic");
        menu_button.set_menu_model(Some(&app_menu()));
        header.pack_end(&menu_button);

        let search_entry = gtk::SearchEntry::new();
        search_entry.set_hexpand(true);
        let search_bar = gtk::SearchBar::new();
        search_bar.set_child(Some(&search_entry));
        search_bar.connect_entry(&search_entry);
        search_bar.set_key_capture_widget(Some(&window));
        search_button
            .bind_property("active", &search_bar, "search-mode-enabled")
            .bidirectional()
            .build();

        let banner = adw::Banner::new("");
        banner.set_button_label(Some("Cancel"));

        let content = gtk::Box::new(Orientation::Vertical, 0);
        content.append(&banner);
        content.append(&search_bar);
        content.append(&stack);

        let toolbar = adw::ToolbarView::new();
        toolbar.add_top_bar(&header);
        toolbar.set_content(Some(&content));
        toolbar.add_bottom_bar(&switcher_bar);

        let toast = adw::ToastOverlay::new();
        toast.set_child(Some(&toolbar));
        window.set_content(Some(&toast));

        add_breakpoints(&window);

        let inner = Rc::new(Inner {
            window: window.clone(),
            toast,
            banner: banner.clone(),
            search_bar,
            search_entry: search_entry.clone(),
            header,
            back,
            switcher,
            switcher_bar: switcher_bar.clone(),
            stack: stack.clone(),
            folders_nav: folders_nav.clone(),
            photos_nav: photos_nav.clone(),
            collections_nav: collections_nav.clone(),
            thumbs: ThumbCache::new(),
            state: RefCell::new(None),
            root: RefCell::new(None),
            cancel: RefCell::new(None),
            ops: RefCell::new(OpLedger::default()),
            surface: RefCell::new(SurfaceFlags::idle()),
            mute_watch: MuteGate::new(),
            watch: RefCell::new(None),
            watch_rx: RefCell::new(None),
            watch_root: RefCell::new(None),
            last_analysis: RefCell::new(None),
            required_tags: RefCell::new(Vec::new()),
            compact: Cell::new(comet),
            short: Cell::new(comet),
            viewer_open: Cell::new(false),
        });
        let this = Window { inner };

        let layout = this.clone();
        window.connect_default_width_notify(move |w| layout.apply_size(w.width(), w.height()));
        let layout = this.clone();
        window.connect_default_height_notify(move |w| layout.apply_size(w.width(), w.height()));

        let layout = this.clone();
        stack.connect_visible_child_notify(move |_| layout.sync_chrome());

        this.wire_nav(&folders_nav);
        this.wire_nav(&photos_nav);
        this.wire_nav(&collections_nav);

        let popped = this.clone();
        this.inner.back.connect_clicked(move |_| {
            popped.pop_nav();
        });

        let keys = gtk::EventControllerKey::new();
        let keyed = this.clone();
        keys.connect_key_pressed(move |_, key, _, mods| {
            let alt = mods.contains(gdk::ModifierType::ALT_MASK);
            if key == gdk::Key::Escape || (alt && key == gdk::Key::Left) {
                if keyed.pop_nav() {
                    return glib::Propagation::Stop;
                }
            }
            glib::Propagation::Proceed
        });
        window.add_controller(keys);

        let search = this.clone();
        search_entry.connect_search_changed(move |entry| {
            search.on_search(&entry.text());
        });

        let cancel = this.clone();
        banner.connect_button_clicked(move |_| cancel.request_cancel());

        this.apply_size(
            if comet { 540 } else { 1200 },
            if comet { 620 } else { 800 },
        );
        this
    }

    fn install_actions(&self) {
        let prefs = gio::SimpleAction::new("preferences", None);
        let w = self.clone();
        prefs.connect_activate(move |_, _| w.show_preferences());
        self.inner.window.add_action(&prefs);

        let about = gio::SimpleAction::new("about", None);
        let w = self.clone();
        about.connect_activate(move |_, _| w.show_about());
        self.inner.window.add_action(&about);

        let open = gio::SimpleAction::new("open-folder", None);
        let w = self.clone();
        open.connect_activate(move |_, _| w.pick_folder());
        self.inner.window.add_action(&open);

        let reload = gio::SimpleAction::new("reload", None);
        let w = self.clone();
        reload.connect_activate(move |_, _| w.reload_current());
        self.inner.window.add_action(&reload);

        let scan = gio::SimpleAction::new("scan-photos", None);
        let w = self.clone();
        scan.connect_activate(move |_, _| w.start_analysis());
        self.inner.window.add_action(&scan);
    }

    fn start_thumb_pump(&self) {
        let thumbs = self.inner.thumbs.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(32), move || {
            thumbs.drain();
            glib::ControlFlow::Continue
        });
    }

    fn start_watch_pump(&self) {
        let this = self.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(200), move || {
            let hit = {
                let rx = this.inner.watch_rx.borrow();
                match rx.as_ref() {
                    Some(rx) => {
                        let mut hit = false;
                        while rx.try_recv().is_ok() {
                            hit = true;
                        }
                        hit
                    }
                    None => false,
                }
            };
            if hit && this.inner.ops.borrow().current().is_none() {
                this.reload_current();
            }
            glib::ControlFlow::Continue
        });
    }

    fn set_watch_muted(&self, muted: bool) {
        if self.inner.mute_watch.set_muted(muted) == UnmuteAction::ReconcileOnce
            && self.inner.ops.borrow().current().is_none()
        {
            self.reload_current();
        }
    }

    /// Apply a completion only when `token` is still the live generation.
    /// Stale callbacks leave the banner, cancel flag, mute, and library as-is.
    fn finish_op(&self, token: OpToken, publish: bool) -> bool {
        if !self.inner.ops.borrow().is_current(token) {
            return false;
        }
        apply_done(
            &mut self.inner.ops.borrow_mut(),
            &mut self.inner.surface.borrow_mut(),
            token,
            publish,
        );
        self.inner.banner.set_revealed(false);
        self.inner.cancel.replace(None);
        self.set_watch_muted(false);
        true
    }

    fn ensure_watch(&self) {
        let root = self.inner.root.borrow().clone();
        let same = self.inner.watch_root.borrow().as_ref() == root.as_ref();
        if same && self.inner.watch.borrow().is_some() {
            return;
        }
        self.inner.watch.replace(None);
        self.inner.watch_rx.replace(None);
        self.inner.watch_root.replace(root.clone());
        let Some(root) = root.filter(|p| p.is_dir()) else {
            return;
        };
        match watch::start(root, self.inner.mute_watch.clone()) {
            Ok((handle, rx)) => {
                self.inner.watch.replace(Some(handle));
                self.inner.watch_rx.replace(Some(rx));
            }
            Err(e) => self.toast(&format!("Folder watch: {e}")),
        }
    }

    fn scale_factor(&self) -> u32 {
        self.inner.window.scale_factor().max(1) as u32
    }

    fn logical_size(&self) -> (u32, u32) {
        let w = self.inner.window.width();
        let h = self.inner.window.height();
        if w > 1 && h > 1 {
            (w as u32, h as u32)
        } else {
            (
                self.inner.window.default_width().max(1) as u32,
                self.inner.window.default_height().max(1) as u32,
            )
        }
    }

    fn viewer_max_side(&self) -> u32 {
        let (w, h) = self.logical_size();
        viewer_long_side(w, h, self.scale_factor())
    }

    fn apply_size(&self, width: i32, height: i32) {
        self.inner.compact.set(width <= 550);
        self.inner.short.set(height <= 700);
        self.sync_chrome();
    }

    fn sync_chrome(&self) {
        let nav = current_nav(self);
        let can_pop = nav.navigation_stack().n_items() > 1;
        let viewing = nav
            .visible_page()
            .and_then(|p| p.tag())
            .is_some_and(|t| t == "viewer");
        self.inner.viewer_open.set(viewing);
        self.inner.back.set_visible(can_pop);

        let compact = self.inner.compact.get();
        if can_pop {
            if let Some(page) = nav.visible_page() {
                self.inner.window.set_title(Some(&page.title()));
            }
            self.inner
                .header
                .set_title_widget(Option::<&gtk::Widget>::None);
        } else if compact {
            self.inner.window.set_title(Some(tab_title(self)));
            self.inner
                .header
                .set_title_widget(Option::<&gtk::Widget>::None);
        } else {
            self.inner.window.set_title(Some(APP_TITLE));
            self.inner
                .header
                .set_title_widget(Some(&self.inner.switcher));
        }
        self.inner.switcher_bar.set_reveal(compact && !viewing);
        if self.inner.short.get() && self.inner.banner.is_revealed() {
            self.inner.search_bar.set_search_mode(false);
        }
    }

    fn pop_nav(&self) -> bool {
        if current_nav(self).pop() {
            self.sync_chrome();
            true
        } else {
            false
        }
    }

    fn wire_nav(&self, nav: &adw::NavigationView) {
        let pushed = self.clone();
        nav.connect_pushed(move |_| pushed.sync_chrome());
        let popped = self.clone();
        nav.connect_popped(move |_, _| popped.sync_chrome());
        let replaced = self.clone();
        nav.connect_replaced(move |_| replaced.sync_chrome());
    }

    fn toast(&self, msg: &str) {
        self.inner.toast.add_toast(adw::Toast::new(msg));
    }

    fn reload_from_config(&self) {
        let loaded = Config::load_report();
        if let Some(msg) = loaded.corruption_message() {
            self.toast(&msg);
        }
        if let Some(path) = loaded.into_config().library_root {
            self.inner.root.replace(Some(path.clone()));
            if path.is_dir() {
                self.start_scan(path);
            } else {
                self.rebuild_all();
            }
        } else {
            self.rebuild_all();
        }
    }

    fn reload_current(&self) {
        if let Some(root) = self.inner.root.borrow().clone() {
            self.start_scan(root);
        } else {
            self.pick_folder();
        }
    }

    fn pick_folder(&self) {
        let dialog = gtk::FileDialog::builder()
            .title("Open photo folder")
            .modal(true)
            .build();
        let window = self.inner.window.clone();
        let this = self.clone();
        dialog.select_folder(
            Some(&window),
            gio::Cancellable::NONE,
            move |result| match result {
                Ok(file) => {
                    if let Some(path) = file.path() {
                        this.inner.root.replace(Some(path.clone()));
                        this.start_scan(path);
                    }
                }
                Err(e) => {
                    let msg = e.to_string();
                    if !msg.contains("Dismissed") && !msg.contains("dismissed") {
                        this.toast(&msg);
                    }
                }
            },
        );
    }

    fn request_cancel(&self) {
        if let Some(flag) = self.inner.cancel.borrow().as_ref() {
            flag.store(true, Ordering::Relaxed);
        }
    }

    fn start_scan(&self, root: PathBuf) {
        if let Some(flag) = self.inner.cancel.borrow().as_ref() {
            flag.store(true, Ordering::Relaxed);
        }
        let token = apply_begin(
            &mut self.inner.ops.borrow_mut(),
            &mut self.inner.surface.borrow_mut(),
            OpKind::Scan,
        );
        let flag = Arc::new(AtomicBool::new(false));
        self.inner.cancel.replace(Some(flag.clone()));
        self.set_watch_muted(true);
        self.inner.banner.set_title("Scanning…");
        self.inner.banner.set_revealed(true);
        self.sync_chrome();

        let (tx, rx) = std::sync::mpsc::channel::<ScanEvent>();
        let root_thread = root.clone();
        let ops = self.inner.ops.borrow().clone();
        thread::spawn(move || {
            let progress_tx = tx.clone();
            let result = crate::host::open_library_with_commit(
                &root_thread,
                &flag,
                Some(&|msg, done, total| {
                    let _ = progress_tx.send(ScanEvent::Progress {
                        token,
                        msg: msg.to_string(),
                        done,
                        total,
                    });
                }),
                Some((&ops, token)),
            );
            let _ = tx.send(ScanEvent::Done {
                token,
                result: result.map_err(|e| e.to_string()),
            });
        });

        let this = self.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
            let mut keep = true;
            while let Ok(ev) = rx.try_recv() {
                match ev {
                    ScanEvent::Progress {
                        token,
                        msg,
                        done,
                        total,
                    } => {
                        if !this.inner.ops.borrow().is_current(token) {
                            continue;
                        }
                        if total > 0 {
                            this.inner
                                .banner
                                .set_title(&format!("{msg} {done}/{total}"));
                        } else if done > 0 {
                            this.inner.banner.set_title(&format!("{msg} {done}"));
                        } else {
                            this.inner.banner.set_title(&msg);
                        }
                    }
                    ScanEvent::Done { token, result } => {
                        let live = this.inner.ops.borrow().is_current(token);
                        if !live {
                            continue;
                        }
                        match result {
                            Ok(state) => {
                                this.finish_op(token, true);
                                let n = state.index.photos().len();
                                if let Some(msg) = state.snapshot_reuse.recovery_message() {
                                    this.toast(&msg);
                                }
                                if let Some(msg) =
                                    crate::row::unsupported_names_message(&state.unsupported_names)
                                {
                                    this.toast(&msg);
                                }
                                this.inner.state.replace(Some(state));
                                this.rebuild_all();
                                this.ensure_watch();
                                this.toast(&format!("Found {n} photos"));
                            }
                            Err(e) if e.contains("cancel") => {
                                this.finish_op(token, false);
                                this.toast("Scan cancelled");
                            }
                            Err(e) => {
                                this.finish_op(token, false);
                                this.toast(&e);
                            }
                        }
                        this.sync_chrome();
                        keep = false;
                    }
                }
            }
            if keep {
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
        let _ = root;
    }

    fn start_analysis(&self) {
        if self.inner.ops.borrow().current().is_some() {
            self.toast("A scan is already running");
            return;
        }
        let Some(state) = self.inner.state.borrow().clone() else {
            self.toast("Open a folder first");
            return;
        };
        let photos = state.index.photos().to_vec();
        if photos.is_empty() {
            self.toast("This folder has no photos yet");
            return;
        }
        let pack = session::discover_pack();
        let token = apply_begin(
            &mut self.inner.ops.borrow_mut(),
            &mut self.inner.surface.borrow_mut(),
            OpKind::Analysis,
        );
        let flag = Arc::new(AtomicBool::new(false));
        self.inner.cancel.replace(Some(flag.clone()));
        self.set_watch_muted(true);
        self.inner.banner.set_title("Scan Photos…");
        self.inner.banner.set_revealed(true);
        self.sync_chrome();

        let (tx, rx) = std::sync::mpsc::channel::<AnalysisEvent>();
        let progress_tx = tx.clone();
        let on_progress: session::ProgressFn = Arc::new(move |p| {
            let _ = progress_tx.send(AnalysisEvent::Progress {
                token,
                title: session::progress_title(&p),
            });
        });
        let (geo_cache, geo_note) = config::load_geo_cache();
        if let Some(msg) = geo_note {
            self.toast(&msg);
        }
        let ml_cache = config::ml_cache_path();
        let endpoint = config::nominatim_endpoint();
        let ops = self.inner.ops.borrow().clone();
        thread::spawn(move || {
            let mut geo_cache = geo_cache;
            let geo = Nominatim::new(endpoint);
            let summary = session::run_analysis(
                &photos,
                pack.as_ref(),
                Some(&ml_cache),
                &geo,
                &mut geo_cache,
                false,
                &flag,
                Some(on_progress),
            );
            let library = if summary.written_paths.is_empty() {
                None
            } else {
                match overlay_sidecars(state, Some(&summary.written_paths)) {
                    Ok(next) => Some(next),
                    Err(e) => {
                        let _ = tx.send(AnalysisEvent::Done {
                            token,
                            summary,
                            library: None,
                            refresh_error: Some(e.to_string()),
                        });
                        return;
                    }
                }
            };
            if let Err(e) = commit_analysis_state(&geo_cache, library.as_ref(), &flag, &ops, token)
            {
                let _ = tx.send(AnalysisEvent::Done {
                    token,
                    summary,
                    library: None,
                    refresh_error: Some(e.to_string()),
                });
                return;
            }
            let _ = tx.send(AnalysisEvent::Done {
                token,
                summary,
                library,
                refresh_error: None,
            });
        });

        let this = self.clone();
        glib::timeout_add_local(std::time::Duration::from_millis(50), move || {
            let mut keep = true;
            while let Ok(ev) = rx.try_recv() {
                match ev {
                    AnalysisEvent::Progress { token, title } => {
                        if this.inner.ops.borrow().is_current(token) {
                            this.inner.banner.set_title(&title);
                        }
                    }
                    AnalysisEvent::Done {
                        token,
                        summary,
                        library,
                        refresh_error,
                    } => {
                        if !this.inner.ops.borrow().is_current(token) {
                            continue;
                        }
                        let publish = library.is_some();
                        this.finish_op(token, publish);
                        this.inner.last_analysis.replace(Some(summary.clone()));
                        if let Some(state) = library {
                            this.inner.state.replace(Some(state));
                            this.rebuild_all();
                        }
                        if let Some(err) = refresh_error {
                            this.toast(&err);
                        } else {
                            this.toast(&summary.toast_line());
                        }
                        this.sync_chrome();
                        keep = false;
                    }
                }
            }
            if keep {
                glib::ControlFlow::Continue
            } else {
                glib::ControlFlow::Break
            }
        });
    }

    fn availability(&self) -> LibraryAvailability {
        library_availability(
            self.inner.root.borrow().as_deref(),
            self.inner.state.borrow().as_ref(),
        )
    }

    fn rebuild_all(&self) {
        self.rebuild_folders();
        self.rebuild_photos(false);
        self.refresh_nav_root(&self.inner.collections_nav, self.collections_root());
        self.sync_chrome();
    }

    fn rebuild_folders(&self) {
        self.refresh_nav_root(&self.inner.folders_nav, self.folders_root_page());
    }

    fn refresh_nav_root(&self, nav: &adw::NavigationView, root: adw::NavigationPage) {
        let stack = nav.navigation_stack();
        let n = stack.n_items();
        if n <= 1 {
            replace_nav(nav, root);
            return;
        }
        let rest: Vec<adw::NavigationPage> = (1..n)
            .filter_map(|i| stack.item(i).and_downcast::<adw::NavigationPage>())
            .collect();
        let mut pages = Vec::with_capacity(rest.len() + 1);
        pages.push(root);
        pages.extend(rest);
        nav.replace(&pages);
    }

    fn folders_root_page(&self) -> adw::NavigationPage {
        match self.availability() {
            LibraryAvailability::NoneSelected => folder_status(
                "No Folder",
                "Choose a folder of photos to browse. Nothing is copied.",
                "Open Folder",
                self.clone(),
            ),
            LibraryAvailability::Unavailable => folder_status(
                "Folder Unavailable",
                "The saved library folder is gone or unreadable.",
                "Choose Folder",
                self.clone(),
            ),
            LibraryAvailability::Empty => folder_status(
                "Empty Folder",
                "This folder has no photos yet.",
                "Choose Another Folder",
                self.clone(),
            ),
            LibraryAvailability::Ready => {
                let state = self.inner.state.borrow();
                let root = state.as_ref().and_then(|s| s.root_folder.as_ref());
                match root {
                    Some(folder) if !folder.subfolders.is_empty() => {
                        self.folder_browser_page(folder, "Folders")
                    }
                    Some(folder) if !folder.photos.is_empty() => {
                        self.photo_grid_page(&folder.photos, folder.name.as_str())
                    }
                    _ => folder_status(
                        "Empty Folder",
                        "This folder has no photos yet.",
                        "Choose Another Folder",
                        self.clone(),
                    ),
                }
            }
        }
    }

    fn folder_browser_page(&self, folder: &PhotoFolder, title: &str) -> adw::NavigationPage {
        let grid = gtk::FlowBox::new();
        grid.set_selection_mode(gtk::SelectionMode::None);
        grid.set_homogeneous(true);
        grid.set_min_children_per_line(2);
        grid.set_max_children_per_line(6);
        grid.set_row_spacing(8);
        grid.set_column_spacing(8);
        grid.set_margin_top(12);
        grid.set_margin_bottom(12);
        grid.set_margin_start(12);
        grid.set_margin_end(12);
        for child in &folder.subfolders {
            grid.append(&self.folder_tile(child));
        }
        if !folder.photos.is_empty() && !folder.subfolders.is_empty() {
            let this = self.clone();
            let photos = folder.photos.clone();
            let name = folder.name.clone();
            let photos_btn = gtk::Button::builder()
                .label(format!("{} photos here", photos.len()))
                .build();
            photos_btn.add_css_class("pill");
            photos_btn.connect_clicked(move |_| {
                let page = this.photo_grid_page(&photos, &name);
                this.inner.folders_nav.push(&page);
            });
            let wrap = gtk::Box::new(Orientation::Vertical, 8);
            wrap.append(&photos_btn);
            wrap.append(&grid);
            return adw::NavigationPage::new(&scrolled(&wrap), title);
        }
        adw::NavigationPage::new(&scrolled(&grid), title)
    }

    fn folder_tile(&self, folder: &PhotoFolder) -> gtk::Widget {
        let picture = gtk::Picture::new();
        picture.set_content_fit(gtk::ContentFit::Cover);
        picture.set_can_shrink(true);
        picture.set_size_request(140, 140);
        if let Some(cover) = folder.cover_photo_url.as_ref() {
            if let Some(state) = self.inner.state.borrow().as_ref() {
                if let Some(photo) = state
                    .index
                    .sorted_photos()
                    .find(|p| p.path() == cover.path())
                {
                    self.inner.thumbs.bind_grid(
                        &picture,
                        photo.path(),
                        &photo.id.to_string(),
                        self.scale_factor(),
                    );
                }
            }
        }
        let name = gtk::Label::new(Some(&folder.name));
        name.add_css_class("heading");
        name.set_xalign(0.0);
        let count = gtk::Label::new(Some(&format!("{}", folder.total_photo_count)));
        count.add_css_class("dim-label");
        count.set_xalign(0.0);
        let labels = gtk::Box::new(Orientation::Vertical, 2);
        labels.append(&name);
        labels.append(&count);
        let box_ = gtk::Box::new(Orientation::Vertical, 6);
        box_.append(&picture);
        box_.append(&labels);
        let btn = gtk::Button::new();
        btn.set_child(Some(&box_));
        btn.add_css_class("flat");
        let this = self.clone();
        let id = folder.id;
        let title = folder.name.clone();
        btn.connect_clicked(move |_| {
            this.open_folder(id, &title);
        });
        btn.upcast()
    }

    fn open_folder(&self, id: StableId, title: &str) {
        let state = self.inner.state.borrow();
        let Some(root) = state.as_ref().and_then(|s| s.root_folder.as_ref()) else {
            return;
        };
        let Some(folder) = find_folder(root, id) else {
            return;
        };
        let page = if folder.subfolders.is_empty() {
            self.photo_grid_page(&folder.photos, title)
        } else {
            self.folder_browser_page(folder, title)
        };
        drop(state);
        self.inner.folders_nav.push(&page);
    }

    fn rebuild_photos(&self, wipe: bool) {
        let page = match self.availability() {
            LibraryAvailability::Ready => self.photos_tab_page(),
            other => empty_for(other, self.clone()),
        };
        if wipe {
            replace_nav(&self.inner.photos_nav, page);
        } else {
            self.refresh_nav_root(&self.inner.photos_nav, page);
        }
    }

    fn photos_tab_page(&self) -> adw::NavigationPage {
        let state = self.inner.state.borrow();
        let Some(lib) = state.as_ref() else {
            return empty_for(LibraryAvailability::Empty, self.clone());
        };
        let query = self.inner.search_entry.text().to_string();
        let required = self.inner.required_tags.borrow().clone();
        let (tags, _) = lib.suggestions();
        let photos: Vec<PhotoFile> = if query.is_empty() && required.is_empty() {
            lib.sorted_photos().into_iter().cloned().collect()
        } else {
            lib.index
                .search(&query, &required, &tags)
                .into_iter()
                .cloned()
                .collect()
        };
        drop(state);
        let chips = self.tag_chip_bar();
        let grid = self.photo_grid_widget(&photos);
        let box_ = gtk::Box::new(Orientation::Vertical, 0);
        box_.append(&chips);
        box_.append(&grid);
        adw::NavigationPage::new(&box_, "Photos")
    }

    fn tag_chip_bar(&self) -> gtk::Widget {
        let state = self.inner.state.borrow();
        let Some(lib) = state.as_ref() else {
            return gtk::Box::new(Orientation::Horizontal, 0).upcast();
        };
        let (tags, people) = lib.suggestions();
        let required = self.inner.required_tags.borrow().clone();
        let mut chips = leaf_tags(&tags);
        chips.extend(people);
        chips.sort_by(|a, b| b.count.cmp(&a.count).then_with(|| a.id.cmp(&b.id)));
        chips.truncate(20);
        for sel in &required {
            if !chips.iter().any(|c| c.id == sel.id) {
                chips.insert(0, sel.clone());
            }
        }
        drop(state);
        if chips.is_empty() {
            return gtk::Box::new(Orientation::Horizontal, 0).upcast();
        }
        let row = gtk::Box::new(Orientation::Horizontal, 6);
        row.set_margin_start(12);
        row.set_margin_end(12);
        row.set_margin_top(8);
        row.set_margin_bottom(4);
        for tag in chips {
            let active = required.iter().any(|t| t.id == tag.id);
            let this = self.clone();
            let label = tag.display_name.clone();
            let chip = cards::tag_chip(&label, active, move || {
                this.toggle_required_tag(&tag);
            });
            row.append(&chip);
        }
        let sw = gtk::ScrolledWindow::new();
        sw.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
        sw.set_propagate_natural_height(true);
        sw.set_child(Some(&row));
        sw.upcast()
    }

    fn toggle_required_tag(&self, tag: &TagSuggestion) {
        {
            let mut req = self.inner.required_tags.borrow_mut();
            if let Some(i) = req.iter().position(|t| t.id == tag.id) {
                req.remove(i);
            } else {
                req.push(tag.clone());
            }
        }
        if self.inner.stack.visible_child_name().as_deref() != Some("photos") {
            if let Some(child) = self.inner.stack.child_by_name("photos") {
                self.inner.stack.set_visible_child(&child);
            }
        }
        self.rebuild_photos(true);
    }

    fn on_search(&self, _query: &str) {
        if self.inner.stack.visible_child_name().as_deref() != Some("photos") {
            if let Some(child) = self.inner.stack.child_by_name("photos") {
                self.inner.stack.set_visible_child(&child);
            }
        }
        self.rebuild_photos(true);
    }

    fn photo_grid_page(&self, photos: &[PhotoFile], title: &str) -> adw::NavigationPage {
        adw::NavigationPage::new(&self.photo_grid_widget(photos), title)
    }

    fn photo_grid_widget(&self, photos: &[PhotoFile]) -> gtk::Widget {
        if photos.is_empty() {
            return status_page("No Photos", "Nothing matches.", "image-x-generic-symbolic")
                .upcast();
        }
        let store = gio::ListStore::new::<glib::BoxedAnyObject>();
        for (idx, photo) in photos.iter().enumerate() {
            store.append(&glib::BoxedAnyObject::new(PhotoRow::from_photo(idx, photo)));
        }
        let factory = gtk::SignalListItemFactory::new();
        let thumbs = self.inner.thumbs.clone();
        let scale = self.scale_factor();
        factory.connect_setup(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            let picture = gtk::Picture::new();
            picture.set_content_fit(gtk::ContentFit::Cover);
            picture.set_can_shrink(true);
            picture.set_size_request(140, 140);
            item.set_child(Some(&picture));
        });
        factory.connect_bind(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            let Some(boxed) = item.item().and_downcast::<glib::BoxedAnyObject>() else {
                return;
            };
            let Some(picture) = item.child().and_downcast::<gtk::Picture>() else {
                return;
            };
            let row = boxed.borrow::<PhotoRow>();
            if row.is_video {
                picture.set_alternative_text(Some("Video"));
                picture.set_paintable(Option::<&gtk::gdk::Paintable>::None);
            } else {
                match row.utf8_path() {
                    Ok(path) => thumbs.bind_grid(&picture, path, &row.id, scale),
                    Err(err) => {
                        picture.set_alternative_text(Some(&err.to_string()));
                        picture.set_paintable(Option::<&gtk::gdk::Paintable>::None);
                    }
                }
            }
        });
        let thumbs_unbind = thumbs.clone();
        factory.connect_unbind(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            if let Some(picture) = item.child().and_downcast::<gtk::Picture>() {
                thumbs_unbind.unbind(&picture);
            }
        });
        let sel = gtk::NoSelection::new(Some(store));
        let grid = gtk::GridView::new(Some(sel), Some(factory));
        grid.set_min_columns(2);
        grid.set_max_columns(6);
        grid.set_single_click_activate(true);
        grid.set_enable_rubberband(false);
        let all: Rc<Vec<PhotoFile>> = Rc::new(photos.to_vec());
        let this = self.clone();
        grid.connect_activate(move |_, pos| {
            this.open_viewer(&all, pos as usize);
        });
        scrolled(&grid).upcast()
    }

    fn open_viewer(&self, photos: &Rc<Vec<PhotoFile>>, idx: usize) {
        let Some(photo) = photos.get(idx) else {
            return;
        };
        let page = self.viewer_page(photo, photos.clone(), idx);
        self.inner.viewer_open.set(true);
        self.sync_chrome();
        current_nav(self).push(&page);
    }

    fn viewer_page(
        &self,
        photo: &PhotoFile,
        photos: Rc<Vec<PhotoFile>>,
        idx: usize,
    ) -> adw::NavigationPage {
        let picture = gtk::Picture::new();
        picture.set_content_fit(gtk::ContentFit::Contain);
        picture.set_hexpand(true);
        picture.set_vexpand(true);
        if !photo.is_video {
            self.inner.thumbs.bind_viewer(
                &picture,
                photo.path(),
                &photo.id.to_string(),
                self.viewer_max_side(),
            );
        }
        let click = gtk::GestureClick::new();
        let this = self.clone();
        click.connect_released(move |_, _, _, _| {
            this.inner.viewer_open.set(!this.inner.viewer_open.get());
            this.sync_chrome();
        });
        picture.add_controller(click);

        if photos.len() > 1 {
            let swipe = gtk::GestureSwipe::new();
            let this_s = self.clone();
            let photos_s = photos.clone();
            swipe.connect_swipe(move |_, vx, _| {
                if vx < -180.0 && idx + 1 < photos_s.len() {
                    this_s.replace_viewer(&photos_s, idx + 1);
                } else if vx > 180.0 && idx > 0 {
                    this_s.replace_viewer(&photos_s, idx - 1);
                }
            });
            picture.add_controller(swipe);
        }

        let overlay = gtk::Overlay::new();
        overlay.set_child(Some(&picture));
        let chrome = gtk::Box::new(Orientation::Horizontal, 6);
        chrome.set_halign(Align::End);
        chrome.set_valign(Align::Start);
        chrome.set_margin_top(8);
        chrome.set_margin_end(8);
        let info_btn = gtk::Button::from_icon_name("dialog-information-symbolic");
        info_btn.set_tooltip_text(Some("Photo info"));
        info_btn.add_css_class("circular");
        info_btn.add_css_class("osd");
        let short = self.inner.short.get();
        if photos.len() > 1 && !short {
            let prev = gtk::Button::from_icon_name("go-previous-symbolic");
            let next = gtk::Button::from_icon_name("go-next-symbolic");
            prev.add_css_class("circular");
            prev.add_css_class("osd");
            next.add_css_class("circular");
            next.add_css_class("osd");
            let this_p = self.clone();
            let photos_p = photos.clone();
            prev.connect_clicked(move |_| {
                if idx > 0 {
                    this_p.replace_viewer(&photos_p, idx - 1);
                }
            });
            let this_n = self.clone();
            let photos_n = photos.clone();
            next.connect_clicked(move |_| {
                if idx + 1 < photos_n.len() {
                    this_n.replace_viewer(&photos_n, idx + 1);
                }
            });
            chrome.append(&prev);
            chrome.append(&next);
        }
        chrome.append(&info_btn);
        overlay.add_overlay(&chrome);

        if photos.len() > 1 && !short {
            overlay.add_overlay(&self.filmstrip(&photos, idx));
        }

        let info = info_box(photo);
        let split = adw::OverlaySplitView::new();
        split.set_content(Some(&overlay));
        split.set_sidebar(Some(&scrolled(&info)));
        split.set_sidebar_position(gtk::PackType::End);
        split.set_collapsed(self.inner.compact.get() || self.inner.short.get());
        split.set_enable_hide_gesture(true);

        let this = self.clone();
        let photo_owned = photo.clone();
        let split_ref = split.clone();
        info_btn.connect_clicked(move |_| {
            if this.inner.compact.get() || this.inner.short.get() {
                this.show_info_sheet(&photo_owned);
            } else {
                split_ref.set_collapsed(!split_ref.is_collapsed());
            }
        });

        let page = adw::NavigationPage::new(&split, &viewer_title(photo));
        page.set_tag(Some("viewer"));
        page
    }

    fn filmstrip(&self, photos: &Rc<Vec<PhotoFile>>, idx: usize) -> gtk::Widget {
        let store = gio::ListStore::new::<gtk::StringObject>();
        for (i, photo) in photos.iter().enumerate() {
            store.append(&gtk::StringObject::new(&format!(
                "{i}\t{}\t{}\t{}\t{}",
                photo.path(),
                photo.id,
                u8::from(photo.is_video),
                u8::from(i == idx)
            )));
        }
        let factory = gtk::SignalListItemFactory::new();
        let thumbs = self.inner.thumbs.clone();
        let scale = self.scale_factor();
        factory.connect_setup(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            let picture = gtk::Picture::new();
            picture.set_content_fit(gtk::ContentFit::Cover);
            picture.set_size_request(48, 48);
            item.set_child(Some(&picture));
        });
        factory.connect_bind(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            let Some(s) = item.item().and_downcast::<gtk::StringObject>() else {
                return;
            };
            let Some(picture) = item.child().and_downcast::<gtk::Picture>() else {
                return;
            };
            let text = s.string();
            let mut parts = text.split('\t');
            let _i = parts.next();
            let Some(path) = parts.next() else { return };
            let Some(id) = parts.next() else { return };
            let is_video = parts.next() == Some("1");
            let current = parts.next() == Some("1");
            if current {
                picture.add_css_class("suggested-action");
            } else {
                picture.remove_css_class("suggested-action");
            }
            if is_video {
                picture.set_paintable(Option::<&gdk::Paintable>::None);
            } else {
                thumbs.bind_grid(&picture, path, id, scale);
            }
        });
        let thumbs_unbind = thumbs.clone();
        factory.connect_unbind(move |_, obj| {
            let item = obj
                .downcast_ref::<gtk::ListItem>()
                .expect("factory item")
                .clone();
            if let Some(picture) = item.child().and_downcast::<gtk::Picture>() {
                thumbs_unbind.unbind(&picture);
            }
        });
        let sel = gtk::SingleSelection::new(Some(store));
        sel.set_selected(idx as u32);
        let list = gtk::ListView::new(Some(sel), Some(factory));
        list.set_orientation(Orientation::Horizontal);
        list.set_single_click_activate(true);
        list.add_css_class("osd");
        let this = self.clone();
        let photos = photos.clone();
        list.connect_activate(move |_, pos| {
            this.replace_viewer(&photos, pos as usize);
        });
        let list_scroll = list.clone();
        let target = idx as u32;
        glib::idle_add_local_once(move || {
            list_scroll.scroll_to(target, gtk::ListScrollFlags::NONE, None::<gtk::ScrollInfo>);
        });
        let sw = gtk::ScrolledWindow::new();
        sw.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
        sw.set_propagate_natural_height(true);
        sw.set_halign(Align::Fill);
        sw.set_valign(Align::End);
        sw.add_css_class("osd");
        sw.set_child(Some(&list));
        sw.upcast()
    }

    fn replace_viewer(&self, photos: &Rc<Vec<PhotoFile>>, idx: usize) {
        let nav = current_nav(self);
        nav.pop();
        if let Some(photo) = photos.get(idx) {
            nav.push(&self.viewer_page(photo, photos.clone(), idx));
        }
    }

    fn show_info_sheet(&self, photo: &PhotoFile) {
        let dialog = adw::Dialog::new();
        dialog.set_title("Photo");
        dialog.set_content_width(540);
        dialog.set_child(Some(&scrolled(&info_box(photo))));
        dialog.present(&self.inner.window);
    }

    fn collections_root(&self) -> adw::NavigationPage {
        match self.availability() {
            LibraryAvailability::Ready => self.collections_hub(),
            other => empty_for(other, self.clone()),
        }
    }

    fn collections_hub(&self) -> adw::NavigationPage {
        let state = self.inner.state.borrow();
        let Some(lib) = state.as_ref() else {
            return empty_for(LibraryAvailability::Empty, self.clone());
        };
        let (tags, people) = lib.suggestions();
        let groups = collection_groups(&tags);
        let unnamed = faces::unnamed_faces(lib.index.photos());
        let events = lib
            .root_folder
            .as_ref()
            .map(event_folders)
            .unwrap_or_default();
        let compact = self.inner.compact.get() || self.inner.short.get();
        let people_side = if compact { 96 } else { 120 };
        let album_side = if compact { 112 } else { 140 };
        let rail_limit = if compact { 8 } else { 14 };

        let col = gtk::Box::new(Orientation::Vertical, 0);
        col.set_margin_bottom(24);

        if !people.is_empty() || !unnamed.is_empty() {
            let subtitle = if unnamed.is_empty() {
                format!("{}", people.len())
            } else {
                format!("{} · {} to review", people.len(), unnamed.len())
            };
            let people_nav = people.clone();
            let unnamed_nav = unnamed.clone();
            let this = self.clone();
            col.append(&cards::section_header("People", &subtitle, move || {
                this.push_people(&people_nav, &unnamed_nav);
            }));
            col.append(&self.people_rail(&people, &unnamed, people_side, compact, rail_limit));
        }

        for group in &groups {
            let leaves = leaf_tags(&group.tags);
            let preview: Vec<TagSuggestion> = leaves.iter().take(rail_limit).cloned().collect();
            let this = self.clone();
            let group_owned = group.clone();
            col.append(&cards::section_header(
                &group.name,
                &format!("{}", leaves.len()),
                move || this.push_album_grid(&group_owned),
            ));
            col.append(&self.album_rail(&preview, album_side));
        }

        if !events.is_empty() {
            let shown: Vec<PhotoFolder> = events
                .iter()
                .take(if compact { 6 } else { 12 })
                .cloned()
                .collect();
            col.append(&cards::section_header(
                "Events",
                &format!("{}", events.len()),
                {
                    let this = self.clone();
                    let all = events.clone();
                    move || this.push_events_list(&all)
                },
            ));
            for folder in &shown {
                col.append(&self.event_row_widget(folder));
            }
        }

        drop(state);
        adw::NavigationPage::new(&scrolled(&col), "Collections")
    }

    fn people_rail(
        &self,
        people: &[TagSuggestion],
        unnamed: &[UnnamedFace],
        side: i32,
        compact: bool,
        limit: usize,
    ) -> gtk::Widget {
        let mut cards_out: Vec<gtk::Widget> = Vec::new();
        if !unnamed.is_empty() {
            let this = self.clone();
            let unnamed = unnamed.to_vec();
            cards_out.push(cards::review_card(unnamed.len(), side, move || {
                this.push_face_review(&unnamed);
            }));
        }
        for tag in people.iter().take(limit) {
            cards_out.push(self.person_card(tag, side));
        }
        if compact || cards_out.len() <= 3 {
            cards::rail(cards_out)
        } else {
            let mut cols: Vec<Vec<gtk::Widget>> = Vec::new();
            let mut iter = cards_out.into_iter();
            while let Some(a) = iter.next() {
                let mut col = vec![a];
                if let Some(b) = iter.next() {
                    col.push(b);
                }
                cols.push(col);
            }
            cards::paired_rail(cols)
        }
    }

    fn album_rail(&self, tags: &[TagSuggestion], side: i32) -> gtk::Widget {
        cards::rail(tags.iter().map(|tag| self.album_card(tag, side)))
    }

    fn person_card(&self, tag: &TagSuggestion, side: i32) -> gtk::Widget {
        let picture = gtk::Picture::new();
        if let Some((photo, region)) = self.person_cover(tag) {
            if let Some(region) = region {
                self.inner.thumbs.bind_face(
                    &picture,
                    photo.path(),
                    &photo.id.to_string(),
                    self.scale_factor(),
                    &region,
                );
            } else {
                self.inner.thumbs.bind_grid(
                    &picture,
                    photo.path(),
                    &photo.id.to_string(),
                    self.scale_factor(),
                );
            }
        }
        let this = self.clone();
        let tag = tag.clone();
        let name = tag.display_name.clone();
        let count = format!("{}", tag.count);
        cards::cover_card(picture, &name, &count, side, move || {
            this.push_tag_photos(&tag)
        })
    }

    fn album_card(&self, tag: &TagSuggestion, side: i32) -> gtk::Widget {
        let picture = gtk::Picture::new();
        if let Some(photo) = self.tag_cover(tag) {
            self.inner.thumbs.bind_grid(
                &picture,
                photo.path(),
                &photo.id.to_string(),
                self.scale_factor(),
            );
        }
        let this = self.clone();
        let tag = tag.clone();
        let name = tag.display_name.clone();
        let count = format!("{}", tag.count);
        cards::cover_card(picture, &name, &count, side, move || {
            this.push_tag_photos(&tag)
        })
    }

    fn event_row_widget(&self, folder: &PhotoFolder) -> gtk::Widget {
        let picture = gtk::Picture::new();
        if let Some(photo) = self.folder_cover(folder) {
            self.inner.thumbs.bind_grid(
                &picture,
                photo.path(),
                &photo.id.to_string(),
                self.scale_factor(),
            );
        }
        let dates = event_date_range(folder);
        let this = self.clone();
        let id = folder.id;
        let title = folder.name.clone();
        cards::event_row(
            picture,
            &folder.name,
            &format!("{} photos", folder.photos.len()),
            dates.as_deref(),
            move || this.push_event_folder(id, &title),
        )
    }

    fn person_cover(&self, tag: &TagSuggestion) -> Option<(PhotoFile, Option<FaceRegion>)> {
        let state = self.inner.state.borrow();
        let lib = state.as_ref()?;
        let photos = lib.index.photos_for_tag(&tag.full_path);
        let with_face = photos
            .iter()
            .find(|p| faces::named_region_for(p, &tag.display_name).is_some())
            .map(|p| (*p).clone());
        let photo = with_face.or_else(|| photos.first().map(|p| (*p).clone()))?;
        let region = faces::named_region_for(&photo, &tag.display_name).cloned();
        Some((photo, region))
    }

    fn tag_cover(&self, tag: &TagSuggestion) -> Option<PhotoFile> {
        let state = self.inner.state.borrow();
        state
            .as_ref()?
            .index
            .photos_for_tag(&tag.full_path)
            .into_iter()
            .next()
            .cloned()
    }

    fn folder_cover(&self, folder: &PhotoFolder) -> Option<PhotoFile> {
        if let Some(url) = folder.cover_photo_url.as_ref() {
            let state = self.inner.state.borrow();
            if let Some(lib) = state.as_ref() {
                if let Some(photo) = lib
                    .index
                    .sorted_photos()
                    .find(|p| p.path() == url.path())
                    .cloned()
                {
                    return Some(photo);
                }
            }
        }
        folder.photos.first().cloned()
    }

    fn push_album_grid(&self, group: &CollectionGroup) {
        let leaves = leaf_tags(&group.tags);
        let tags = if leaves.is_empty() {
            group.tags.clone()
        } else {
            leaves
        };
        let flow = gtk::FlowBox::new();
        flow.set_selection_mode(gtk::SelectionMode::None);
        flow.set_homogeneous(true);
        flow.set_min_children_per_line(2);
        flow.set_max_children_per_line(6);
        flow.set_row_spacing(10);
        flow.set_column_spacing(10);
        flow.set_margin_top(12);
        flow.set_margin_bottom(16);
        flow.set_margin_start(16);
        flow.set_margin_end(16);
        let side = if self.inner.compact.get() { 140 } else { 168 };
        for tag in &tags {
            flow.append(&self.album_card(tag, side));
        }
        self.inner
            .collections_nav
            .push(&adw::NavigationPage::new(&scrolled(&flow), &group.name));
    }

    fn push_people(&self, people: &[TagSuggestion], unnamed: &[UnnamedFace]) {
        let flow = gtk::FlowBox::new();
        flow.set_selection_mode(gtk::SelectionMode::None);
        flow.set_homogeneous(true);
        flow.set_min_children_per_line(2);
        flow.set_max_children_per_line(6);
        flow.set_row_spacing(10);
        flow.set_column_spacing(10);
        flow.set_margin_top(12);
        flow.set_margin_bottom(16);
        flow.set_margin_start(16);
        flow.set_margin_end(16);
        let side = if self.inner.compact.get() { 120 } else { 140 };
        if !unnamed.is_empty() {
            let this = self.clone();
            let unnamed = unnamed.to_vec();
            flow.append(&cards::review_card(unnamed.len(), side, move || {
                this.push_face_review(&unnamed);
            }));
        }
        for tag in people {
            flow.append(&self.person_card(tag, side));
        }
        self.inner
            .collections_nav
            .push(&adw::NavigationPage::new(&scrolled(&flow), "People"));
    }

    fn push_events_list(&self, events: &[PhotoFolder]) {
        let col = gtk::Box::new(Orientation::Vertical, 0);
        col.set_margin_bottom(16);
        for folder in events {
            col.append(&self.event_row_widget(folder));
        }
        self.inner
            .collections_nav
            .push(&adw::NavigationPage::new(&scrolled(&col), "Events"));
    }

    fn push_event_folder(&self, id: StableId, title: &str) {
        let state = self.inner.state.borrow();
        let Some(root) = state.as_ref().and_then(|s| s.root_folder.as_ref()) else {
            return;
        };
        let Some(folder) = find_folder(root, id) else {
            return;
        };
        let page = self.photo_grid_page(&folder.photos, title);
        drop(state);
        self.inner.collections_nav.push(&page);
    }

    fn push_face_review(&self, unnamed: &[UnnamedFace]) {
        let list = gtk::ListBox::new();
        list.add_css_class("boxed-list");
        list.set_selection_mode(gtk::SelectionMode::None);
        list.set_margin_top(18);
        list.set_margin_start(18);
        list.set_margin_end(18);
        list.set_margin_bottom(18);
        let scale = self.scale_factor();
        let cache = config::ml_cache_path();
        let clusters = session::people::unlabeled_clusters(&cache).unwrap_or_default();
        if clusters.is_empty() {
            for face in unnamed {
                let filename = std::path::Path::new(&face.path)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or(&face.path);
                let row = adw::ActionRow::builder()
                    .title(filename)
                    .subtitle("Scan Photos with faces to name")
                    .activatable(false)
                    .build();
                let picture = gtk::Picture::new();
                picture.set_size_request(48, 48);
                picture.set_content_fit(gtk::ContentFit::Cover);
                self.inner.thumbs.bind_face(
                    &picture,
                    &face.path,
                    &face.photo_id,
                    scale,
                    &face.region,
                );
                row.add_prefix(&picture);
                list.append(&row);
            }
        } else {
            for cluster in clusters {
                let thumb = session::people::cluster_thumb(&cache, cluster.id)
                    .ok()
                    .flatten();
                let subtitle = format!("{} faces", cluster.size);
                let row = adw::ActionRow::builder()
                    .title("Unnamed person")
                    .subtitle(subtitle)
                    .activatable(true)
                    .build();
                if let Some(thumb) = thumb {
                    let region = face_region_from_bbox(thumb.bbox, thumb.image_w, thumb.image_h);
                    let picture = gtk::Picture::new();
                    picture.set_size_request(48, 48);
                    picture.set_content_fit(gtk::ContentFit::Cover);
                    self.inner.thumbs.bind_face(
                        &picture,
                        &thumb.path,
                        &format!("cluster-{}", cluster.id),
                        scale,
                        &region,
                    );
                    row.add_prefix(&picture);
                }
                row.add_suffix(&gtk::Image::from_icon_name("document-edit-symbolic"));
                let this = self.clone();
                let id = cluster.id;
                row.connect_activated(move |_| this.prompt_name_cluster(id));
                list.append(&row);
            }
        }
        let clamp = adw::Clamp::new();
        clamp.set_child(Some(&list));
        self.inner
            .collections_nav
            .push(&adw::NavigationPage::new(&scrolled(&clamp), "Review"));
    }

    fn prompt_name_cluster(&self, cluster_id: i64) {
        if !session::ml_enabled() {
            self.toast("Rebuild with --features ml to name people");
            return;
        }
        if session::discover_pack().is_none() {
            self.toast("No model pack — Scan Photos with faces first");
            return;
        }
        let dialog = adw::MessageDialog::new(
            Some(&self.inner.window),
            Some("Name this person"),
            Some("Writes through the face engine, same as iOS."),
        );
        dialog.add_response("cancel", "Cancel");
        dialog.add_response("name", "Name");
        dialog.set_response_appearance("name", adw::ResponseAppearance::Suggested);
        dialog.set_default_response(Some("name"));
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("Name"));
        entry.set_hexpand(true);
        dialog.set_extra_child(Some(&entry));
        let this = self.clone();
        dialog.connect_response(None, move |_, response| {
            if response != "name" {
                return;
            }
            this.name_cluster(cluster_id, &entry.text());
        });
        dialog.present();
    }

    fn name_cluster(&self, cluster_id: i64, name: &str) {
        let Some(pack) = session::discover_pack() else {
            self.toast("No model pack");
            return;
        };
        let Some(state) = self.inner.state.borrow().clone() else {
            return;
        };
        let root = state.root.to_str().map(str::to_string);
        match session::people::name_cluster(
            config::ml_cache_path(),
            &pack.directory,
            cluster_id,
            name,
            root.as_deref(),
        ) {
            Ok(paths) => match reapply_sidecars(state, Some(&paths)) {
                Ok(next) => {
                    self.inner.state.replace(Some(next));
                    self.rebuild_all();
                    self.toast(&format!("Named {name}"));
                }
                Err(e) => self.toast(&e.to_string()),
            },
            Err(e) => self.toast(&e),
        }
    }

    fn push_tag_photos(&self, tag: &TagSuggestion) {
        let state = self.inner.state.borrow();
        let Some(lib) = state.as_ref() else {
            return;
        };
        let photos: Vec<PhotoFile> = lib
            .index
            .photos_for_tag(&tag.full_path)
            .into_iter()
            .cloned()
            .collect();
        let title = tag.display_name.clone();
        drop(state);
        self.inner
            .collections_nav
            .push(&self.photo_grid_page(&photos, &title));
    }

    fn show_preferences(&self) {
        let page = adw::PreferencesPage::new();
        page.set_title("Preferences");

        let library = adw::PreferencesGroup::new();
        library.set_title("Library");
        let folder_row = adw::ActionRow::builder()
            .title("Folder")
            .subtitle(
                self.inner
                    .root
                    .borrow()
                    .as_ref()
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|| "Not chosen".into()),
            )
            .build();
        let change = gtk::Button::with_label("Change");
        change.add_css_class("pill");
        let this = self.clone();
        change.connect_clicked(move |_| this.pick_folder());
        folder_row.add_suffix(&change);
        library.add(&folder_row);

        let reload = adw::ActionRow::builder()
            .title("Reload folder")
            .activatable(true)
            .build();
        let this = self.clone();
        reload.connect_activated(move |_| this.reload_current());
        library.add(&reload);
        page.add(&library);

        let pack = session::discover_pack();
        let photo_count = self
            .inner
            .state
            .borrow()
            .as_ref()
            .map(|s| s.index.photos().len())
            .unwrap_or(0);
        let scan = adw::PreferencesGroup::new();
        scan.set_title("Scan Photos");
        scan.set_description(Some(&session::readiness_blurb(pack.as_ref(), photo_count)));

        let pack_row = adw::ActionRow::builder()
            .title("Model pack")
            .subtitle(match &pack {
                Some(p) => format!(
                    "{} · {}{}",
                    if p.version.is_empty() {
                        p.name.as_str()
                    } else {
                        p.version.as_str()
                    },
                    p.source_label(),
                    if p.has_faces { " · faces" } else { "" }
                ),
                None => "None found".into(),
            })
            .build();
        scan.add(&pack_row);

        let run = adw::ActionRow::builder()
            .title("Scan Photos")
            .subtitle("Tag → faces → places")
            .activatable(true)
            .build();
        let start = gtk::Button::with_label("Start");
        start.add_css_class("pill");
        start.add_css_class("suggested-action");
        let this = self.clone();
        start.connect_clicked(move |_| this.start_analysis());
        run.add_suffix(&start);
        let this = self.clone();
        run.connect_activated(move |_| this.start_analysis());
        scan.add(&run);

        if let Some(last) = self.inner.last_analysis.borrow().as_ref() {
            let last_row = adw::ActionRow::builder()
                .title("Last run")
                .subtitle(last.toast_line())
                .build();
            scan.add(&last_row);
        }
        page.add(&scan);

        let dialog = adw::PreferencesDialog::new();
        dialog.add(&page);
        dialog.present(&self.inner.window);
    }

    fn show_about(&self) {
        let about = adw::AboutDialog::new();
        about.set_application_name("LocalGallery");
        about.set_developer_name("Johannes");
        about.set_version("0.1.0");
        about.set_comments("A folder-based photo gallery. Same library as the iOS app.");
        about.set_website("https://github.com/j23n/localgallery");
        about.set_license_type(gtk::License::MitX11);
        about.present(&self.inner.window);
    }
}

enum ScanEvent {
    Progress {
        token: OpToken,
        msg: String,
        done: usize,
        total: usize,
    },
    Done {
        token: OpToken,
        result: Result<LibraryState, String>,
    },
}

enum AnalysisEvent {
    Progress {
        token: OpToken,
        title: String,
    },
    Done {
        token: OpToken,
        summary: AnalysisSummary,
        library: Option<LibraryState>,
        refresh_error: Option<String>,
    },
}

fn tab_title(window: &Window) -> &'static str {
    match window.inner.stack.visible_child_name().as_deref() {
        Some("folders") => "Folders",
        Some("photos") => "Photos",
        Some("collections") => "Collections",
        _ => APP_TITLE,
    }
}

fn current_nav(window: &Window) -> adw::NavigationView {
    match window.inner.stack.visible_child_name().as_deref() {
        Some("folders") => window.inner.folders_nav.clone(),
        Some("collections") => window.inner.collections_nav.clone(),
        _ => window.inner.photos_nav.clone(),
    }
}

fn replace_nav(nav: &adw::NavigationView, page: adw::NavigationPage) {
    while nav.pop() {}
    nav.replace(&[page]);
}

fn add_breakpoints(window: &adw::ApplicationWindow) {
    let compact = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
        adw::BreakpointConditionLengthType::MaxWidth,
        550.0,
        adw::LengthUnit::Sp,
    ));
    window.add_breakpoint(compact);

    let short = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
        adw::BreakpointConditionLengthType::MaxHeight,
        700.0,
        adw::LengthUnit::Sp,
    ));
    window.add_breakpoint(short);
}

fn app_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    menu.append(Some("Preferences"), Some("win.preferences"));
    menu.append(Some("Open Folder"), Some("win.open-folder"));
    menu.append(Some("Reload"), Some("win.reload"));
    menu.append(Some("Scan Photos"), Some("win.scan-photos"));
    menu.append(Some("About LocalGallery"), Some("win.about"));
    menu
}

fn nav_status(title: &str, desc: &str, icon: &str) -> adw::NavigationPage {
    adw::NavigationPage::new(&status_page(title, desc, icon), title)
}

fn status_page(title: &str, desc: &str, icon: &str) -> adw::StatusPage {
    let page = adw::StatusPage::new();
    page.set_title(title);
    page.set_description(Some(desc));
    page.set_icon_name(Some(icon));
    page
}

fn folder_status(title: &str, desc: &str, button: &str, window: Window) -> adw::NavigationPage {
    let page = status_page(title, desc, "folder-pictures-symbolic");
    let btn = gtk::Button::with_label(button);
    btn.add_css_class("suggested-action");
    btn.add_css_class("pill");
    btn.set_halign(Align::Center);
    btn.connect_clicked(move |_| window.pick_folder());
    page.set_child(Some(&btn));
    adw::NavigationPage::new(&page, title)
}

fn empty_for(avail: LibraryAvailability, window: Window) -> adw::NavigationPage {
    match avail {
        LibraryAvailability::NoneSelected => folder_status(
            "No Folder",
            "Choose a folder of photos to browse.",
            "Open Folder",
            window,
        ),
        LibraryAvailability::Unavailable => folder_status(
            "Folder Unavailable",
            "The saved library folder is gone or unreadable.",
            "Choose Folder",
            window,
        ),
        LibraryAvailability::Empty | LibraryAvailability::Ready => folder_status(
            "No Photos",
            "This folder has no photos yet.",
            "Choose Another Folder",
            window,
        ),
    }
}

fn face_region_from_bbox(bbox: [f32; 4], image_w: u32, image_h: u32) -> FaceRegion {
    let w = image_w.max(1) as f64;
    let h = image_h.max(1) as f64;
    FaceRegion {
        name: None,
        center_x: ((bbox[0] + bbox[2]) as f64 / 2.0) / w,
        center_y: ((bbox[1] + bbox[3]) as f64 / 2.0) / h,
        width: (bbox[2] - bbox[0]).abs() as f64 / w,
        height: (bbox[3] - bbox[1]).abs() as f64 / h,
    }
}

fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    let sw = gtk::ScrolledWindow::new();
    sw.set_child(Some(child));
    sw.set_vexpand(true);
    sw.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    sw
}

fn event_date_range(folder: &PhotoFolder) -> Option<String> {
    time::format_local_day_range(folder.photos.iter().filter_map(|p| p.date_taken))
}

fn viewer_title(photo: &PhotoFile) -> String {
    photo
        .date_taken
        .map(time::format_local_day)
        .unwrap_or_else(|| photo.filename.clone())
}

fn info_box(photo: &PhotoFile) -> gtk::Box {
    let box_ = gtk::Box::new(Orientation::Vertical, 12);
    box_.set_margin_top(18);
    box_.set_margin_bottom(18);
    box_.set_margin_start(18);
    box_.set_margin_end(18);

    let list = gtk::ListBox::new();
    list.add_css_class("boxed-list");
    list.set_selection_mode(gtk::SelectionMode::None);

    let date = photo.date_taken.map(time::format_local_datetime);
    list.append(&info_row("Date", date.as_deref().unwrap_or("—")));
    list.append(&info_row("File", &photo.filename));
    if let (Some(lat), Some(lon)) = (photo.gps_latitude, photo.gps_longitude) {
        list.append(&info_row("GPS", &format!("{lat:.5}, {lon:.5}")));
    }
    if let Some(cc) = &photo.country_code {
        list.append(&info_row("Country", cc));
    }
    if photo.is_video {
        list.append(&info_row("Type", "Video"));
    }
    let faces = photo
        .face_regions
        .iter()
        .filter_map(|r| r.name.as_deref())
        .collect::<Vec<_>>();
    if !faces.is_empty() {
        list.append(&info_row("Faces", &faces.join(", ")));
    } else if !photo.face_regions.is_empty() {
        list.append(&info_row(
            "Faces",
            &format!("{} unnamed", photo.face_regions.len()),
        ));
    }
    box_.append(&list);

    if !photo.hierarchical_tags.is_empty() {
        let tags = adw::PreferencesGroup::new();
        tags.set_title("Tags");
        for tag in &photo.hierarchical_tags {
            tags.add(
                &adw::ActionRow::builder()
                    .title(&tag.display_name)
                    .subtitle(&tag.full_path)
                    .build(),
            );
        }
        box_.append(&tags);
    }

    let sidecar = if sidecar_exists(&StdVfs, photo.path()) {
        sidecar_path(photo.path())
    } else {
        "No sidecar on disk".into()
    };
    let side = adw::ActionRow::builder()
        .title("Sidecar")
        .subtitle(sidecar)
        .build();
    let wrap = gtk::ListBox::new();
    wrap.add_css_class("boxed-list");
    wrap.append(&side);
    box_.append(&wrap);
    box_
}

fn info_row(title: &str, subtitle: &str) -> adw::ActionRow {
    adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .build()
}
