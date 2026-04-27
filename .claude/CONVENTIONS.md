# Conventions

Shared conventions for the **localfiles** family of iOS apps:
[localgallery](https://github.com/j23n/localgallery),
[localcontacts](https://github.com/j23n/localcontacts),
[localmusic](https://github.com/j23n/localmusic).

These apps all do the same thing: make a folder of files (photos, vCards, audio)
a first-class iOS citizen — no library import, no cloud account, the file system
is the source of truth. They should look, feel, and read like one product.

This document is the source of truth for cross-app standards. When you change
it, mirror the change to all three repos (see [Sync](#sync) at the bottom).

## How to read this document

- **Rules** are prescriptive ("do X, not Y") with rationale.
- **Per-app status** tables track where each repo currently stands vs. the rule.
  Cells marked with a GitHub issue link are tracked migrations.

---

## 1. Per-app status snapshot

| Convention | localgallery | localcontacts | localmusic |
|---|---|---|---|
| Deployment target iOS 18 | ❌ iOS 17 | ✅ | ❌ iOS 17 |
| Swift 6 strict concurrency | ❌ Swift 5, `minimal` | ✅ Swift 6, `complete` | ❌ Swift 5, none |
| `@Observable` state | ❌ `ObservableObject` | ✅ | ❌ `ObservableObject` |
| Decomposed Store + Services | ❌ one mega-manager | ✅ | ✅ |
| `Models/` `Services/` `Views/` layout | ❌ flat | ✅ | ❌ flat |
| `Log.<category>` (`os.Logger`) | ✅ | ❌ `print` | ❌ `print` |
| SHA-256 stable IDs | ❌ MD5 | n/a | ✅ |
| Swift Testing | ❌ no tests | ✅ | ❌ XCTest |
| Tests in CI | ❌ | ✅ (in build.yml) | ✅ (separate test.yml) |
| `macos-26` runner | ✅ | ❌ `macos-15` | ❌ `macos-15` |
| Bundle ID `com.localX.app` | ✅ | ✅ | ❌ `com.folderplayer` |
| Settings UX (`List` + sections) | ✅ canonical | ✅ | ✅ |
| Folder access flow | ✅ | ✅ | ✅ |
| Atomic file writes | ✅ | ✅ | ✅ |
| Scene-phase rescan | ❌ | ✅ | ❌ |

Each `❌` should be tracked by a migration issue in the relevant repo.

---

## 2. Project layout

Each app is a single Xcode project generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The `.xcodeproj` is **not
checked in** — `xcodegen` regenerates it from `project.yml` on demand.

```
LocalX.xcodeproj         # generated, gitignored
LocalX/
  LocalXApp.swift        # @main entry; tabs / scene wiring only
  Models/                # value types: Contact, Track, PhotoFile, …
  Services/              # I/O, parsers, stores: ContactsStore, MetadataLoader, …
  Views/                 # SwiftUI views, one per file
  Components/            # shared SwiftUI primitives (ThumbnailView, etc.)
  Shared/                # only when a second target needs the types
  Logging.swift          # Log.<category> namespace (see §6)
  Design.swift           # design tokens (see §10)
  Info.plist
  LocalX.entitlements
  Assets.xcassets/
LocalXTests/
  README.md              # documents test conventions + refactor seams
  Fixtures.swift         # shared builders
  …Tests.swift
project.yml
README.md
LICENSE                  # MPL 2.0
.claude/
  CLAUDE.md              # repo-specific Claude Code guide (optional)
  CONVENTIONS.md         # cross-app conventions (this file, mirrored — see §18)
.github/workflows/
  build.yml              # archive + IPA on tag (see §15)
  test.yml               # tests on PR (see §15)
.gitignore
```

**Why subfolders.** Xcode is happy with a flat directory, but once an app has
20+ source files, navigation cost compounds. Subfolders are the cheapest
intervention.

**Why `Shared/`.** When a second target (a widget extension, a watch app)
needs to compile some types, put them in `Shared/` and list the path under
both targets in `project.yml`. Cross-process state goes through files in the
App Group, never via in-memory references — see localgallery's `project.yml`
comment for the canonical statement.

---

## 3. Build settings

Set these in every `project.yml`:

```yaml
options:
  deploymentTarget:
    iOS: "18.0"
  xcodeVersion: "16.0"

settings:
  base:
    SWIFT_VERSION: "6.0"
    IPHONEOS_DEPLOYMENT_TARGET: "18.0"
    SWIFT_STRICT_CONCURRENCY: complete
```

**iOS 18 baseline.** Current iOS is 26 (April 2026). iOS 18 is two majors back —
covers ~95 % of in-use iPhones and unlocks `@Observable` propagation, modern
`NavigationStack` behaviour, and Swift 6 concurrency. Bumping further (iOS 19+)
is fine when the App Store usage data justifies it.

**Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.** This is non-negotiable.
The whole architecture (next section) depends on the compiler enforcing actor
isolation. Use of `@unchecked Sendable` is allowed only with a comment
explaining what invariant the human is upholding instead of the compiler.

**iOS 26 features** (e.g. `scrollEdgeEffectStyle(.soft)`) may be adopted via
`#available(iOS 26.0, *)` checks for progressive enhancement. localgallery's
`softTopScrollEdge()` extension is the model.

---

## 4. State management

Use Apple's **Observation framework** (`@Observable`), not Combine
(`ObservableObject` / `@Published` / `@StateObject` / `@EnvironmentObject`).

```swift
import Observation

@Observable
@MainActor
final class ContactsStore {
    var contacts: [Contact] = []
    var folderURL: URL?
    // …
}
```

In views:

```swift
struct ContactListView: View {
    @Environment(ContactsStore.self) private var store
    // …
}
```

In the app entry:

```swift
@main
struct LocalContactsApp: App {
    @State private var store = ContactsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
```

**Why.** `@Observable` re-evaluates only views that *read* a changed property
(field-level granularity), avoids `@Published`'s Combine overhead, and composes
cleanly with Swift 6 isolation. `ObservableObject` is the iOS 13–16 pattern.

**One Store per app, decomposed by responsibility.** The Store owns
view-facing state. I/O and protocol concerns (bookmarks, parsers, system
integrations) live in separate service types it composes. localcontacts is
the canonical example: `ContactsStore` + `BookmarkManager` +
`FolderAccessManager` + `CNSyncService` + `VCardParser` + `VCardWriter`.

**Avoid `static var shared` on the Store.** A SwiftUI-injected `@State`
lifetime is enough. If a non-SwiftUI entry point (BG task handler, app
extension) needs access, expose a small actor or value-type service for that
specific need — don't hand it the whole store.

---

## 5. Folder access (security-scoped bookmarks)

This is the central feature of all three apps. The flow is identical and
should not be invented per app.

### 5.1 Document picker

A trivial wrapper, identical across all three:

```swift
struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
```

### 5.2 Picker callback dance

The picker hands you a URL with a transient security scope. **Claim it
synchronously in the callback**, save the bookmark, release, then dispatch
the rescan as a `Task`:

```swift
.sheet(isPresented: $showFolderPicker) {
    DocumentPicker { pickerURL in
        // Transient scope must be claimed and turned into a bookmark
        // synchronously — not from inside a Task.
        _ = pickerURL.startAccessingSecurityScopedResource()
        bookmarkManager.saveBookmark(for: pickerURL)
        pickerURL.stopAccessingSecurityScopedResource()
        Task { await store.adoptSavedFolder() }
    }
}
```

### 5.3 Bookmark service

Bookmark persistence is its own type with `UserDefaults` injected (see §13
on testability):

```swift
final class BookmarkManager {
    private let defaults: UserDefaults
    static let bookmarkKey = "folderBookmark"

    init(userDefaults: UserDefaults = .standard) { self.defaults = userDefaults }

    func saveBookmark(for url: URL) throws { /* … */ }
    func loadBookmark() -> URL? { /* with isStale handling */ }
    func clearBookmark() { /* … */ }
}
```

### 5.4 Lifecycle: restore on launch + rescan on resume

Restore once on launch via `.task`; rescan when the app returns to the
foreground via `scenePhase`. Local files can change while the app is
backgrounded (Files.app, Syncthing, etc.) — re-checking on resume is the
right default.

```swift
@Environment(\.scenePhase) private var scenePhase

WindowGroup {
    ContentView()
        .environment(store)
        .task { await store.restoreFolder() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.checkForExternalChanges() }
            }
        }
}
```

---

## 6. Logging

Use `os.Logger` through a `Log` namespace. Never use `print(...)` outside
test code.

```swift
import os

enum Log {
    private static let subsystem = "localcontacts"

    static let scan   = Logger(subsystem: subsystem, category: "scan")
    static let store  = Logger(subsystem: subsystem, category: "store")
    static let sync   = Logger(subsystem: subsystem, category: "sync")
    static let ui     = Logger(subsystem: subsystem, category: "ui")
}

// Usage:
Log.scan.info("Scanning folder \(url.path, privacy: .private)")
Log.store.error("Failed to save: \(error.localizedDescription)")
```

**Why.** `os.Logger` integrates with Console.app, supports privacy redaction,
filters by category and level, has lazy interpolation (free when filtered
out), and survives release builds. `print` writes to stderr and disappears.

**Gotcha.** `os.Logger` interpolations are `@escaping @autoclosure`. Inside
a closure you must write `self.foo` explicitly — the compiler will complain
otherwise.

**Categories** are app-specific (gallery has `scan`, `enrich`, `thumb`,
`cache`, `index`, `memory`, `bg`, `widget`, …). The set should reflect the
app's actual subsystems, not be copy-pasted.

---

## 7. Settings sheet

Every app has a Settings sheet, and it should look the same. localgallery's
is the canonical version; all three apps already follow it closely.

### Shape

```swift
struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            List {
                // 1. Folder section — always first
                Section("<Domain> Folder") {  // "Photo Library", "Contacts Folder", "Music Folder"
                    Button {
                        showFolderPicker = true
                    } label: {
                        LabeledContent {
                            Text(store.folderURL?.lastPathComponent ?? "Not selected")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Folder", systemImage: "folder")
                        }
                    }
                    .tint(.primary)        // suppress accent on the chevron

                    Button("Reload <Domain>") {     // "Reload Library", "Reload Contacts", "Reload Music"
                        Task { await store.rescan() }
                    }

                    if let lastSync = store.lastSyncedAt {
                        LabeledContent("Last Synced") {
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // 2. Domain-specific sections (People, Tags, Sync, …)

                // 3. Info section — always last data section
                Section("Info") {
                    LabeledContent("<Items>", value: "\(store.items.count)")
                    LabeledContent("Version", value: appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showFolderPicker) { /* picker dance from §5.2 */ }
        }
    }
}
```

### Rules

- **Folder section first**, **Info section last**, domain sections in between.
- **Folder row** uses `LabeledContent` + `Label("Folder", systemImage: "folder")`.
- `.tint(.primary)` on the folder Button to suppress accent on the chevron
  (otherwise it inherits the app accent, which clashes with the muted label).
- **Reload button** label is `Reload <Domain>`, not "Refresh" or "Sync".
- **Done** in `.toolbar` at `.confirmationAction`.
- **`.navigationBarTitleDisplayMode(.inline)`** — the small inline title.
- **Counts in Info** — single source of truth for "how big is this thing."

---

## 8. App shell & navigation

### When to use a TabView

If the app has **two or more independent top-level surfaces**, use a TabView
with one `NavigationStack` per tab. Otherwise (localcontacts) just have a
single root view that switches between an empty-state folder picker and the
main content.

```swift
// Multi-surface (gallery, music)
TabView(selection: $router.selectedTab) {
    NavigationStack(path: $router.foldersPath) { FolderBrowserView() /* … */ }
        .tabItem { Label("Folders", systemImage: "folder") }

    NavigationStack { AllPhotosView() }
        .tabItem { Label("Photos", systemImage: "square.stack.3d.up") }
}

// Single-surface (contacts)
Group {
    if store.folderURL != nil {
        ContactListView()
    } else {
        FolderPickerView()
    }
}
```

### Deep-link router

Apps with deep links (widgets, notifications) have a small `AppRouter`
`@Observable` object that holds `selectedTab` and per-tab `NavigationPath`s,
and consumes pending route ids when the backing data is ready. localgallery's
`AppRouter` is the model.

### Settings access

Settings is a `.sheet` opened from a toolbar button on the root of each
top-level tab — never a tab of its own. This keeps the tab bar focused on
content surfaces.

---

## 9. Stable IDs

When a model represents an on-disk file (Track, PhotoFile, Contact),
**derive its ID from the file URL via SHA-256**. This keeps SwiftUI list
identity stable across rescans (no flicker, no scroll jump, no selection
loss) without storing IDs on disk.

```swift
import CryptoKit

extension Track {
    static func stableID(for url: URL) -> UUID {
        let path = url.standardized.path
        let digest = SHA256.hash(data: Data(path.utf8))
        var bytes = Array(digest.prefix(16))
        // RFC 4122 layout — variant + version-5 nibbles. Foundation's UUID
        // only validates the layout, so this is well-formed even without a
        // strict v5 namespace input.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                           bytes[4],  bytes[5],  bytes[6],  bytes[7],
                           bytes[8],  bytes[9],  bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
```

**Standardize the URL** before hashing (`url.standardized.path`) — otherwise
`/Users/foo/x` and `/private/Users/foo/x` collide differently.

**Why SHA-256, not MD5.** Both work. SHA-256 is the better default in 2026
and CryptoKit makes them equally easy. localmusic is the model;
localgallery is on MD5 and has a migration issue open.

---

## 10. Design tokens

Each app has a `Design` enum exposing the same API. Each app picks its own
palette to match its character (gallery is warm photo-album; music can be
cooler; contacts more neutral). The convention is the **shape**, not the
hex values.

```swift
enum Design {
    static let accentColor: Color
    static let accentSoft: Color   // accent at low opacity, for backgrounds

    static let bg: Color           // canvas
    static let bgCard: Color       // raised surfaces
    static let bgGrouped: Color    // grouped-list background

    static let ink: Color          // primary text
    static let ink2: Color         // secondary text
    static let ink3: Color         // tertiary / muted

    static let separator: Color
    static let destructive: Color

    static let cardRadius: CGFloat
}
```

Use these tokens for any non-system-semantic colour. System semantics
(`.primary`, `.secondary`, `.tertiary`, system fills) are still preferred
where they fit — the tokens exist for the cases where they don't.

---

## 11. UIKit appearance

**Default: don't.** Use SwiftUI `.tint(...)` at the `WindowGroup` level. Let
SwiftUI handle nav bar, tab bar, and list backgrounds.

`UINavigationBar.appearance()`, `UITabBar.appearance()`, and especially
`UIView.appearance().tintColor` are allowed **only** with a comment
explaining the specific SwiftUI gap they're working around. localgallery's
`configureAppearance()` is the model: every appearance override has a
multi-line comment documenting the SwiftUI bug or gap that motivates it.

**The global `UIView.appearance().tintColor` hammer** in particular: do
not adopt unless you've personally hit a sheet-context tint cascade gap
that `.tint()` cannot reach.

---

## 12. File I/O

- **Atomic writes**: `try data.write(to: url, options: .atomic)`.
- **Directory listings** for security-scoped folders use
  `contentsOfDirectory(at:includingPropertiesForKeys:options:)`, **not**
  `enumerator(at:)` — the latter resolves symlinks to `/private/var/...`
  paths that fall outside the security-scoped grant and silently fail.
  See localmusic's `PersistenceManager.latestMTime` for the canonical
  comment.
- **JSON encoders/decoders**: vanilla `JSONEncoder()` / `JSONDecoder()`
  unless a specific reason exists; pretty-print only for human-readable
  artifacts (test fixtures, debug dumps).
- **No background mutation of the user's files** without an explicit user
  action. The apps treat user files as read-mostly; writes only happen as
  the immediate result of a user interaction (save contact, edit playlist,
  etc.).

---

## 13. Vocabulary

Use these terms exactly. Cross-app consistency matters more than per-app
cleverness.

| Term | Means | Don't say |
|---|---|---|
| **Folder** | The user-selected security-scoped directory | "Library", "Path", "Source", "Location" |
| **Reload** | Re-scan the folder, refresh in-memory state | "Refresh", "Sync" (sync means CN sync) |
| **Last Synced** | Timestamp of last successful reload | "Last Updated", "Last Refresh" |
| **Sync** (verb) | Two-way reconciliation with a system store (e.g. Apple Contacts). Reserved. | (don't use for plain reload) |
| **Settings** | The sheet, not "Preferences" or "Options" | |
| **Conflict** | Local file and external system disagree | "Discrepancy" |
| **Tag** / **Category** | User-applied label | "Group" |

---

## 14. Testing

Use **Swift Testing** (`@Test`, `#expect`, `#require`), not XCTest.

```swift
import Testing
@testable import LocalContacts

@Test func parsesBareName() throws {
    let card = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Alice\r\nEND:VCARD\r\n"
    let contact = try #require(VCardParser().parse(string: card))
    #expect(contact.fullName == "Alice")
}
```

### Refactor seams

Every test target's `README.md` has a **Refactor seams** section. This is
the explicit list of testability accommodations made to production code.
**Don't remove a seam without replacing it.** Both localmusic and
localcontacts already do this — copy their format.

Common seams:

- **Inject `UserDefaults`** into bookmark/persistence services. Default to
  `.standard` for app code; tests pass `UserDefaults(suiteName:)`.
- **Inject the documents URL** into persistence services. Tests pass a
  per-test temp directory.
- **`#if DEBUG` overrides** for hard-to-isolate I/O caches (e.g.
  `ArtworkCache.directoryOverride`). Set in `setUp`, clear in `tearDown`.
  Document parallel-test safety constraints in the test README.
- **`nonisolated` static helpers** for pure logic that would otherwise sit
  on a `@MainActor` type. Lets tests call them without crossing actor
  boundaries (which would trip `Sendable` issues with non-Sendable
  arguments like `CNContact`).
- **`assignDefaultID` flags** on parsers that mutate their output, so tests
  can observe the un-mutated state.

### Filesystem tests

```swift
@Test func savesContactToTempFolder() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ContactsStore()
    store.folderURL = dir   // skip setFolder — see refactor seams
    // …
}
```

- **Per-test temp dir** under `FileManager.default.temporaryDirectory`,
  cleaned up via `defer`.
- **Never touch the user's folder.** Don't go through `setFolder` /
  bookmarks — assign `folderURL` directly.
- **Skip `CNContactStore` / authorization-gated code** in unit tests. If
  you need to test it, use a protocol shim (see localcontacts' "Follow-up
  work" notes).

### What to test

Mirror localgallery's TEST_PLAN.md tiering:

1. **Pure logic** (sorting, parsing, ID derivation, filter equality, label
   tables). Cheap, no fixtures, catches the majority of regressions.
2. **Integration** with committed fixture files (small, documented how
   each was produced). Metadata parsing, file-system round-trips.
3. **Performance regression guards** (`measure`-style). Local-only —
   don't gate CI; device variance makes thresholds flaky.
4. **One XCUITest happy-path** per app — folder pick → list → detail →
   action. Drive via a `--demo-library` debug-only launch arg pointing at
   a fixture folder, since `UIDocumentPickerViewController` can't be
   driven from XCUITest.

---

## 15. Continuous integration

Two workflows per repo. **Tests** on every PR, **build IPA** on tag push.

### `.github/workflows/test.yml`

```yaml
name: Test
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Show toolchain
        run: |
          xcodebuild -version
          xcrun simctl list devices available iPhone

      - name: Install XcodeGen
        run: brew install xcodegen

      - name: Generate Xcode project
        run: xcodegen

      - name: Pick a simulator
        id: pick
        run: |
          NAME=$(xcrun simctl list devices available -j \
            | jq -r '.devices | to_entries
                     | map(select(.key | contains("iOS")))
                     | sort_by(.key) | reverse | .[0].value
                     | map(select(.name | startswith("iPhone")))
                     | sort_by(.name) | reverse | .[0].name')
          echo "device_name=$NAME" >> "$GITHUB_OUTPUT"

      - name: Run tests
        run: |
          xcodebuild test \
            -project LocalX.xcodeproj \
            -scheme LocalX \
            -destination "platform=iOS Simulator,name=${{ steps.pick.outputs.device_name }}" \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
          | tee xcodebuild.log
```

localmusic's `test.yml` is the model for the dynamic-simulator-pick step
— don't hardcode `iPhone 16`, GitHub-hosted runner images change.

### `.github/workflows/build.yml`

```yaml
name: Build IPA
on:
  push:
    tags: ["v*"]
  pull_request:
    branches: [main]

jobs:
  build:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - run: xcodegen
      - name: Build
        run: |
          xcodebuild archive \
            -project LocalX.xcodeproj -scheme LocalX \
            -destination "generic/platform=iOS" \
            -archivePath build/LocalX.xcarchive \
            CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
      - name: Create IPA
        run: |
          mkdir -p build/Payload
          cp -r build/LocalX.xcarchive/Products/Applications/LocalX.app build/Payload/
          cd build && zip -r LocalX.ipa Payload
      - name: Upload IPA to release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: build/LocalX.ipa
```

### Rules

- **Runner: `macos-26`.** All three apps use the same runner — bump
  in lockstep when GitHub deprecates it.
- **Tests in `test.yml`, builds in `build.yml`** — separate concerns.
  Don't combine (localcontacts currently does; that's tracked).
- **Unsigned archive** in CI. Signing happens out-of-band.
- **`softprops/action-gh-release@v2`** for tag pushes.
- **No `xcodebuild` Xcode version pin** unless you've hit a specific
  bug. Trust the runner's default Xcode and bump deliberately.

---

## 16. README template

Each repo's README follows the same shape. Don't redesign.

```markdown
# LocalX

One-paragraph description: what it does, what kind of files it works with,
that it's read-mostly / file-as-source-of-truth.

## Why

The "why local files" pitch. ~3 sentences. Pair with [Syncthing][] /
[SyncTrain][] for cross-device sync.

## Features

- Bullet list, ~6–10 items.
- Each item is **bold name** — short description.

## Requirements

- Xcode 16.0+
- iOS 18.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Build

​```bash
brew install xcodegen
xcodegen
open LocalX.xcodeproj
​```

## Setup

What the user does on first launch: pick a folder, optional permissions, etc.

## License

[MPL 2.0](LICENSE)

[Syncthing]: https://syncthing.net/
[SyncTrain]: https://apps.apple.com/app/synctrain/id6475591584
```

---

## 17. Bundle identifiers

| App | Bundle ID | Prefix |
|---|---|---|
| localgallery | `com.localgallery.app` | `com.localgallery` |
| localcontacts | `com.localcontacts.app` | `com.localcontacts` |
| localmusic | `com.localmusic.app` (target) | `com.localmusic` |

**localmusic note.** The current bundle ID is `com.folderplayer` (legacy).
Renaming requires a new App Store record if the app is published.
Confirm App Store status before changing — there is no migration once
shipped.

Extension targets append a sub-id: `com.localgallery.app.widgets`,
`com.localX.app.tests`.

---

## 18. Sync

This file is **mirrored** across the three repos at `.claude/CONVENTIONS.md`.
The canonical source is [`localgallery/.claude/CONVENTIONS.md`][canon]; the
others should match byte-for-byte.

It lives next to the per-repo [`CLAUDE.md`](./CLAUDE.md) so Claude Code
sessions (CLI and web) pick it up automatically without polluting the repo
root.

Until a sync mechanism is in place (a fourth `localfiles-shared` repo, a
GitHub Action that opens PRs across all three when `localgallery` changes,
or a `git subtree` setup), updates must be propagated by hand. Mirror any
edit to all three repos in the same PR.

[canon]: https://github.com/j23n/localgallery/blob/main/.claude/CONVENTIONS.md
