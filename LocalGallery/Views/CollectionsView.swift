import SwiftUI

/// Typed nav stack values for the Collections tab. Hosting the path at the
/// tab root lets the slideshow's "See all" replace itself with the grid view —
/// so back-from-grid returns to Collections, not to the slideshow.
enum CollectionsRoute: Hashable {
    case slideshow(Memory)
    case memoryGrid(Memory)
    case peopleList
    case personGrid(TagSuggestion)
}

struct CollectionsView: View {
    @Binding var path: [CollectionsRoute]
    @Environment(GalleryStore.self) private var store
    @State private var showSettings = false

    // Person → contact linking sheet
    @State private var linkingPerson: TagSuggestion?

    // First-time Contacts permission primer. Tracked in UserDefaults so the
    // prompt only appears once per install — declining doesn't re-prompt.
    @AppStorage("hasShownContactsPrimer") private var hasShownContactsPrimer = false
    @State private var showContactsPrimer = false

    // Memory-to-video share state
    @State private var renderingMemory: Memory?
    @State private var renderProgress: Double = 0
    @State private var renderedVideoURL: URL?
    @State private var renderError: String?
    /// Held so "Cancel" actually cancels the render — clearing the overlay
    /// state alone would leave the H.264 encode (and its remote-photo
    /// downloads) running to completion in the background.
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.allPhotos.isEmpty {
                if store.isScanning {
                    ProgressView("Scanning…")
                } else {
                    emptyState
                }
            } else {
                collectionsBody
            }
        }
        .background(Design.bg)
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // Always include the banner — it returns EmptyView when no
            // scan is running. The `if store.scanProgress != nil` used to
            // live here, but reading scanProgress in the parent body made
            // every progress tick re-evaluate the whole CollectionsView
            // body and re-diff its content. Now the read is scoped to
            // ScanProgressBanner.body and the parent stays untouched.
            ToolbarItem(placement: .principal) {
                ScanProgressBanner()
            }
            ToolbarItem(placement: .topBarTrailing) {
                SettingsToolbarButton(isPresented: $showSettings)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $linkingPerson) { person in
            ContactLinkSheet(person: person)
        }
        .sheet(isPresented: $showContactsPrimer) {
            ContactsPermissionPrimer(
                onAllow: {
                    showContactsPrimer = false
                    Task { await store.requestContactsAccess() }
                },
                onSkip: { showContactsPrimer = false }
            )
            .presentationDetents([.medium])
        }
        // Show the Contacts primer once, the first time the user lands on
        // Collections with photos loaded. Re-evaluates when allPhotos goes from
        // empty → populated (initial scan) so it doesn't miss the moment.
        // Skips silently when access is already determined (granted or denied) —
        // we don't re-prompt; the user can grant access from Settings.
        .task(id: store.allPhotos.isEmpty) {
            guard !hasShownContactsPrimer,
                  !store.allPhotos.isEmpty,
                  ContactsService.authorizationStatus() == .notDetermined
            else { return }
            // Tiny pause so the sheet doesn't fight the appear animation.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard ContactsService.authorizationStatus() == .notDetermined else { return }
            hasShownContactsPrimer = true
            showContactsPrimer = true
        }
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
        .navigationDestination(for: CollectionsRoute.self) { route in
            switch route {
            case .slideshow(let memory):
                // "See all" tapped — replace the slideshow with the grid in
                // the nav stack so back from the grid returns straight to
                // Collections, not back to the slideshow.
                MemorySlideshowView(memory: memory, onSeeAll: { mem in
                    if let last = path.indices.last {
                        path[last] = .memoryGrid(mem)
                    }
                })
            case .memoryGrid(let memory):
                MemoryGridView(memory: memory)
            case .peopleList:
                PeopleListView()
            case .personGrid(let tag):
                TagGridView(tag: tag)
            }
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
                Button("Cancel") {
                    renderTask?.cancel()
                    renderTask = nil
                    renderingMemory = nil
                }
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
        let mgr = store
        let photos = mgr.photos(for: memory)
        guard !photos.isEmpty else { return }
        renderingMemory = memory
        renderProgress = 0
        renderedVideoURL = nil

        renderTask = Task.detached(priority: .userInitiated) {
            // Pre-flight: pull non-local photos down before the renderer
            // tries to read their bytes — without this it would silently
            // fail on placeholders.
            let remote = photos.filter { $0.locality != .local }
            for p in remote {
                if Task.isCancelled { return }
                _ = try? await mgr.ensureMaterialized(p)
            }
            if Task.isCancelled { return }

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
                    // Same guard as the success path: a cancelled render's
                    // throw must not pop the error alert over whatever the
                    // user moved on to.
                    guard renderingMemory?.id == memory.id else { return }
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
                let memories = store.memories.visible
                if !memories.isEmpty {
                    sectionHeader("Memories", systemIcon: "sparkles", accent: true)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.6) {
                            store.memories.forceRegenerate()
                        }
                    memoriesRail(memories)
                }

                let people = store.people.visiblePeopleForRail
                if !people.isEmpty {
                    peopleSectionHeader
                    peopleRail(people)
                }

                if !store.eventFolders.isEmpty {
                    sectionHeader("Events")
                    eventsList
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .softTopScrollEdge()
        .background(Design.bg)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func sectionHeader(_ title: String, systemIcon: String? = nil, accent: Bool = false) -> some View {
        HStack(spacing: 8) {
            if let systemIcon {
                Image(systemName: systemIcon)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 20, weight: .bold))
        }
        .foregroundStyle(accent ? Design.accentColor : Design.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private var peopleSectionHeader: some View {
        NavigationLink(value: CollectionsRoute.peopleList) {
            HStack(spacing: 8) {
                Text("People")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Design.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Design.ink3)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
    }

    private func memoriesRail(_ memories: [Memory]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(memories) { memory in
                    NavigationLink(value: CollectionsRoute.slideshow(memory)) {
                        MemoryCardView(memory: memory)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            path.append(.memoryGrid(memory))
                        } label: {
                            Label("View photos", systemImage: "square.grid.2x2")
                        }
                        Button {
                            startRender(memory: memory)
                        } label: {
                            Label("Share slideshow video", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            store.memories.hide(memory.id)
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
                ForEach(pairs, id: \.first!.id) { pair in
                    VStack(spacing: 10) {
                        ForEach(pair) { person in
                            NavigationLink {
                                TagGridView(tag: person)
                            } label: {
                                PersonCard(tag: person, featured: store.people.isFeatured(person.fullPath))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PersonContextMenu(person: person) { linkingPerson = $0 }
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
            ForEach(Array(store.eventFolders.enumerated()), id: \.element.id) { idx, folder in
                NavigationLink {
                    FolderGridView(title: folder.name, photos: folder.photos)
                } label: {
                    eventRow(folder)
                }
                .buttonStyle(.plain)
                if idx < store.eventFolders.count - 1 {
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
        .contentShape(Rectangle())
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
        LibraryEmptyState(icon: "rectangle.stack", title: "No Collections")
    }
}

// MARK: - Identifiable wrapper for sheet(item:) on a URL

private struct RenderedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

