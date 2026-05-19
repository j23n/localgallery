# WP3 — Crash reporting (MetricKit + opt-in log capture)

Goal: surface crashes to the developer through two channels — automatic via
App Store Connect, and manual via an in-app share — without leaking user
data by default. MetricKit handles capture (privacy-clean by construction);
optional log persistence lets users who want richer reports opt in.

File paths and line numbers reflect the branch state at plan authoring;
expect drift after each pass.

---

## Design summary

- **Capture via MetricKit, not signal handlers.** `MXMetricManagerSubscriber`
  receives `MXDiagnosticPayload`s on next launch after a crash. No
  async-signal-safety pitfalls, catches jetsam / watchdog / hangs that DIY
  signal handlers miss, no third-party SDK.
- **Two delivery channels coexist.**
  - *Automatic*: App Store Connect → Xcode Organizer for users on App Store /
    TestFlight with system "Share with App Developers" on (default-on for
    most users). Aggregated, ~1-day delay. Free; no app code involved;
    not gated by any in-app toggle.
  - *Manual*: in-app crash banner in Settings, user-initiated `UIActivityViewController`
    share. Delivers a JSON payload + log tail to wherever the user chooses
    — typically a GitHub issue attachment at
    `github.com/j23n/localgallery/issues`. Gated behind the master
    Crash Reporting toggle.
- **Privacy default: clean.** Out of the box, the app does not write any
  crash data to disk and does not capture logs. The user opts in via a
  single toggle. The App Store Connect channel is unaffected by this
  toggle — that's an OS-level user choice in iOS Settings.
- **Single opt-in.** A Settings toggle "Crash Reporting" (off by default)
  is the master switch. When on:
  - MetricKit subscriber is installed; crash payloads are written to
    `crashes/last-crash.json`.
  - `LogPersistence` flushes `LogStore.shared.entries` to disk on a
    debounce; bounded to a small tail (500 KB).
  - The gear button in each top-level toolbar gets a notification dot when
    a pending crash payload exists.
  - The Settings banner appears when a pending crash payload exists, with
    a Share button (JSON + log tail) and a Dismiss button.

  When off:
  - Subscriber is not installed; no payloads stored.
  - `LogPersistence` does nothing.
  - No badge, no banner.
  - Existing `crashes/` and `logs/` files are deleted.

  Two layers of consent remain: toggle-on (opt-in to capture at all) +
  manual tap to share each crash (the share itself is a deliberate user
  action through `UIActivityViewController`).
- **Non-goals.** No automatic upload, no third-party SDK, no symbolication
  on-device (developer symbolicates from the matching dSYM), no
  cross-launch breadcrumb merging beyond the most recent flush.

---

## Pass 1 — MetricKit subscriber, log persistence, opt-in toggle

Foundational. Capture machinery + master toggle. No UI surfacing yet.

### 1.1 `CrashDiagnosticsService`

New file: `LocalGallery/Services/CrashDiagnosticsService.swift` —
`@Observable @MainActor final class` conforming to `MXMetricManagerSubscriber`.

```swift
@Observable @MainActor
final class CrashDiagnosticsService: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsService()

    let crashFileURL: URL    // <AppSupport>/crashes/last-crash.json
    let logTailURL: URL      // <AppSupport>/logs/recent.txt

    /// Mirror of the `crashReportingEnabled` `@AppStorage` value, observed
    /// by the toolbar gear-badge overlay. Updated by `setEnabled(_:)`.
    private(set) var isEnabled: Bool

    /// Set when a pending crash payload is on disk. Drives the gear badge
    /// and the Settings banner. Re-read on launch and after `didReceive`.
    private(set) var hasPendingCrash: Bool

    func setEnabled(_ enabled: Bool)
    func pendingCrashReport() -> Data?
    func recentLogTail() -> Data?
    func clearPendingCrash()      // deletes both files, sets hasPendingCrash = false

    // MXMetricManagerSubscriber
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload])
}
```

Implementation notes:

