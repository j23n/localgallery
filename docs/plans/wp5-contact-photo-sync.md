# WP5 — Manual crop + contact-photo sync for linked people

Goal: let the user pick the exact crop that represents a person across
the app, and (opt-in) push that cropped image to the matching system
Contact's avatar with a side-by-side confirmation. The work splits
into three layers: a square-aspect manual crop UI that runs on every
"set featured photo" action, a per-person normalized-rect store, and
a Contacts write path gated by a Settings toggle and a per-write
confirmation sheet.

File paths and line numbers reflect the branch state at plan authoring;
expect drift after each pass.

---

## Design summary

- **One existing primitive carries the in-app side.**
  `featuredPhotoByPerson: [String: UUID]`
  (LocalGallery/Services/GalleryStore.swift:53) records which photo
  represents a person; the existing context-menu entry in
  `PhotoGridScreen` (LocalGallery/Views/PhotoGridScreen.swift:543)
  sets it. We bolt a new mandatory crop step onto that flow and add
  a parallel `featuredCropByPerson` store.
- **Manual crop is the default — no auto fallback.** Every time the
  user marks a photo as a person's featured photo, the crop sheet
  opens; the user must save a square crop before the featured photo
  is recorded. `FaceRegion`s are flaky in practice (third-party
  taggers vary), so we don't use them as a fallback or even as a
  preset prefill — the crop sheet opens at the image center and the
  user adjusts. Single, predictable flow with no branching on whether
  a face region happens to be present.
- **`PersonThumbnailView` keeps its current behavior for un-featured
  people.** People without an entry in `featuredPhotoByPerson`
  continue to render via the existing face-region path in
  `PersonThumbnailView.crop(_:to:)`
  (LocalGallery/Components/PersonThumbnailView.swift). That's status
  quo for the tile view. Once a person has a featured photo, the
  manual crop wins and face regions are not consulted for that person.
- **One canonical cropped image per person.** A single square,
  normalized `CGRect` (0…1, top-left origin — same coordinate space
  as `FaceRegion` at LocalGallery/Models/FaceRegion.swift) persists
  per person path. It drives both the in-app `PersonThumbnailView`
  and, when sync is enabled, the contact's `imageData`. No separate
  "contact crop."
- **Sync gate: linked contact + featured photo set.** Not gated by
  `featuredPeople`. Any person that the user sets a featured photo
  for, *and* that resolves to a `CNContact` via
  `ContactLinker.effectiveContact(...)`
  (LocalGallery/Services/ContactLinker.swift), is a sync candidate.
  The "favorite people" feature is unrelated.
- **Per-write confirmation, not silent.** When sync is on and the
  user saves a crop for a linked person, a confirmation sheet shows
  the contact's current photo and the new cropped image side by side;
  the user explicitly continues or aborts. Aborting cancels the
  whole operation — no featured-photo change, no crop saved, no
  contact write. This matches iOS conventions for destructive
  confirmations (Photos, Contacts) and keeps the mental model simple:
  with sync on, "set featured photo" means "set the contact photo."
- **Last-write-wins on the contact.** We don't snapshot prior
  `imageData` and don't restore on disable. The per-write
  confirmation is the safety net; nothing leaves the device without
  the user seeing a before/after first.

---

## Work items

### 1. Manual crop UI

New SwiftUI view `PersonCropView`, presented as a sheet from the
existing "Mark as featured" context-menu entry in `PhotoGridScreen`
(PhotoGridScreen.swift:543) and from a new "Adjust crop" entry that
appears in the same menu when the photo is already featured for the
active person.

- Square viewport (matches both the round contact avatar and the
  square `PersonCard` tile in CollectionsView.swift:478).
- Initial crop = center square of the source image, clamped to image
  bounds. No face-region preset.
- Drag pans the image; magnification gesture zooms. A reset button
  re-centers to the initial crop.
- Output is a `CGRect` in the original image's normalized coordinate
  space, *not* a pre-rendered bitmap. We re-crop on demand the same
  way `PersonThumbnailView` does today. Keeps the on-disk footprint
  identical to current state.
- "Save" updates two stores in one call: `featuredPhotoByPerson` and
  the new `featuredCropByPerson`. If sync is on and the person is
  linked, it then routes through the confirmation sheet (work item 7)
  before either store is committed — abort discards both.

### 2. Per-person crop store

Add to `GalleryStore`:

```swift
@Observable @MainActor
final class GalleryStore {
    // …
    private(set) var featuredCropByPerson: [String: NormalizedRect] = [:]
    // …
}
```

