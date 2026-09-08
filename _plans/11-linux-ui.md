# Linux UI — GNOME, laptop and Mecha Comet

A GTK4 / libadwaita app that talks to the Rust crates in-process (no UniFFI).
Same library, same sidecars, same scan / tag / face / places engines as iOS.
**One binary, two first-class windows:** a normal GNOME laptop (header
switcher, inspector pane, filmstrip) and the same process maximized on a
Mecha Comet. Nothing is Comet-only or laptop-only except chrome density.
Collapse is `AdwBreakpoint` in `sp` (Large Text still fits).

The sketches in `_sketches/linux-ui/` are the *wide* mood. This plan is the
information architecture and the collapse rules. Do not treat the sketches'
six-item sidebar as the nav: iOS has three tabs, and GNOME's view switcher
wants three or four peers.

Laptop and Comet are both required. The Comet is the *smallest* window we
size for (not a tall phone). Mechanix OS is a custom Wayland shell (GPUI /
Flutter natives), not GNOME — a libadwaita app is a guest client. That is
fine: Fedora aarch64 packages run, and HDMI/USB-C display-out is a normal
wide laptop-style window.

## Standing decisions

1. **Toolkit: Relm4 + libadwaita 1.6+.** Rust throughout; crates are called
   directly. Relm4 is how Amberol / Fragments stay on Adwaita without writing
   XML by hand. gtk-rs alone is a fallback if Relm4 fights a widget.
2. **Adwaita chrome, not a custom iOS skin.** Header bars, boxed lists, toasts,
   bottom sheets, and the system dark/high-contrast preference all come from
   the platform. The photo *canvas* can stay a quiet warm/neutral field; the
   chrome follows `prefers-color-scheme`. Fighting Adwaita breaks both
   GNOME and a short Mechanix window.
3. **Three primary views, matching iOS:** Folders · Photos · Collections.
   People and Memories live *inside* Collections. Settings is a preferences
   dialog, not a fourth tab.
4. **Breakpoints use `sp`.** Window `width-request` 360, `height-request` 294
   (libadwaita floor). Design and QA lock is the Comet at 2× (below), not a
   390×844 phone.
5. **v1 is browse + scan.** Folder pick, library walk, grids, viewer, info,
   Scan Photos (tag → faces → places). Memories slideshow, MP4 export,
   contacts, iCloud, and widgets stay iOS-only until the session crate exists.
6. **Comet is browse-first.** Sidecars already travel (Syncthing). Heavy
   tagging / faces can run on a desktop or iPhone; the handheld must stay
   usable on 4 GB and must not assume a GNOME session.

## Non-goals (v1)

- Reimplementing scan policy / memory gating in the UI (call the core; if a
  rule is still Swift-only, port the rule first — see the boundary note).
- A custom thumbnail decoder in the core. Use `Glycin` or GDK pixbuf for
  display; ML still uses the core's pinned decode.
- Flatpak-only distribution in the first spike (run from the source tree).
  Metainfo + a `.desktop` file are written so Mechanix Search / a later
  Flatpak can launch it.
- Rewriting the UI in Flutter / mechanix.dart. The Comet runs Fedora
  packages; GNOME on a desk and GTK-on-Mechanix share one binary.
- Using the i.MX NPU in v1. Analysis stays the existing ONNX path, at
  conservative concurrency.

## Mecha Comet (first-class small screen)

Current Comet panel (mecha.so / datasheet, 2026 unit):

| | |
|---|---|
| Panel | 3.92″ AMOLED, 1080×1240, 5-point touch, ~500–550 nits |
| Density | √(1080²+1240²) / 3.92 ≈ **419 PPI** |
| Aspect | 27∶31 — slightly taller than square, **not** phone-tall |
| Chassis | 73×155×14 mm (keyboard / gamepad / GPIO snaps on *below* the panel) |
| SoC | i.MX 8M Plus (4× A53, Vivante GC7000UL, EtnaViv GLES 2.1, 2.3 TOPS) or i.MX 95 (6× A55, Mali-G310, up to 8 TOPS) |
| RAM | 2 / 4 / 8 GB (design for **4 GB**; 2 GB is browse-only) |
| OS | Mechanix OS (Fedora 43, Linux 6.12, custom Wayland shell) |
| Out | Mini-HDMI / DP-over-USB-C — same app, wide layout |

**Scale.** 419 PPI wants integer 2× on a Wayland client (96×2 = 192 CSS-dpi;
a theoretical GNOME 4× would make chrome enormous). At **2×** GTK sees:

```
logical  540 × 620
physical 1080 × 1240
```