- `setEnabled(_:)` is the single mutation point; called once at launch
  from `LocalGalleryApp.init()` reading the `@AppStorage` default, and
  again from the Settings toggle's `.onChange`. Internally:
  - Off → On: `MXMetricManager.shared.add(self)`; create `crashes/`,
    `logs/`; refresh `hasPendingCrash` from disk (in case a payload was
    stored from a previous on-state).
  - On → Off: `MXMetricManager.shared.remove(self)`; call
    `clearPendingCrash()`; delete the entire `crashes/` and `logs/`
    directories; reset `hasPendingCrash` to false.
- `didReceive(_:)` filters payloads with non-empty `crashDiagnostics`,
  picks the most recent, serializes via `payload.jsonRepresentation()`,
  hops to `MainActor`, writes atomically. Sets `hasPendingCrash = true`.
  Early-returns if `isEnabled` is false (defensive — subscriber should be
  removed in that state, but covers the brief window during a flip).
- `clearPendingCrash()` removes both `last-crash.json` and `recent.txt`,
  sets `hasPendingCrash = false`. Used by both the Settings Dismiss
  button and the off-transition.
- Hang / CPU / disk diagnostics ignored in this pass; crash-only.

### 1.2 `LogPersistence`

New file: `LocalGallery/Services/LogPersistence.swift` —
`@MainActor final class`.

```swift
@MainActor
final class LogPersistence {
    static let shared = LogPersistence()

    var isEnabled: Bool { CrashDiagnosticsService.shared.isEnabled }

    func scheduleFlush()    // no-op when isEnabled is false
}
```

Implementation notes:

- `scheduleFlush()` early-returns when disabled.
- When enabled: cancels any pending `Task`, starts a new one that sleeps
  2s, then writes `LogStore.shared.asText` atomically to
  `CrashDiagnosticsService.shared.logTailURL`. Debounce coalesces bursts
  during scans / enrichment.
- File size cap: 500 KB. After every flush, if the file exceeds the cap,
  truncate to the last 500 KB by reading the file, slicing, and rewriting.
  Cheap; runs at most once per flush and only on overflow.
- No clean-up on disable here — `CrashDiagnosticsService.setEnabled(false)`
  owns directory removal.

### 1.3 `LogStore` hook

`LocalGallery/Services/LogStore.swift`, in `insert(_:)`:

```swift
private func insert(_ entry: Entry) {
    // existing coalesce / append / cap logic...
    LogPersistence.shared.scheduleFlush()
}
```

One extra method call per log line. Cheap when toggle is off (early
return on `isEnabled` check inside `scheduleFlush`).

### 1.4 Wiring at launch

`LocalGallery/LocalGalleryApp.swift`:

```swift
@AppStorage("crashReportingEnabled") private var crashReportingEnabled = false

init() {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    configureAppearance()
    CrashDiagnosticsService.shared.setEnabled(crashReportingEnabled)
}
```

MetricKit must be subscribed early when enabled; payloads can be delivered
shortly after launch. `init()` is the right hook.

`@AppStorage` is the source of truth for the toggle; the service mirrors
it. Decouples persistence from observation.

### 1.5 Assertion-message audit

One-time grep audit so user data can't slip into the crash payload via
`fatalError`/`precondition` messages. MetricKit itself never sees them,
but if any of these fire, the trap site's reason string ends up in the
crash backtrace's frame info.

Targets:
- `fatalError(`
- `preconditionFailure(`
- `assertionFailure(`
- `precondition(.*,` (two-arg form)
- `assert(.*,`

Rewrite any messages that interpolate user-provided strings (file URLs,
folder names, photo names) into generic invariant messages.

---

## Pass 2 — Toolbar gear badge & Settings UI

User-visible surface: opt-in toggle, gear-icon badge, crash banner, share.

### 2.1 Settings toggle

`LocalGallery/Views/SettingsView.swift`, new section (placement: top of
the existing list, *above* the crash banner so the toggle is always
discoverable; or under "Help" if we want it lower-key — pick top for v1):