Where `NormalizedRect` is a small `Codable, Hashable` value with four
`Double`s (centerX, centerY, width, height — same shape as
`FaceRegion`, dropping `name`). Persisted as a JSON-encoded
UserDefaults dict under `"featuredCropByPerson"`, sibling to the
existing `"featuredPhotoByPerson"` block (GalleryStore.swift:366).

Setter API:

- `setFeaturedCrop(personPath: String, rect: NormalizedRect)`
- `clearFeaturedCrop(personPath: String)` — removes the override.
- `featuredCrop(for personPath: String) -> NormalizedRect?` — read
  helper used by `PersonThumbnailView` and the sync service.

`PersonThumbnailView` gains one new branch at the top of its crop
resolution: if `store.featuredCrop(for: personPath)` returns a value,
use it. Otherwise fall back to the current face-region / center-crop
path unchanged (this only matters for people without a featured
photo set; people *with* a featured photo always have a crop after
this WP lands).

### 3. Crop-aware image renderer

Pull the crop math out of `PersonThumbnailView.crop(_:to:)` into a
small free function or `enum PersonImageRenderer` namespace so the
crop sheet, the tile view, and the sync service all share one
implementation. Two entry points:

- `renderForTile(image:rect:)` — returns a `UIImage` sized for the
  person tile.
- `renderForContact(image:rect:)` — returns JPG `Data` at e.g.
  1024×1024, suitable for `CNMutableContact.imageData`.

Both share the same crop-rect resolution so the in-app and on-contact
images are visually identical.

### 4. ContactsService — read + write surface

Today `ContactsService` is a read-only protocol
(LocalGallery/Services/ContactsService.swift). Add:

```swift
protocol ContactsServicing {
    // existing reads…
    func imageData(forContactID id: String) async throws -> Data?
    func updateImage(contactID: String, imageData: Data) async throws
}
```

`imageData(forContactID:)` is needed for the confirmation sheet's
"current photo" pane. `LiveContactsService` implementation:

- **Read**: `unifiedContact(withIdentifier:keysToFetch:)` with
  `CNContactImageDataKey`. Returns `nil` when the contact has no
  image.
- **Write**:
  1. Fetch via `unifiedContact(withIdentifier:keysToFetch:)` with
     `CNContactImageDataKey` + identifiers.
  2. `mutableCopy()` to get a `CNMutableContact`, set `imageData`.
  3. Wrap in a `CNSaveRequest`, call `store.execute(_:)`.
  4. Bubble up `CNError` cases verbatim — the caller decides what to
     surface.

The fake in tests gets in-memory equivalents.

### 5. Permissions

- Update `NSContactsUsageDescription` in LocalGallery/Info.plist:
  > LocalGallery uses your contacts to surface birthday memories for
  > the people in your photos and, if you enable contact-photo sync,
  > to set a contact's photo to the image you've chosen for that
  > person. Names are matched only against your photo tags.
- The sync toggle requires `.authorized` access — `.limited` does not
  permit `CNContactStore.save(_:)` for arbitrary contacts in
  practice. On first toggle-on, call `requestAccess()` and only
  proceed if the result is `.authorized`. If the user is stuck on
  `.limited`, show a dismissible inline note in Settings linking to
  the system Settings app.

### 6. Settings toggle

In `SettingsView` → People section, below the existing "Birthday
Memories" toggle:

- `Toggle("Sync contact photos", isOn: $store.syncContactPhotos)`
- Footer:
  > When on, the photo you choose for a person who is linked to a
  > contact is offered as that contact's avatar. You'll see a
  > before/after preview each time before anything is written.
- First time the toggle is flipped on, request `.authorized`
  Contacts access if not already granted; the per-write confirmation
  sheet is the primary safety net so no separate first-enable
  confirmation is needed beyond the permission prompt.

Persistence pattern matches existing toggles (UserDefaults via a
`didSet` on the `@Observable` property; key `"syncContactPhotos"`).

### 7. Confirmation sheet

New view `ContactPhotoConfirmSheet`, presented after the user taps
"Save" in `PersonCropView` when both:

- `syncContactPhotos` is on, and
- the person resolves to a `CNContact` via `effectiveContact(...)`.

Layout:

- Two square thumbnails side by side: "Current" (the contact's
  existing `imageData`, or a placeholder when none) and "New" (the
  freshly cropped image, rendered via `renderForContact`).
- Person name + linked contact name below.
- Primary button: "Replace contact photo". Secondary: "Cancel".

