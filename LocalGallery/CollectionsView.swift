import SwiftUI

struct CollectionsView: View {
    @EnvironmentObject var manager: GalleryManager
    @State private var showSettings = false

    // Navigation target for "View photos" action — context menu dispatches via state
    // because navigating from inside a menu button closure isn't reliable otherwise.
    @State private var navMemory: Memory?

    // Memory-to-video share state
    @State private var renderingMemory: Memory?
    @State private var renderProgress: Double = 0
    @State private var renderedVideoURL: URL?
    @State private var renderError: String?

    var body: some View {
        Group {
            if manager.allPhotos.isEmpty {
                if manager.isScanning {
                    ProgressView("Scanning…")
                } else {
                    emptyState
                }
            } else {
                collectionsBody
            }
        }
        .background(Design.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gear") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: Binding<RenderedVideo?>(
            get: { renderedVideoURL.map { RenderedVideo(url: $0) } },
            set: { renderedVideoURL = $0?.url }
        )) { v in
            ShareSheet(items: [v.url])
        }
        .overlay {
            if renderingMemory != nil {
                renderingOverlay
            }
        }
        .alert("Couldn’t render slideshow",
               isPresented: Binding(get: { renderError != nil }, set: { if !$0 { renderError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(renderError ?? "")
        }
        .navigationDestination(item: $navMemory) { memory in
            MemoryGridView(memory: memory)
        }
    }

    // MARK: - Memory video render

    private var renderingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView(value: renderProgress)
                    .progressViewStyle(.linear)
                    .tint(Design.accentColor)
                Text("Rendering slideshow… \(Int(renderProgress * 100))%")
                    .font(.system(size: 13))
                    .foregroundStyle(Design.ink2)
                Button("Cancel") { renderingMemory = nil }
                    .font(.system(size: 13))
                    .foregroundStyle(Design.accentColor)
            }
            .padding(20)
            .frame(width: 260)
            .background(Design.bgCard, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        }
    }

    private func startRender(memory: Memory) {
        let mgr = manager
        let photos = mgr.photos(for: memory)
        guard !photos.isEmpty else { return }
        renderingMemory = memory
        renderProgress = 0
        renderedVideoURL = nil

        Task.detached(priority: .userInitiated) {
            let loader: (URL, CGSize) async -> UIImage? = { url, _ in
                await mgr.loadFullImage(for: url)
            }
            do {
                let url = try await SlideshowVideoRenderer.render(
                    photos: photos,
                    title: memory.title,
                    loadImage: loader,
                    progress: { @MainActor p in renderProgress = p }
                )
                await MainActor.run {
                    guard renderingMemory?.id == memory.id else { return }
                    renderingMemory = nil
                    renderedVideoURL = url
                }
            } catch {
                await MainActor.run {
                    renderingMemory = nil
                    renderError = String(describing: error)
                }
            }
        }
    }

    // MARK: - Body

    private var collectionsBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleHeader

                let memories = manager.visibleMemories
                if !memories.isEmpty {
                    sectionHeader("Memories", systemIcon: "sparkles", accent: true)
                    memoriesRail(memories)
                }

                let people = manager.visiblePeople
                if !people.isEmpty {
                    sectionHeader("People")
                    peopleRail(people)
                }

                if !manager.eventFolders.isEmpty {
                    sectionHeader("Events")
                    eventsList
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .background(Design.bg)
    }

