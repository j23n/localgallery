# Mutations, storage, and backup

What the apps write, where it lives, and what to copy if you care
about the library.

## Library folder (source of truth)

Photos and videos stay ordinary files. The apps also:

| Action | What happens |
|---|---|
| Scan Photos / tagging / faces / Places | Writes or updates `photo.jpg.xmp` next to the file. Image bytes are not rewritten. |
| Name / rename / merge people | Updates People keywords and MWG regions in that sidecar. |
| Move photo | Moves the image and its companions (sidecar, Live Photo pair, etc.) into another folder in the library. |
| Delete photo | Deletes the image and its companions. |
| Create folder | Creates a directory in the library tree. |

These are explicit user or Scan Photos actions, not background
rewrites of the originals. Confirmations apply to delete and move.

Current tagging writer treats `Objects/*` and `Scenes/*` as a replace
set for those roots; People, Places, Landmarks, and bare keywords are
left alone. The standing policy is narrower
([ADR 0001](adr/0001-xmp-ownership.md)): retract only sentinel-owned
claims. Unrelated XML is preserved on the DOM path.

Places: GPS is sent to Nominatim; the resulting `Places/…` path is
written to the sidecar.

## Caches (recomputable)

| Store | Typical location | Contents |
|---|---|---|
| `gallery-cache.sqlite` | iOS Application Support; Linux XDG data | ML queues, embeddings, face clusters |
| Library snapshot JSON | App cache | Last tree + optional sidecar manifest (v20) |
| Memories cache | App cache | Generated rail; evicted if the library snapshot version mismatches |
| Sidecar parse cache (iOS) | App cache | Parsed XMP for evicted provider files |
| Thumbnails | iOS disk cache; Linux Freedesktop `thumbnails/large` and `x-large` | Display only |
| Geo cache | App support / XDG | Nominatim results by coordinates |
| Widget snapshots (iOS) | App Group | Pre-rendered tiles and deep-link ids |

Deleting caches does not delete photos or sidecars. The next scan or
analysis rebuilds them.

## Backup

Copy the **library folder**, including every `.xmp`. That is the
portable gallery. Application Support / XDG caches are optional; they
only save time.

If you sync with Syncthing (or SyncTrain on iOS), include sidecars.
Exclude `gallery-cache.sqlite` if you sync the same folder the app
uses as a library — the cache is per-device.

## File-provider folders (iOS)

Non-local items stay placeholders until opened. Sidecars can be
fetched in bulk and cached so tags remain searchable after the
provider evicts the `.xmp`. Clearing downloads does not remove
sidecars you already have on disk in the folder.