That matches the “UI is 2×” recollection. Confirm on-device with
`gdk_surface_get_scale()` / the compositor’s `wl_output` scale the first
time a Comet is in hand. If Mechanix leaves the output at 1×, GTK chrome
will be unreadably small — then set the output scale to 2 (or
`GDK_SCALE=2` only as a last resort; Wayland-native scale is preferred).

Also size for **1.5×** (720×827) and **2.5×** (432×496) in case Settings
exposes a slider. 540×620 remains the lock.

**Height is the scarce resource.** A typical phone logical canvas is
~390×844. The Comet is *wider and much shorter*. Header (~46) +
`ViewSwitcherBar` (~56) leave ~518 px of content; a search bar or scan
banner on top of that drops you under 450. Do not stack desktop chrome.

Comet-only collapse (add a `max-height: 700sp` breakpoint, or
`max-width: 550sp and max-height: 700sp`):

- Bottom `ViewSwitcherBar` (540 < 550sp). Three short labels, not a sidebar.
- No filmstrip in the viewer; chrome hides on tap.
- No overlay inspector — info is a bottom sheet, half-height max.
- Search lives in the header toggle; do not leave `AdwSearchBar` + banner
  + switcher up at once. If a scan is running, the banner *replaces* the
  search bar.
- `AdwStatusPage` uses the compact size; no large illustrations.
- Preferences is a **full NavigationPage** (or a dialog that fills the
  window), never a floating 700-px preferences window.
- Grid: **2 columns** at 540 (tiles ~250 logical / 500 physical). 3
  columns only if tile min-width is dropped to ~110.
- Collections hub is a single scrolling boxed list, no side-by-side rails.
- Viewer is full-bleed; switcher bar hidden.

**Input.** Finger-first (44×44 px minimum). The keyboard module adds keys
and a trackpad — shortcuts still work, hover-only actions still do not.
Five-point touch: pinch-zoom in the viewer is in scope for v1 if cheap.

**GPU / GTK renderer.** 8M Plus is EtnaViv **OpenGL ES 2.1**. GTK4’s ngl
/ Vulkan paths are likely to fail or crawl. First Comet boot must try
`GSK_RENDERER` in order: `gl`, then `cairo`. Ship a `.desktop` `Exec`
wrapper that falls back. Prefer **GDK / pixbuf** for display decode on
this SoC; Glycin’s sandbox is extra RAM and another GPU client. Mali on
the 95 can revisit Glycin.

**CPU / RAM.** ONNX tagging + faces on 4× A53 will be slow and memory-
hungry. Host defaults on `MemAvailable < 3 GB`: analysis threads = 1,
faces off unless the user starts them, thumb decode capped (≤512 px).
The product story is: **scan where there is CPU, browse the Comet**.
Sidecars make that true without a sync protocol of our own.

**Docked.** HDMI/USB-C out is a second output or the only one. Same
process, same breakpoints: a 1080p@1× or 2× desktop monitor is the wide
layout. Do not special-case “Comet + monitor” beyond following window
size.

**Dev fixture (no hardware yet).** A nested window or mutter/weston
output at **540×620 logical, scale 2** (buffer 1080×1240). Step 1 of the
build-out must open in that size and stay usable. Also open a 1200×800
window so the wide path does not rot.

## Layout

Two libadwaita patterns, nested:

```
AdwApplicationWindow
  breakpoint max-width: 550sp
    → reveal ViewSwitcherBar, hide header ViewSwitcher
    → collapse OverlaySplitView (inspector)
  breakpoint max-height: 700sp
    → Comet chrome: no filmstrip, compact StatusPage, prefs fill window
  breakpoint max-width: 800sp
    → collapse inspector only (header switcher still fits)

  AdwToolbarView
    top:    AdwHeaderBar
              title-widget: AdwViewSwitcher (wide)  — Folders | Photos | Collections
              start: back (when NavigationView can pop)
              end:   search toggle, menu (Preferences, About)
    content: AdwViewStack
              folders     → AdwNavigationView (folder tiles → folder grid)
              photos      → AdwNavigationView (all-photos grid → viewer)
              collections → AdwNavigationView (hub → tag/people/memory/review)
    bottom: AdwViewSwitcherBar (narrow only)
            hidden while the viewer page is on top
```

Inspector (photo info, selected person) is an `AdwOverlaySplitView` on the
*content* page, not a third window column. Wide: utility pane. Narrow:
`AdwDialog` as a bottom sheet (`presentation` follows parent width).