    private var titleHeader: some View {
        Text("Collections")
            .font(.system(size: 30, weight: .semibold))
            .tracking(-0.6)
            .foregroundStyle(Design.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func sectionHeader(_ title: String, systemIcon: String? = nil, accent: Bool = false) -> some View {
        HStack(spacing: 7) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title.uppercased())
                .font(.system(size: 12.5, weight: .semibold))
                .tracking(0.5)
        }
        .foregroundStyle(accent ? Design.accentColor : Design.ink2)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    private func memoriesRail(_ memories: [Memory]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(memories) { memory in
                    NavigationLink {
                        MemorySlideshowView(memory: memory)
                    } label: {
                        MemoryCardView(memory: memory)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            navMemory = memory
                        } label: {
                            Label("View photos", systemImage: "square.grid.2x2")
                        }
                        Button {
                            startRender(memory: memory)
                        } label: {
                            Label("Share slideshow video", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            manager.hideMemory(memory.id)
                        } label: {
                            Label("Hide memory", systemImage: "eye.slash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    private func peopleRail(_ people: [TagSuggestion]) -> some View {
        // Two-row horizontal scroll, column-major like the design.
        let pairs = stride(from: 0, to: people.count, by: 2).map { i -> [TagSuggestion] in
            if i + 1 < people.count { return [people[i], people[i + 1]] }
            return [people[i]]
        }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                    VStack(spacing: 10) {
                        ForEach(pair) { person in
                            NavigationLink {
                                TagGridView(tag: person)
                            } label: {
                                PersonCard(tag: person, featured: manager.isFeatured(person.fullPath))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let isFeatured = manager.isFeatured(person.fullPath)
                                Button {
                                    manager.toggleFeaturePerson(person.fullPath)
                                } label: {
                                    Label(isFeatured ? "Unfeature" : "Feature",
                                          systemImage: isFeatured ? "star.slash" : "star")
                                }
                                Button(role: .destructive) {
                                    manager.hidePerson(person.fullPath)
                                } label: {
                                    Label("Hide", systemImage: "eye.slash")
                                }
                            }
                        }
                        if pair.count == 1 {
                            Color.clear.frame(width: 128, height: 128)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    private var eventsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(manager.eventFolders.enumerated()), id: \.element.id) { idx, folder in
                NavigationLink {
                    FolderGridView(title: folder.name, photos: folder.photos)
                } label: {
                    eventRow(folder)
                }
                .buttonStyle(.plain)
                if idx < manager.eventFolders.count - 1 {
                    Divider()
                        .background(Design.separator)
                        .padding(.leading, 96)
                }
            }
        }
        .background(Design.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
    }

    private func eventRow(_ folder: PhotoFolder) -> some View {
        HStack(spacing: 14) {
            if let coverURL = folder.coverPhotoURL {
                ThumbnailView(url: coverURL, size: 68, cornerRadius: 10)
                    .frame(width: 68, height: 68)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Design.bgGrouped)
                    .frame(width: 68, height: 68)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title3)
                            .foregroundStyle(Design.ink3)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(Design.ink)
                    .lineLimit(1)
                Text("\(folder.photos.count) photos")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Design.ink2)
                if let range = eventDateRange(folder) {
                    Text(range)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Design.ink3)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Design.ink3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func eventDateRange(_ folder: PhotoFolder) -> String? {
        let dates = folder.photos.compactMap(\.dateTaken).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return fmt.string(from: first)
        }
        return "\(fmt.string(from: first)) – \(fmt.string(from: last))"
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(Design.accentColor.opacity(0.7))
            VStack(spacing: 8) {
                Text("No Collections")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.ink)
                Text("Choose a folder in Settings to get started.")
                    .font(.subheadline)
                    .foregroundStyle(Design.ink2)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}

// MARK: - Tag Grid View

struct TagGridView: View {
    let tag: TagSuggestion
    @EnvironmentObject var manager: GalleryManager

    private var photos: [PhotoFile] {
        manager.search(query: "", requiredTags: [tag])
    }

    private var isPersonTag: Bool {
        tag.namespace?.lowercased() == "people"
    }

    var body: some View {
        PhotoGridScreen(
            title: tag.displayName,
            subtitle: tag.fullPath.replacingOccurrences(of: "/", with: " › "),
            photos: photos,
            featureContextPerson: isPersonTag ? tag : nil
        )
    }
}

// MARK: - Person Card (single featured photo, bottom-left name)

struct PersonCard: View {
    let tag: TagSuggestion
    let featured: Bool
    @EnvironmentObject var manager: GalleryManager

    private var coverPhoto: PhotoFile? {
        manager.featuredPhoto(for: tag)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = coverPhoto {
                ThumbnailView(url: photo.url, size: 128)
                    .frame(width: 128, height: 128)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Design.ink3)
                    }
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: UnitPoint(x: 0.5, y: 0.45),
                endPoint: .bottom
            )

            if featured {
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            Text(tag.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.bottom, 7)
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

// MARK: - Memory Card (large, rounded, gradient caption)

struct MemoryCardView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager

    private var coverURL: URL? { manager.photo(byID: memory.coverPhotoID)?.url }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let url = coverURL {
                ThumbnailView(url: url, size: 328)
                    .frame(width: 264, height: 328)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .frame(width: 264, height: 328)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: UnitPoint(x: 0.5, y: 0.4),
                endPoint: .bottom
            )
            .frame(width: 264, height: 328)

            VStack(alignment: .leading, spacing: 3) {
                Text(memory.title)
                    .font(Design.serifItalic(22, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let subtitle = memory.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Text("\(memory.photoIDs.count) photos")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 1)
            }
            .padding(14)
        }
        .frame(width: 264, height: 328)
        .clipShape(RoundedRectangle(cornerRadius: Design.memoryRadius))
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Memory grid mode (reachable via "See all" from slideshow)

struct MemoryGridView: View {
    let memory: Memory
    @EnvironmentObject var manager: GalleryManager

    var body: some View {
        PhotoGridScreen(
            title: memory.title,
            subtitle: memory.subtitle,
            photos: manager.photos(for: memory),
            playableMemory: memory
        )
    }
}

// MARK: - Identifiable wrapper for sheet(item:) on a URL

private struct RenderedVideo: Identifiable {
    let id = UUID()
    let url: URL
}
