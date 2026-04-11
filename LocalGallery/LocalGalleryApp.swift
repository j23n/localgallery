import SwiftUI
import AVFoundation

// MARK: - Design Constants

enum Design {
    static let accentColor = Color(red: 0.90, green: 0.65, blue: 0.22)
}

@main
struct LocalGalleryApp: App {
    @StateObject private var galleryManager = GalleryManager()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(galleryManager)
                .tint(Design.accentColor)
        }
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
                Label("Folders", systemImage: "folder.fill")
            }

            NavigationStack {
                CollectionsView()
            }
            .tabItem {
                Label("Collections", systemImage: "rectangle.stack.fill")
            }

            NavigationStack {
                AllPhotosView()
            }
            .tabItem {
                Label("All Photos", systemImage: "photo.stack.fill")
            }

        }
        .task {
            await manager.restoreFolder()
        }
    }
}