```
wide (≥800sp)                 Comet 2× (540×620)
┌──────────┬────────┬─────┐   ┌──────────────────┐
│ header   │        │     │   │ header + back    │  ~46
│ switcher │ grid   │info │   │ 2-col grid       │  ~518
├──────────┤        │     │   ├──────────────────┤
│          │        │     │   │ Folders Photos … │  ~56
└──────────┴────────┴─────┘   └──────────────────┘
```

Grid columns follow the same window, not a separate breakpoint object:
2 @ 360–540 (Comet), 3 @ 550–700, 4 @ 700, 5–6 @ 1000. `GtkGridView`
with a `GtkSignalListItemFactory` and a tile min-width (~140px; ~110px
only if we ever need 3 columns on the Comet). Decode thumbs at
`tile_css × window_scale` so 2× stays sharp.

## Navigation map

```
Folders ── tile ──► folder browser ── tile ──► folder grid ──► viewer
Photos  ── search/tags ──► all-photos grid ──► viewer
Collections
   ├── tag root / tag ──► tag grid ──► viewer
   ├── People ──► people list ──► person grid ──► viewer
   │                └── Review ──► cluster grid ──► cluster ──► name / merge
   └── Memory (v2) ──► slideshow
Preferences (dialog on a desk; full page on the Comet)
   ├── Library (folder, reload, cancel)
   ├── Scan Photos (tag / faces / places + activity)
   ├── People (me, hidden)          — no Contacts in v1
   └── About
First-run StatusPage ──► GtkFileDialog (select folder)
```

Deep links (iOS widgets) do not exist. A later `.desktop` `MimeType` /
`%f` can open a folder; that is a v2.

## Pages

**First run / empty / unavailable.** `AdwStatusPage`. Three copies of the iOS
empty states: no folder, folder gone, folder empty. One button each.

**Folders.** `GtkGridView` of cover tiles (name + count). Push a browser page
when the folder has subfolders; push a photo grid when it is a leaf. Same
rule as `AppRouter.applyFolder`.

**Photos.** Date-sorted `GtkGridView` over `LibraryIndex::sorted_photo_ids`.
`AdwSearchBar` filters through `LibraryIndex::search`. Required-tag chips
reuse the index, not a Swift-side filter.

**Collections hub.** Not a photo grid. Boxed groups: tag roots (Objects,
Scenes, Places, People, …) with counts; a People row that appears when
`PeopleSectionVisibility` would (`named || reviewable || scanning`); a
Memories row that can stay "coming" in v1.

**People / review.** List + cluster grid. Merge/name/ignore call the core
(`face_merge_direction`, `name_cluster`, …). Crops from MWG rectangles on
the *display* thumbnail, same as iOS — no pixels across a crate boundary.

**Viewer.** A `AdwNavigationPage` pushed on the current stack (so back is
the system gesture). Filmstrip along the bottom on wide **and tall**;
hidden on the Comet (`max-height: 700sp`) and behind a tap. Info is the
overlay pane on a desk, a half-height bottom sheet on the Comet: capture
date, camera EXIF (platform decode is fine), hierarchical chips, faces
summary, sidecar on-disk. Delete/move stay behind a confirmation
`AdwAlertDialog`.

**Scan.** Preferences row starts `LibraryAnalysis`-equivalent sequencing
in the host. Progress is an `AdwBanner` on every primary view plus a
Preferences row (the Comet has no status bar). Cancel is on the banner.
On short windows the banner replaces the search bar so chrome does not
stack.
Activity is a subpage of Preferences, not a main destination.

## Host (the Linux `GalleryStore`)

A Relm4 component, main-context, owns:

- library root path (XDG config)
- `ScannerSession` / scan-kind policy (until that moves into a session crate)
- `LibraryIndex` + the in-process photo table (`gallery-model::PhotoFile`)
- `TaggingSession` / `FaceSession` / geocode runner
- `inotify` on directories only, muted during an analysis run (same rule as
  `LibraryRootMonitor.shouldIgnoreEvents`)

Long work stays on core threads; progress hops to the GTK main context
with `glib::MainContext::default().invoke`. No UniFFI object table — the
host holds `PhotoFile` values and the index returns ids.

Paths: XDG config for prefs, Freedesktop thumbnail cache +
`gallery-cache.sqlite` under XDG cache,
XDG data for an imported model pack. Bundled pack from
`/usr/share/localgallery/pack/<version>` or the source-tree `build/pack`.
`resolve_model_pack` already decides which wins.

VFS: `StdVfs`. `ProviderProbe` stays the default (local files). Folder
access is a path the user picked; portal/`GtkFileDialog` is enough under
Flatpak later.

## Display vs ML decode