```swift
@AppStorage("crashReportingEnabled") private var crashReportingEnabled = false

Section {
    Toggle("Crash Reporting", isOn: $crashReportingEnabled)
} footer: {
    Text("When on, LocalGallery captures crash details and recent log entries on this device. Nothing is sent automatically — if a crash is captured, a banner appears here in Settings and you can choose to share the report with the developer. Logs include file names and folder paths from your library. Off by default. App Store crash analytics (system-level) are unaffected by this setting.")
}
.onChange(of: crashReportingEnabled) { _, newValue in
    CrashDiagnosticsService.shared.setEnabled(newValue)
}
```

The footer makes three things explicit:

1. **What is captured** (crash details + recent logs).
2. **That nothing leaves the device automatically** — sharing is a manual,
   per-report action through `UIActivityViewController`.
3. **What's in the logs** (filenames / folder paths) so the user can
   weigh the privacy trade-off.
4. **That this toggle does not affect the OS-level App Store analytics
   path** — that's a separate user choice in iOS Settings.

`@AppStorage` is the source of truth; the `.onChange` propagates flips
into the service so the subscriber and disk state stay in sync.

### 2.2 Crash banner section

Below the toggle, only shown when both `crashReportingEnabled` is true
*and* `CrashDiagnosticsService.shared.hasPendingCrash` is true:

```swift
@Environment(\.scenePhase) private var scenePhase
private var crashService = CrashDiagnosticsService.shared

if crashReportingEnabled, crashService.hasPendingCrash {
    crashSection
}
```

`crashSection`:
- Headline: `Label("LocalGallery crashed last session", systemImage: "exclamationmark.triangle.fill")`.
- Caption: `"A crash report was captured. You can share it with the developer to help diagnose the issue, or dismiss it."`
- Buttons:
  - **Share** (prominent): bundles `last-crash.json` and (if present)
    `recent.txt` into the activity sheet.
  - **Dismiss** (destructive role): calls `clearPendingCrash()`.

Re-read `hasPendingCrash` on `scenePhase == .active` so a payload that
arrives mid-session surfaces without an app restart.

### 2.3 `ShareSheet.present(items:)` helper

Existing `LocalGallery/Components/ShareSheet.swift` is currently only a
`UIViewControllerRepresentable`. Add a static helper alongside it (extract
the present-on-top-VC logic from `LogsView.presentShareSheet`):

```swift
extension ShareSheet {
    @MainActor
    static func present(items: [Any])
}
```

Then refactor `LogsView.presentShareSheet` to call it. The crash banner
uses the same helper.

### 2.4 Share payload

`shareCrashReport()`:
- Always includes `localgallery-crash-<yyyy-MM-dd>.json`
  (`pendingCrashReport()` data).
- Includes `localgallery-logs-<yyyy-MM-dd>.txt` if `recentLogTail()` is
  non-nil. (Logs are only present when the user opted in *before* the
  crash; the file ships with whatever the persistence captured.)
- Writes both files to `FileManager.default.temporaryDirectory`.
- `ShareSheet.present(items: urls)` — `UIActivityViewController` handles
  multi-attachment naturally for Mail / Files / Messages targets.

The JSON is `MXDiagnosticPayload.jsonRepresentation()` raw — readable in
any text editor, suitable for attachment to a GitHub issue.

### 2.5 Toolbar gear-icon badge

The gear button currently appears in three places:
- `LocalGallery/Views/FolderBrowserView.swift:46`
- `LocalGallery/Views/PhotoGridScreen.swift:620`
- `LocalGallery/Views/CollectionsView.swift:49`

New file: `LocalGallery/Components/SettingsToolbarButton.swift` —
reusable, encapsulates the gear + badge + sheet wiring so the badge logic
lives in one place.

```swift
struct SettingsToolbarButton: View {
    @Binding var isPresented: Bool
    private var crashService = CrashDiagnosticsService.shared
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "gear")
                .overlay(alignment: .topTrailing) {
                    if crashReportingEnabled, crashService.hasPendingCrash {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
                }
        }
    }
}
```

