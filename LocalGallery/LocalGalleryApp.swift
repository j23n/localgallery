import SwiftUI
import AVFoundation
import UIKit
import BackgroundTasks

// MARK: - Design Tokens (Quiet direction)

enum Design {
    // Warm, stock-adjacent palette (#FAF7F2 canvas, muted amber accent).
    static let accentColor  = Color(red: 0.769, green: 0.541, blue: 0.243)  // #C48A3E
    static let accentSoft   = Color(red: 0.769, green: 0.541, blue: 0.243).opacity(0.13)

    static let bg           = Color(red: 0.980, green: 0.969, blue: 0.949)  // #FAF7F2
    static let bgCard       = Color.white                                    // #FFFFFF
    static let bgGrouped    = Color(red: 0.949, green: 0.929, blue: 0.898)  // #F2EDE5

    static let ink          = Color(red: 0.110, green: 0.102, blue: 0.086)  // #1C1A16
    static let ink2         = Color(red: 0.369, green: 0.341, blue: 0.302)  // #5E574D
    static let ink3         = Color(red: 0.584, green: 0.553, blue: 0.510)  // #958D82
    static let separator    = Color(red: 0.235, green: 0.216, blue: 0.176).opacity(0.10)

    static let destructive  = Color(red: 0.698, green: 0.290, blue: 0.227)  // #B24A3A

    static let cardRadius: CGFloat = 14
    static let memoryRadius: CGFloat = 20

    /// Newsreader italic stand-in (system serif italic) — used for memory titles.
    static func serifItalic(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif).italic()
    }
}

extension View {
    /// Soft gradient fade at the top edge of the enclosing scroll view so
    /// content dissolves into the nav bar (iOS 26+ — no-op on older OSes).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// AppDelegate handles two things: per-screen orientation locking (used by
/// `OrientationLock`) and registration of the once-a-day background refresh
/// task that re-runs memory generation when the app isn't open. Registration
/// must happen synchronously in `didFinishLaunchingWithOptions`, before the
/// scene is connected — that's why this lives here and not on `GalleryManager`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// `BGTaskSchedulerPermittedIdentifiers` whitelists this exact string in
    /// the Info.plist; both must stay in sync. `nonisolated` so the
    /// `nonisolated static func scheduleBackgroundRefresh()` can read it.
    nonisolated static let backgroundRefreshIdentifier = "com.localgallery.app.dailyMemories"

    /// Owns the BG-task → manager indirection. The `WindowGroup` attaches the
    /// `GalleryManager` once SwiftUI builds the scene. We hold the service
    /// here (rather than reaching for a `GalleryManager.shared` global) so the
    /// BG handler has a stable, isolation-correct API to call.
    let memoryRefresh = MemoryRefreshService()

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

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Self.scheduleBackgroundRefresh()
        }

        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }

    /// Schedule the next background refresh ~24h out. iOS treats this as an
    /// earliest-bound — the actual run is opportunistic and may be skipped.
    /// The foreground catch-up in `GalleryManager.generateMemoriesIfNeeded` is
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
            Log.bg.warning("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    /// Handler for the background refresh. Forwards to `MemoryRefreshService`
    /// which runs the once-a-day memory regeneration on the attached manager
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
    @State private var galleryManager = GalleryManager()
    @State private var router = AppRouter()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(galleryManager)
                .environment(router)
                .tint(Design.accentColor)
                // Hand the manager to the BG-task service. Runs once per
                // scene build; on a true background-only launch the
                // WindowGroup doesn't build and the service stays detached
                // (BG handler no-ops, foreground catch-up takes over on
                // next entry).
                //
                // Trade-off vs the previous synchronous `Self.shared = self`
                // in `GalleryManager.init()`: there is now a small additional
                // window between `@State` materialisation and `.task` firing
                // where a BG handler could see a manager-less service and
                // no-op. In practice BG tasks are gated to ≥24h after
                // submission and the foreground catch-up covers any miss, so
                // the window is benign.
                .task {
                    appDelegate.memoryRefresh.attach(galleryManager)
                }
                .onOpenURL { url in
                    router.handle(url, manager: galleryManager)
                }
                // Cold-launch deep links (folder/memory) queue an id when the
                // backing data isn't ready; consume them as soon as the data
                // appears so the user lands on the right screen.
                .onChange(of: galleryManager.rootFolder?.id) { _, _ in
                    router.consumePendingIfReady(manager: galleryManager)
                }
                .onChange(of: galleryManager.memories.count) { _, _ in
                    router.consumePendingIfReady(manager: galleryManager)
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
        // bursts of observed-state updates (e.g. `manager.rescan()` rewriting
        // `allPhotos`/`allTags`/indexes at once) descendant Lists can rebuild
        // before the new tint context resolves. In any of those gaps the
        // underlying UIView falls through to `tintColor`, which inherits up
        // to the window — and the iOS default window tint is system blue.
        //
        // Pinning the UIKit appearance accent at app start sets the floor of
        // that cascade so no SF Symbol in a Label/Toggle/NavigationLink can
        // resolve to system blue, regardless of which sheet/nav context it
        // lives in. SwiftUI `.tint()` modifiers continue to override where
        // intentional (e.g. `.tint(.primary)` on the Folder row in Settings).
        UIView.appearance().tintColor = accent
        UIWindow.appearance().tintColor = accent

        // Nav bar: transparent at scroll edge, translucent blur when content scrolls under.
        // Matches stock apps (Photos, Messages) — no opaque band.
        let navStandard = UINavigationBarAppearance()
        navStandard.configureWithDefaultBackground()
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

        // Tab bar: warm translucent
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = bg.withAlphaComponent(0.96)
        tab.shadowColor = UIColor(Design.separator)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
    }
}

struct ContentView: View {
    @Environment(GalleryManager.self) private var manager
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
            await manager.restoreFolder()
        }
    }
}