| Job | Who |
|---|---|
| Grid / folder covers | XDG `large` (256) at 1×, `x-large` (512) at 2×. Never ML. |
| Viewer | original file, window long side × scale, cap **2000** (same as iOS) |
| Tagging / faces | core pinned path, working copy ≤ `ANALYSIS_MAX_LONG_SIDE` (2048) |
| Face crops in the UI | display thumbnail + MWG rect |

Do not send viewer or XDG pixels into Scan Photos. Do not invent a private
thumb size or a 2048 display cache.

## Responsive checklist

| Window | Nav | Inspector | Grid | Viewer |
|---|---|---|---|---|
| ≥800sp wide | header `ViewSwitcher` | overlay pane | 4–6 | filmstrip + pane |
| 550–800sp | header `ViewSwitcher` | dialog / sheet | 3–4 | filmstrip, sheet for info |
| ≤550sp tall (phone) | bottom `ViewSwitcherBar` | bottom sheet | 2–3 | full page, tap for chrome, bar hidden |
| **Comet 540×620 @ 2×** | bottom bar | half-height sheet | **2** | full-bleed, no filmstrip, bar hidden |

Also:

- Hover-only actions get a menu equivalent (`AdwHeaderBar` overflow).
- Confirmation and preferences use `AdwDialog` (auto window vs sheet).
- Toasts (`AdwToastOverlay`) for "sidecar written" / errors; no modal
  success dialogs.
- Touch: `AdwNavigationView` swipe-back; viewer swipe between photos.
- Hide the view switcher bar on the viewer page so the photo is full-bleed.

## Suggested crate layout

```
linux/                      # later: fine to extract with core/
  Cargo.toml                # gtk4, libadwaita, relm4, gallery-*
  data/
    app.desktop
    app.metainfo.xml
    icons/
  src/
    main.rs
    app.rs                  # AdwApplication
    window.rs               # breakpoints, stack, switcher
    host.rs                 # library state, scan, analysis
    pages/{folders,photos,collections,viewer,people,prefs,activity}.rs
    widgets/{photo_grid,folder_tile,person_crop,tag_chip}.rs
    thumbs.rs               # XDG thumb cache
```

Not a workspace member of `core/` (that workspace is the portable crates).
`linux/` depends on them by path. UniFFI is unused.

## Build-out order

1. **Empty window** — Relm4 + libadwaita, three-page stack, breakpoints
   flipping the switcher, StatusPage. No core. Must be usable at the
   **540×620 / scale 2** fixture *and* at 1200×800.
2. **Folder + scan** — `GtkFileDialog` → `ScannerSession` → folder tiles
   and a photo grid. Proves `StdVfs` + snapshot on Linux.
3. **Index + search** — `LibraryIndex` over the in-process photo table.
4. **Viewer + info** — NavigationPage, Glycin/GDK decode, sidecar via
   `read_sidecar` / `SidecarView`.
5. **Scan Photos** — tagging + faces + places, banner progress, activity
   page. Host `HeicDecoder` only if software HEVC is too slow.
6. **People review** — clusters, name, merge (core `face_merge_direction`).
7. **Polish** — `.desktop`, metainfo, inotify, dark-style canvas, Flatpak
   manifest (not a requirement to start).

Memories rail and slideshow are after 6; they need the coordinator rules
in a session crate or they will drift from iOS. That extraction — plus
Nominatim in core — is `_plans/12-session-host.md`.

## Open choices (pick before 1)

- **Header switcher vs always-on sidebar on desktop.** This plan uses a
  header `ViewSwitcher` (HIG, three peers). A `ViewSwitcherSidebar` on
  ≥1000sp is an optional extra, not v1.
- **Glycin vs GDK** for display. Default **GDK on Comet**, Glycin
  optional on desktop (Mali / Intel / AMD). Revisit after the first
  Comet boot.
- **App id:** `com.j23n.LocalGallery` to match iOS / GitHub, unless you
  want a `linux` suffix.
- **Confirm 2× on hardware.** If Mechanix ships 1× or 1.5×, adjust the
  fixture; do not hard-code 540×620 as a pixel size in widgets — only as
  the QA window.

## What not to copy from the sketches

- A six-row sidebar with Settings as a peer. Settings is a dialog.
- A permanent status bar. Use `AdwBanner` / toasts.
- Light-only chrome. Follow the system style.
- iOS tab icons in a GNOME header. Use `AdwViewSwitcher` labels + symbolic
  icons (`folder-symbolic`, `image-x-generic-symbolic`,
  `view-grid-symbolic` / a people symbolic).
