import SwiftUI
import AVFoundation
import UIKit

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

/// AppDelegate exists solely so individual screens can lock orientation:
/// `OrientationLock.lock(.portrait)` flips the static and we report it back to
/// UIKit. SwiftUI has no native equivalent for per-screen orientation locking.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.current
    }
}

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
    @StateObject private var galleryManager = GalleryManager()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(galleryManager)
                .tint(Design.accentColor)
        }
    }

    private func configureAppearance() {
        let bg = UIColor(Design.bg)

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
    @EnvironmentObject var manager: GalleryManager
    /// Path for the Collections tab. Lives at the tab root so CollectionsView
    /// can replace the slideshow in the stack with the grid view (so back from
    /// the grid skips the slideshow and returns to Collections).
    @State private var collectionsPath: [CollectionsRoute] = []

    var body: some View {
        TabView {
            NavigationStack {
                FolderBrowserView()
            }
            .tabItem {
                Label("Folders", systemImage: "folder")
            }

            NavigationStack(path: $collectionsPath) {
                CollectionsView(path: $collectionsPath)
            }
            .tabItem {
                Label("Collections", systemImage: "rectangle.stack")
            }

            NavigationStack {
                AllPhotosView()
            }
            .tabItem {
                Label("Photos", systemImage: "square.stack.3d.up")
            }
        }
        .task {
            await manager.restoreFolder()
        }
    }
}
