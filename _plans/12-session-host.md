# Session host + shared geocoder

iOS and Linux both call the same engines. They do **not** yet share the host
that decides when to scan, in what order, and what to ignore. That policy is
already forked. This is the extraction — not more UI, not more ONNX.

**Status:** landed in `gallery-geo` + `gallery-session`. iOS Places lookup
is Nominatim via FFI (`nominatimLookup`); rebuild the xcframework. Linux
calls the session crate in-process.

**Exit criterion:** Scan Photos, pack resolution, Places lookup, people
*writes*, and watch-mute are one Rust implementation. Each app is a shell
(progress hop, geocode URL, filesystem watcher, chrome). UniFFI is the iOS
binding, not the product API.

## Standing decisions

1. **`gallery-session`** owns orchestration. Existing crates keep engines and
   sidecar bytes. `linux/` stays outside the `core/` workspace.
2. **`gallery-ffi` becomes a thin UniFFI skin** over the session crate plus
   thread/run-lock glue. Linux never uses UniFFI.
3. **One Nominatim in core** (`gallery-geo`, or a module on the session crate).
   Not CLGeocoder, not a per-host HTTP client. Places paths are sidecar truth;
   two geocoders is a determinism hole. iOS already forces `en_US` so Apple
   names match photo-tools / Nominatim (`Places/France`, not
   `Places/Frankreich`).
4. **People writes go through `FaceEngine`.** Linux `faces::name_region` →
   `write_faces` Partial is a second people product; delete it. Crops stay on
   the host (display thumb + MWG). If the Linux build has no ONNX, Review
   refuses to name.
5. **Scan-kind policy (light / auto / full, 48 h) stays iOS** until Linux
   actually needs it. Snapshot reuse in `open_library` is enough for a desktop
   folder.
6. **Do not put HTTP on `gallery-meta`.** That crate stays offline. Do not
   keep CLGeocoder as an offline fallback.

## Refactoring list

In this order:

1. **Stop the people-naming fork.** Linux review names via `FaceEngine` /
   `name_cluster` (same replace-set as iOS). Merge / unname / ignore wait on
   that path, not on a sidecar-only helper.

2. **`gallery-geo` — Nominatim is the geocoder.**
   - `accept-language: en`, required User-Agent, 1 req/s.
   - Map JSON through the same collapse (`city|town|village` →
     `place_from_parts`).
   - Own the haversine cache iOS already has (Linux is missing it).
   - `ReverseGeocoder` trait; tests replay **recorded fixtures**, never live
     OSM.
   - Endpoint is injected (same as the cache DB path). Public
     `nominatim.openstreetmap.org` is not a product backend — self-host or a
     paid provider for real libraries.
   - First iOS cutover: log non-prefix changes (`United States` vs
     `United States of America`). Prefix-upgrade handles shallower Apple
     tags; a different country string is a fork.
   - Privacy: GPS leaves the device. Offline Places is skip/retry, not an
     Apple cache. Say so in Settings.

3. **One `run_analysis`.** Phase order tag → faces → places, cancel,
   progress, `written_paths`. Hosts only hop progress to the main thread and
   draw the banner.

4. **One Places eligibility + `force`.** Always `places_still_needed` (and
   the sidecar-aware write skip iOS has). Queue and write path must not
   disagree.

5. **Pack host adapter.** Enumeration of roots + manifest peek lives once;
   `resolve_model_pack` stays in `gallery-ml`.

6. **Watch mute + debounce constant.** 1.5 s, muted while any analysis/scan
   is writing sidecars. inotify / vnode / `NSFilePresenter` stay on the
   host.

7. **Sidecar refresh plan.** Session returns `{ paths, needs_walk }`. iOS
   keeps the 30 s coalescer as a *scheduler*; Linux may apply immediately.
   Decision of what to refresh is shared.

8. **ML eligibility.** Still, readable, not a remote placeholder. One
   function both hosts call.

Leave on the platform: bookmarks / XDG, ImageIO / Freedesktop thumbs, GTK /
SwiftUI, Contacts, widgets, memories *chrome* (engine is already core).

## What stays out of this pass

- Merging `linux/` into the `core/` workspace.
- Moving thumbnail decode or GTK into core.
- Porting iOS scan-kind timing “because it exists.”
- Memories rail on Linux (needs this session crate first, then chrome).

## Pointers

- Drift that motivated this: iOS `LibraryAnalysis` vs `linux/src/analysis.rs`;
  `PackResolver` vs `linux/src/pack.rs`; `GeocodingService` vs
  `linux/src/places.rs`; `FaceService.nameCluster` vs `linux/src/faces.rs`
  `name_region`.
- Write rules already shared: `gallery_meta::{write_places, write_faces}`,
  `places_still_needed`, `place_from_parts`, `FaceEngine::name_cluster`.
- Linux UI plan: `_plans/11-linux-ui.md` (shell only after this lands).