Replace each of the three call sites' inline `Button { showSettings = true } label: { Image(systemName: "gear") }` with `SettingsToolbarButton(isPresented: $showSettings)`. The `.sheet(isPresented: $showSettings) { SettingsView() }` modifier stays where it is.

The badge is a small red dot, not a numeric count — there's only ever
one pending crash file at a time. (If we later add hang reporting and
want to disambiguate, we can swap to a count.)

`hasPendingCrash` is `@Observable`, so the overlay re-evaluates
automatically when MetricKit delivers a payload mid-session or when the
user dismisses.

---

## Pass 3 — Tests & audit

Light. Most of this is integration-shaped; aim for unit coverage on the
file IO and toggle interaction.

### 3.1 Unit tests

`LocalGalleryTests/CrashDiagnosticsServiceTests.swift`:
- `setEnabled(true)` creates the directory; `setEnabled(false)` removes
  it and resets `hasPendingCrash`.
- Writing a crash JSON and reading it back returns the same `Data`.
- `clearPendingCrash()` removes both files; subsequent
  `pendingCrashReport()` and `recentLogTail()` return nil.

`LocalGalleryTests/LogPersistenceTests.swift`:
- With service disabled, `scheduleFlush()` writes nothing.
- With service enabled, debounced flush writes `LogStore.shared.asText`.
- File >500 KB after a flush → truncated to ≤500 KB tail.

### 3.2 Manual smoke test

- Build for device. Toggle "Crash Reporting" on. Log a few lines via the
  app's normal flow. Trigger a `fatalError("invariant violation")` from
  a hidden debug button.
- Confirm on next launch: gear icon shows red dot in the toolbar.
- Open Settings → banner present, Share emits a JSON file with non-empty
  `crashDiagnostics` and a `.txt` log file.
- Tap Dismiss → badge clears, banner disappears, files removed.
- Toggle off → confirm `crashes/` and `logs/` directories deleted.
- Toggle off, crash app → confirm next launch shows no badge / banner
  (subscriber wasn't installed).

### 3.3 Privacy review checklist

Before merging:

- [ ] Grep audit (1.5) complete; no user data in trap messages.
- [ ] `crashes/last-crash.json` confirmed to contain only MetricKit fields
      (call stacks, exception codes, meta) on a real crash payload.
- [ ] Settings toggle defaults to off in a fresh install.
- [ ] Toggle-off transition deletes both `crashes/` and `logs/`.
- [ ] No badge / banner / disk writes when toggle is off.
- [ ] Settings caption clearly states what's captured when toggle is on,
      that nothing is sent automatically, and the App-Store-Connect-is-separate
      clarification.

---

## Open questions

- **Hangs and CPU exceptions.** MetricKit also reports `hangDiagnostics`,
  `cpuExceptionDiagnostics`, `diskWriteExceptionDiagnostics`. Surfacing
  them in the same banner is straightforward (filter `payloads.flatMap
  { $0.crashDiagnostics ?? [] + $0.hangDiagnostics ?? [] }`). Worth doing
  later if hang reports prove useful; out of scope for v1.
- **Repeat-crash UX.** If the app crashes on launch repeatedly, the
  banner appears every time — fine. If the crash payload itself triggers
  a re-crash (unlikely but possible if `pendingCrashReport()` reads
  malformed data), guard with a sentinel: write a "reading crash report"
  marker file before reading, delete after; on launch, if the marker
  exists, skip and clear the crash file.
- **First-time discoverability.** With the toggle off by default, users
  who never visit Settings will never see the banner. The App Store
  Connect channel covers most of this; if we want stronger in-app
  discoverability, a one-time prompt on first launch ("Help improve
  LocalGallery by sharing crash reports?") would catch more users — but
  goes against the privacy-first framing. Defer until we have evidence
  it's needed.
- **dSYM management.** App Store / TestFlight builds upload dSYMs to
  Apple automatically; manual builds need the dSYM kept locally to
  symbolicate user-shared payloads. Document the path in `CLAUDE.md`
  (developer-facing only).
