import SwiftUI

@main
struct FolderGalleryApp: App {
    @StateObject private var galleryManager = GalleryManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(galleryManager)
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
