import SwiftUI
import AVFoundation
import UIKit
import BackgroundTasks

/// AppDelegate handles two things: per-screen orientation locking (used by
/// `OrientationLock`) and registration of the once-a-day background refresh
/// task that re-runs memory generation when the app isn't open. Registration
/// must happen synchronously in `didFinishLaunchingWithOptions`, before the
/// scene is connected — that's why this lives here and not on `GalleryStore`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// `BGTaskSchedulerPermittedIdentifiers` whitelists these exact strings
    /// in the Info.plist; both must stay in sync. `nonisolated` so the
    /// scheduling helpers can read it.
    nonisolated static let backgroundRefreshIdentifier = "com.j23n.localgallery.app.dailyMemories"
    nonisolated static let sidecarRefreshIdentifier = "com.j23n.localgallery.app.sidecarRefresh"

    /// Owns the BG-task → store indirection. The `WindowGroup` attaches the
    /// `GalleryStore` once SwiftUI builds the scene. We hold the service
    /// here (rather than reaching for a `GalleryStore.shared` global) so the
    /// BG handler has a stable, isolation-correct API to call.
    let memoryRefresh = MemoryRefreshService()
    let sidecarRefresh = SidecarRefreshService()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Capture the service value (Sendable because MemoryRefreshService is
        // `@MainActor`) rather than `self` (AppDelegate isn't auto-Sendable
        // under Swift 6 strict concurrency).
        let service = memoryRefresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundRefreshIdentifier,
            using: nil
        ) { task in
            Self.handleBackgroundRefresh(task: task as! BGAppRefreshTask, service: service)
        }

        let sidecarService = sidecarRefresh
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.sidecarRefreshIdentifier,
            using: nil
        ) { task in
            Self.handleSidecarRefresh(task: task as! BGAppRefreshTask, service: sidecarService)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.scheduleBackgroundRefresh()
            Self.scheduleSidecarRefresh()
        }

        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }

    /// Schedule the next background refresh ~24h out. iOS treats this as an
    /// earliest-bound — the actual run is opportunistic and may be skipped.
    /// The foreground catch-up in `GalleryStore.generateMemoriesIfNeeded` is
    /// the safety net for days iOS skips.
    ///
    /// `nonisolated` so the `didEnterBackgroundNotification` observer (a
    /// `@Sendable` closure) and the `BGAppRefreshTask` handler can call it
    /// without hopping back to MainActor — neither needs MainActor state.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.bg.info("Scheduled background refresh for ~24h from now")
        } catch {
            // Common reasons: simulator (where BG tasks aren't supported) or
            // user disabled "Background App Refresh". Not actionable from code.
            Log.bg.warning("Failed to schedule background refresh: \(Log.r.error(error))")
        }
    }

    /// Schedule the next sidecar refresh ~12h out — twice the cadence of the
    /// daily memories task. Best-effort, same as memories.
    nonisolated static func scheduleSidecarRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: sidecarRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.bg.info("Scheduled sidecar refresh for ~12h from now")
        } catch {
            Log.bg.warning("Failed to schedule sidecar refresh: \(Log.r.error(error))")
        }
    }

    /// Handler for the background refresh. Forwards to `MemoryRefreshService`
    /// which runs the once-a-day memory regeneration on the attached store
    /// (or no-ops on a background-only launch where the WindowGroup never
    /// built). Always re-schedules the next run so a single skipped day
    /// doesn't kill the recurring schedule.
    private static func handleBackgroundRefresh(task: BGAppRefreshTask, service: MemoryRefreshService) {
        Log.bg.info("Background refresh started")
        scheduleBackgroundRefresh()

        let work = Task { @MainActor in
            await service.runDailyRefresh()
        }

        // Expiration just cancels — completion is reported once below after
        // `work` finishes (or finishes-via-cancellation), so we never call
        // `setTaskCompleted` twice.
        task.expirationHandler = {
            Log.bg.warning("Background refresh expired before completion")
            work.cancel()
        }

        Task {
            await work.value
            let success = !work.isCancelled
            task.setTaskCompleted(success: success)
            Log.bg.info("Background refresh finished (success: \(success))")
        }
    }

    /// Handler for the sidecar refresh. Mirrors `handleBackgroundRefresh`
    /// but routes to `SidecarRefreshService`.
    private static func handleSidecarRefresh(task: BGAppRefreshTask, service: SidecarRefreshService) {
        Log.bg.info("Sidecar refresh started")
        scheduleSidecarRefresh()

        let work = Task { @MainActor in
            await service.runRefresh()
        }

        task.expirationHandler = {
            Log.bg.warning("Sidecar refresh expired before completion")
            work.cancel()
        }

        Task {
            await work.value
            let success = !work.isCancelled
            task.setTaskCompleted(success: success)
            Log.bg.info("Sidecar refresh finished (success: \(success))")
        }
    }
}

@MainActor
enum OrientationLock {
    static var current: UIInterfaceOrientationMask = .all

    static func lock(_ mask: UIInterfaceOrientationMask, rotateTo orientation: UIInterfaceOrientation? = nil) {
        current = mask
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if let orientation, mask.contains(orientationMask(for: orientation)) {
            let prefs = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientationMask(for: orientation))
            scene.requestGeometryUpdate(prefs) { _ in }
        }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    private static func orientationMask(for orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .all
        }
    }
}

