import SwiftUI

// MARK: - Section Model

private struct PhotoSection: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoFile]
}

// MARK: - All Photos View

struct AllPhotosView: View {
    @EnvironmentObject var manager: GalleryManager
    /// Target cell size tier: 0 = large (~3 portrait cols), 1 = medium (~4), 2 = small (~5)
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0
    @State private var searchText: String = ""
    @State private var activeTags: [TagSuggestion] = []
    @State private var selectedPhoto: PhotoFile?
    @State private var presentationID = UUID()
    @State private var showSettings = false
    @State private var scrollToTopTrigger = false

    private var filteredPhotos: [PhotoFile] {
        manager.search(query: searchText, requiredTags: activeTags)
    }

    private var photoSections: [PhotoSection] {
        let photos = filteredPhotos

        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"

        var sections: [PhotoSection] = []
        var currentKey = ""
        var currentTitle = ""
        var currentPhotos: [PhotoFile] = []

        for photo in photos {
            let key: String
            let title: String
            if let date = photo.dateTaken {
                let comps = cal.dateComponents([.year, .month], from: date)
                key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
                title = fmt.string(from: date)
            } else {
                key = "unknown"
                title = "Unknown Date"
            }

            if key != currentKey {
                if !currentPhotos.isEmpty {
                    sections.append(PhotoSection(id: currentKey, title: currentTitle, photos: currentPhotos))
                }
                currentKey = key
                currentTitle = title
                currentPhotos = [photo]
            } else {
                currentPhotos.append(photo)
            }
        }
        if !currentPhotos.isEmpty {
            sections.append(PhotoSection(id: currentKey, title: currentTitle, photos: currentPhotos))
        }
        return sections
    }

    private func yearIndex(from sections: [PhotoSection]) -> [(year: String, sectionID: String)] {
        var result: [(year: String, sectionID: String)] = []
        var seen = Set<String>()
        for section in sections where section.id != "all" && section.id != "unknown" {
            let year = String(section.id.prefix(4))
            if !seen.contains(year) {
                seen.insert(year)
                result.append((year, section.id))
            }
        }
        return result
    }

    private var grid: GridLayoutConfig { GridLayoutConfig(sizeTier: sizeTier) }

    var body: some View {
        let sections = photoSections
        let years = yearIndex(from: sections)
        Group {
            if manager.allPhotos.isEmpty {
                if manager.isScanning {
                    ProgressView("Scanning…")
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 64, weight: .thin))
                            .foregroundStyle(Design.accentColor.opacity(0.7))
                        VStack(spacing: 8) {
                            Text("No Photos")
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Choose a folder in Settings to get started.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(32)
                }
            } else {
                photoGrid(sections: sections, years: years)
            }
        }
        .navigationTitle("All Photos")
        .searchable(text: $searchText, prompt: "Search by name or tag")
        .searchSuggestions {
            if !searchText.isEmpty {
                let query = searchText.lowercased()
                let activeIDs = Set(activeTags.map(\.id))
                let suggestions = manager.allTags.filter {
                    !activeIDs.contains($0.id) &&
                    ($0.displayName.lowercased().contains(query) || $0.fullPath.lowercased().contains(query))
                }.prefix(8)
                ForEach(Array(suggestions)) { tag in
                    Button {
                        activeTags.append(tag)
                        searchText = ""
                    } label: {
                        Label {
                            HStack {
                                Text(tag.displayName)
                                Spacer()
                                Text("\(tag.count)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        } icon: {
                            Image(systemName: tag.icon)
                                .foregroundStyle(Design.accentColor)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    scrollToTopTrigger.toggle()
                } label: {
                    Image(systemName: "arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { cycleSizeTier() } label: {
                    Image(systemName: grid.gridIconName)
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: filteredPhotos, initialPhoto: photo)
                .id(presentationID)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func photoGrid(sections: [PhotoSection], years: [(year: String, sectionID: String)]) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let size = grid.cellSize(for: width)
            ScrollViewReader { proxy in
                ScrollView {
                    // Active tag pills
                    if !activeTags.isEmpty {
                        tagPillsBar
                            .id("__top__")
                    } else {
                        Color.clear.frame(height: 0).id("__top__")
                    }

                    LazyVGrid(columns: grid.columns(for: width), spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.photos) { photo in
                                    gridCell(photo: photo, cellSize: size)
                                }
                            } header: {
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                        .background(.bar)
                                        .id(section.id)
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await manager.rescan()
                }
                .overlay(alignment: .trailing) {
                    if years.count > 1 {
                        YearScrubber(years: years) { sectionID in
                            withAnimation {
                                proxy.scrollTo(sectionID, anchor: .top)
                            }
                        }
                    }
                }
                .onChange(of: scrollToTopTrigger) {
                    withAnimation {
                        proxy.scrollTo("__top__", anchor: .top)
                    }
                }
            }
        }
    }

    private var tagPillsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeTags) { tag in
                    HStack(spacing: 4) {
                        Image(systemName: tag.icon)
                            .font(.caption)
                        Text(tag.displayName)
                            .font(.subheadline)
                        Button {
                            activeTags.removeAll { $0.id == tag.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Design.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(Design.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onTapGesture {
                presentationID = UUID()
                selectedPhoto = photo
            }
    }

    private func cycleSizeTier() {
        GridLayoutConfig.cycleSizeTier(&sizeTier)
    }
}

// MARK: - Year Scrubber

private struct YearScrubber: View {
    let years: [(year: String, sectionID: String)]
    let onScrollTo: (String) -> Void

    @State private var isDragging = false
    @State private var lastIndex = -1

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(Array(years.enumerated()), id: \.element.year) { idx, entry in
                    Text("'" + entry.year.suffix(2))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(isDragging && idx == lastIndex ? Design.accentColor : (isDragging ? Color.primary : Color(.tertiaryLabel)))
                        .scaleEffect(isDragging && idx == lastIndex ? 1.4 : 1.0)
                        .frame(maxHeight: .infinity)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: lastIndex)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .opacity(isDragging ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.2), value: isDragging)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let index = Int(value.location.y / geo.size.height * CGFloat(years.count))
                        let clamped = max(0, min(years.count - 1, index))
                        if clamped != lastIndex {
                            lastIndex = clamped
                            onScrollTo(years[clamped].sectionID)
                            let gen = UISelectionFeedbackGenerator()
                            gen.selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastIndex = -1
                    }
            )
        }
        .frame(width: 32)
        .padding(.vertical, 40)
    }
}
