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
        let mgr = store
        let photos = mgr.photos(for: memory)
        guard !photos.isEmpty else { return }
        renderingMemory = memory
        renderProgress = 0
        renderedVideoURL = nil

        Task.detached(priority: .userInitiated) {
            // Pre-flight: pull non-local photos down before the renderer
            // tries to read their bytes — without this it would silently
            // fail on placeholders.
            let remote = photos.filter { $0.locality != .local }
            for p in remote {
                _ = try? await mgr.ensureMaterialized(p)
            }

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
                let memories = store.visibleMemories
                if !memories.isEmpty {
                    sectionHeader("Memories", systemIcon: "sparkles", accent: true)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.6) {
                            store.forceRegenerateMemories()
                        }
                    memoriesRail(memories)
                }

                let people = store.visiblePeopleForRail
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
                            store.hideMemory(memory.id)
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
                                PersonCard(tag: person, featured: store.isFeatured(person.fullPath))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let isFeatured = store.isFeatured(person.fullPath)
                                let isMe = store.isMe(person.fullPath)
                                Button {
                                    if isMe { store.unmarkAsMe() } else { store.markAsMe(person.fullPath) }
                                } label: {
                                    Label(isMe ? "Unmark as Me" : "Mark as Me",
                                          systemImage: isMe ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
                                }
                                Button {
                                    store.toggleFeaturePerson(person.fullPath)
                                } label: {
                                    Label(isFeatured ? "Unfeature" : "Feature",
                                          systemImage: isFeatured ? "star.slash" : "star")
                                }
                                Button {
                                    linkingPerson = person
                                } label: {
                                    Label(linkContextLabel(person), systemImage: "person.text.rectangle")
                                }
                                Button(role: .destructive) {
                                    store.hidePerson(person.fullPath)
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

    /// Label for the person → contact link context-menu entry. Reflects the
    /// current state so the menu doubles as status. Goes through
    /// `store.linkState` so we don't re-scan the contacts array per render.
    private func linkContextLabel(_ person: TagSuggestion) -> String {
        switch store.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
        case .unlinked:           return "Link to Contact"
        case .disabled:           return "Birthdays disabled"
        case .manual(let c):      return "Linked: \(c.fullName)"
        case .auto(let c):        return "Auto: \(c.fullName)"
        }
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
    @Environment(GalleryStore.self) private var store

    private var photos: [PhotoFile] {
        store.search(query: "", requiredTags: [tag])
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
    @Environment(GalleryStore.self) private var store

    private var coverPhoto: PhotoFile? {
        store.featuredPhoto(for: tag)
    }

    /// True when this person resolves to a contact (manual link or auto-match
    /// by name). False when explicitly unlinked or no contact matches.
    private var isLinkedToContact: Bool {
        store.effectiveContact(forPersonPath: tag.fullPath, displayName: tag.displayName) != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = coverPhoto {
                PersonThumbnailView(
                    url: photo.url,
                    region: store.faceRegion(for: photo, person: tag.displayName),
                    size: 128,
                    isRemote: photo.locality.isRemotePlaceholder
                )
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

            // Top-right badges. Featured stays rightmost (matches existing
            // muscle memory); the contact-link badge sits to its left when
            // both apply.
            HStack(spacing: 4) {
                if isLinkedToContact {
                    badgeCircle(systemName: "person.text.rectangle.fill")
                }
                if featured {
                    badgeCircle(systemName: "star.fill")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(tag.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(tag.count) \(tag.count == 1 ? "photo" : "photos")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .padding(.horizontal, 9)
            .padding(.bottom, 7)
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private func badgeCircle(systemName: String) -> some View {
        Circle()
            .fill(Color.black.opacity(0.45))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - Memory Card (large, rounded, gradient caption)

struct MemoryCardView: View {
    let memory: Memory
    @Environment(GalleryStore.self) private var store

    private var coverPhoto: PhotoFile? {
        if let p = store.photo(byID: memory.coverPhotoID) { return p }
        return memory.photoIDs.lazy.compactMap { store.photo(byID: $0) }.first
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let photo = coverPhoto {
                ThumbnailView(url: photo.url, size: 328, isRemote: photo.locality.isRemotePlaceholder)
                    .frame(width: 264, height: 328)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Design.bgGrouped)
                    .frame(width: 264, height: 328)
                    .overlay {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Design.ink3)
                    }
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
    @Environment(GalleryStore.self) private var store

    var body: some View {
        PhotoGridScreen(
            title: memory.title,
            subtitle: memory.subtitle,
            photos: store.photos(for: memory),
            playableMemory: memory
        )
    }
}

// MARK: - Identifiable wrapper for sheet(item:) on a URL

private struct RenderedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - People List View

struct PeopleListView: View {
    @Environment(GalleryStore.self) private var store
    @State private var searchText = ""
    @State private var linkingPerson: TagSuggestion?

    private var filteredPeople: [TagSuggestion] {
        let all = store.visiblePeople
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredPeople) { person in
                NavigationLink(value: CollectionsRoute.personGrid(person)) {
                    PeopleListRow(tag: person)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        store.hidePerson(person.fullPath)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                }
                .contextMenu {
                    let isFeatured = store.isFeatured(person.fullPath)
                    let isMe = store.isMe(person.fullPath)
                    Button {
                        if isMe { store.unmarkAsMe() } else { store.markAsMe(person.fullPath) }
                    } label: {
                        Label(isMe ? "Unmark as Me" : "Mark as Me",
                              systemImage: isMe ? "person.crop.circle.badge.xmark" : "person.crop.circle.badge.checkmark")
                    }
                    Button {
                        store.toggleFeaturePerson(person.fullPath)
                    } label: {
                        Label(isFeatured ? "Unfeature" : "Feature",
                              systemImage: isFeatured ? "star.slash" : "star")
                    }
                    Button {
                        linkingPerson = person
                    } label: {
                        Label(linkLabel(for: person), systemImage: "person.text.rectangle")
                    }
                    Button(role: .destructive) {
                        store.hidePerson(person.fullPath)
                    } label: {
                        Label("Hide", systemImage: "eye.slash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.large)
        .background(Design.bg)
        .sheet(item: $linkingPerson) { person in
            ContactLinkSheet(person: person)
        }
    }

    private func linkLabel(for person: TagSuggestion) -> String {
        switch store.linkState(forPersonPath: person.fullPath, displayName: person.displayName) {
        case .unlinked:        return "Link to Contact"
        case .disabled:        return "Birthdays disabled"
        case .manual(let c):   return "Linked: \(c.fullName)"
        case .auto(let c):     return "Auto: \(c.fullName)"
        }
    }
}

// MARK: - People List Row

struct PeopleListRow: View {
    let tag: TagSuggestion
    @Environment(GalleryStore.self) private var store

    private var rowPhotos: [PhotoFile] {
        let all = store.photos(forTag: tag)
        guard let cover = store.featuredPhoto(for: tag) else {
            return Array(all.prefix(2))
        }
        var result = [cover]
        if let other = all.first(where: { $0.id != cover.id }) {
            result.append(other)
        }
        return result
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(rowPhotos) { photo in
                    PersonThumbnailView(
                        url: photo.url,
                        region: store.faceRegion(for: photo, person: tag.displayName),
                        size: 52,
                        cornerRadius: 9,
                        isRemote: photo.locality.isRemotePlaceholder
                    )
                    .frame(width: 52, height: 52)
                }
                if rowPhotos.isEmpty {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Design.bgGrouped)
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Design.ink3)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(tag.displayName)
                        .font(.system(size: 15.5, weight: .medium))
                        .foregroundStyle(Design.ink)
                    if store.isFeatured(tag.fullPath) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Design.accentColor)
                    }
                }
                Text("\(tag.count) \(tag.count == 1 ? "photo" : "photos")")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Design.ink2)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