Behavior:

- **Replace** → commit `featuredPhotoByPerson` + `featuredCropByPerson`,
  then call `ContactsService.updateImage(...)`. On `CNError`, surface
  inline in the sheet ("Couldn't update contact: <message>") with
  retry / cancel; the in-app stores are *not* rolled back since
  in-app featuring works regardless of the contact write.
- **Cancel** → discard the crop and the featured-photo change. The
  user is back to whatever featured photo (if any) was set before.

When sync is off OR the person isn't linked, the crop sheet's "Save"
commits both stores directly with no confirmation, and no contact
write happens. That's the path for everyday in-app featuring.

### 8. Sync service + non-confirmation triggers

New `ContactPhotoSyncService` (`@MainActor final class`) injected
into `GalleryStore`. Hosts the actual write call so it can be reused
by the confirmation sheet and by the explicit "Sync now" entries
in the linked contacts list.

- `prepare(personPath: String) async -> SyncPreview?` — resolves the
  contact, loads current `imageData`, loads the featured photo,
  renders the new image, returns a struct with both `Data` blobs and
  the contact ID. Returns `nil` if any prerequisite is missing
  (no featured photo, no link, no image). Used by the confirmation
  sheet.
- `commit(preview: SyncPreview) async throws` — calls
  `ContactsService.updateImage`. Used by the confirmation sheet's
  Replace button and by the linked-contacts list's "Sync now".

No automatic fire-and-forget triggers. Every contact write goes
through either the per-save confirmation sheet or an explicit
"Sync now" tap. Toggle-on does *not* batch-write; if the user wants
to backfill, they use "Sync all" in the linked contacts list (work
item 9), which still routes each write through the confirmation
sheet.

### 9. Linked contacts list — sync UI

In `LinkedContactsList` (PeopleContactLinking.swift), add a per-row
trailing affordance when sync is enabled:

- Idle: nothing (row already shows the contact name).
- Last-write error: small SF Symbol `exclamationmark.triangle.fill`
  in warning color; tap shows the error message.
- An overflow menu with:
  - **Sync now** — opens the confirmation sheet for this person
    using their existing featured crop. Disabled if no featured
    photo is set.
  - **Clear contact photo** — writes empty `Data()` to the contact
    after a small confirmation. Per-contact opt-out independent of
    the global toggle.

A list-level "Sync all" button at the bottom (visible when toggle is
on and ≥1 linked person has a featured photo) walks the list and
opens the confirmation sheet sequentially. The user can cancel any
single confirmation without aborting the whole batch.

---

## Out of scope

- **Per-photo crop persistence.** The crop is per *person*, not per
  photo. Switching the featured photo invalidates the crop (rects
  are relative to the previous photo's frame). Behavior: changing
  `featuredPhotoByPerson` clears `featuredCropByPerson` for that
  person; the new crop sheet opens immediately for the new photo.
- **Contact creation.** We never create new contacts. If a person
  tag has no resolved contact, the confirmation sheet doesn't appear
  and the in-app featuring path runs unchanged.
- **Group-photo handling.** A photo with multiple People/ tags only
  affects the *active* person — the one the context menu was invoked
  under. The same photo can be featured for multiple people; each
  gets its own crop and (if linked + sync on) its own confirmation
  sheet.
- **Live restore on toggle-off.** No image-data snapshotting. The
  per-write confirmation is the safety net.
- **Background sync.** All writes run on user action (confirmation
  sheet or explicit "Sync now"). No BGTask wiring.
- **Watch / share-extension targets.** Out of scope for this WP.

---

## Order of implementation

1. Extract crop math into `PersonImageRenderer` (no behavior change).
2. Add `NormalizedRect` model + `featuredCropByPerson` store +
   persistence + `PersonThumbnailView` resolution branch.
3. Build `PersonCropView` sheet; wire it as a *required* step
   before `setFeaturedPhoto(...)` commits, in
   `PhotoGridScreen` context menu.
4. Add `ContactsService.imageData(forContactID:)` +
   `updateImage(...)` + fakes.
5. Add `ContactPhotoSyncService` (`prepare` / `commit`).
6. Build `ContactPhotoConfirmSheet` and wire it as the post-save
   step in `PersonCropView` when sync is on + person is linked.
7. Settings toggle + Info.plist copy + permission handling.
8. `LinkedContactsList` per-row + list-level sync UI.

Steps 1–3 are independently shippable in-app value (manual crop in
`PersonThumbnailView`); the contact-write path doesn't turn on until
step 7 lands.
