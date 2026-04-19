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

@main
struct LocalGalleryApp: App {
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

        // Nav bar: warm canvas, no hairline
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = bg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(Design.ink)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Design.ink)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav

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

    var body: some View {
        TabView {
            NavigationStack {
                FolderBrowserView()
            }
            .tabItem {
                Label("Folders", systemImage: "folder")
            }

            NavigationStack {
                CollectionsView()
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