@main
struct LocalGalleryApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store = GalleryStore()
    @State private var router = AppRouter()
    @AppStorage("crashReportingEnabled") private var crashReportingEnabled = false

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureAppearance()
        CrashDiagnosticsService.shared.setEnabled(crashReportingEnabled)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(router)
                .tint(Design.accentColor)
                // Hand the store to the BG-task service. Runs once per
                // scene build; on a true background-only launch the
                // WindowGroup doesn't build and the service stays detached
                // (BG handler no-ops, foreground catch-up takes over on
                // next entry).
                //
                // Trade-off vs the previous synchronous `Self.shared = self`
                // in `GalleryStore.init()`: there is now a small additional
                // window between `@State` materialisation and `.task` firing
                // where a BG handler could see a store-less service and
                // no-op. In practice BG tasks are gated to ≥24h after
                // submission and the foreground catch-up covers any miss, so
                // the window is benign.
                .task {
                    appDelegate.memoryRefresh.attach(store)
                    appDelegate.sidecarRefresh.attach(store)
                    // Pre-render the six slideshow music themes so the first
                    // memory open doesn't pay the synth cost on the main
                    // actor. Idempotent — already-cached themes are skipped.
                    Task.detached(priority: .background) {
                        await SlideshowMusicCache.prewarmAll()
                    }
                }
                .onOpenURL { url in
                    router.handle(url, store: store)
                }
                // Cold-launch deep links (folder/memory) queue an id when the
                // backing data isn't ready; consume them as soon as the data
                // appears so the user lands on the right screen.
                .onChange(of: store.rootFolder?.id) { _, _ in
                    router.consumePendingIfReady(store: store)
                }
                // `memories` (not `.count`) so a same-size regeneration still
                // re-evaluates — Memory equality is id-based, so this fires
                // whenever the id set changes.
                .onChange(of: store.memories) { _, _ in
                    router.consumePendingIfReady(store: store)
                }
        }
    }

    private func configureAppearance() {
        let bg = UIColor(Design.bg)
        let accent = UIColor(Design.accentColor)

        // The WindowGroup-level `.tint()` is the SwiftUI authority, but there
        // are gaps where it can't reach a control: sheet presentations cross
        // a `UIPresentationController` boundary (and nested sheets compound
        // it — Settings → Linked Contacts → Contact picker), and during
        // bursts of observed-state updates descendant Lists can rebuild before
        // the new tint context resolves. In any of those gaps the underlying
        // UIView falls through to `tintColor`, which inherits up to the window
        // — and the iOS default window tint is system blue.
        //
        // The `@Observable` migration (#21) eliminated most rebuild-burst
        // triggers (field-level granularity vs `@Published`'s whole-object
        // invalidation), but the sheet-boundary tint gap is an iOS layout
        // constraint independent of the observation framework. Verified still
        // needed under iOS 18 + `@Observable`: Settings → Linked Contacts →
        // Contact picker continues to resolve to system blue without this.
        //
        // SwiftUI `.tint()` modifiers continue to override where intentional
        // (e.g. `.tint(.primary)` on the Folder row in Settings).
        UIView.appearance().tintColor = accent
        UIWindow.appearance().tintColor = accent

        // Nav bar: transparent at scroll edge, translucent blur when content
        // scrolls under. Matches stock apps (Photos, Messages) — no opaque band.
        // Unrelated to @Observable; still required for the warm design treatment.
        let navStandard = UINavigationBarAppearance()
        navStandard.configureWithOpaqueBackground()
        navStandard.backgroundColor = bg.withAlphaComponent(0.90)
        navStandard.shadowColor = .clear
        navStandard.titleTextAttributes = [.foregroundColor: UIColor(Design.ink)]

        let navEdge = UINavigationBarAppearance()
        navEdge.configureWithTransparentBackground()
        navEdge.shadowColor = .clear
        navEdge.titleTextAttributes = [.foregroundColor: UIColor(Design.ink)]

        UINavigationBar.appearance().standardAppearance = navStandard
        UINavigationBar.appearance().scrollEdgeAppearance = navEdge
        UINavigationBar.appearance().compactAppearance = navStandard
        UINavigationBar.appearance().compactScrollEdgeAppearance = navEdge

        // Tab bar: warm translucent. SwiftUI TabView doesn't expose background
        // color or separator without UIKit appearance; unrelated to @Observable.
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = bg.withAlphaComponent(0.96)
        tab.shadowColor = UIColor(Design.separator)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

struct ContentView: View {
    @Environment(GalleryStore.self) private var store
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            NavigationStack(path: $router.foldersPath) {
                FolderBrowserView()
                    .navigationDestination(for: FolderRoute.self) { route in
                        switch route {
                        case .browser(let folder):
                            FolderBrowserView(folder: folder, isRoot: false)
                        case .grid(let folder):
                            FolderGridView(title: folder.name, photos: folder.photos)
                        }
                    }
            }
            .tabItem {
                Label("Folders", systemImage: "folder")
            }
            .tag(AppRouter.Tab.folders)

            NavigationStack(path: $router.collectionsPath) {
                CollectionsView(path: $router.collectionsPath)
            }
            .tabItem {
                Label("Collections", systemImage: "rectangle.stack")
            }
            .tag(AppRouter.Tab.collections)

            NavigationStack {
                AllPhotosView()
            }
            .tabItem {
                Label("Photos", systemImage: "square.stack.3d.up")
            }
            .tag(AppRouter.Tab.photos)
        }
        .task {
            await store.restoreFolder()
        }
    }
}
