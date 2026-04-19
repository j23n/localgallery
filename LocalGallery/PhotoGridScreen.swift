import SwiftUI
import UIKit

/// Unified photo grid used for All Photos, folder/event drill-ins, tag drill-ins,
/// and memory "grid mode". Supports search, tag filtering, year scrubber,
/// Select mode with share, and long-press menus — matching the Quiet design.
struct PhotoGridScreen: View {
    let title: String
    var subtitle: String?
    let photos: [PhotoFile]
    /// When true, show the gear button in the leading toolbar slot.
    var isRoot: Bool = false
    /// Enable search field + tag suggestions in the header.
    var showSearch: Bool = false
    /// When present, shows a "Play" button in the toolbar to jump into slideshow.
    var playableMemory: Memory? = nil

    @EnvironmentObject var manager: GalleryManager
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0

    @State private var query: String = ""
    @State private var activeTags: [TagSuggestion] = []
    @State private var scrollToTopTrigger = false

    // Viewer
    @State private var viewerPhoto: PhotoFile?
    @State private var viewerID = UUID()

    // Select mode
    @State private var selectMode = false
    @State private var selected: Set<UUID> = []

    // Long-press menu
    @State private var photoMenu: PhotoFile?

    // Share sheet (share an arbitrary list of URLs)
    @State private var shareURLs: [URL]?

    // Settings sheet (root only)
    @State private var showSettings = false

    // Slideshow navigation
    @State private var goToSlideshow = false

    private var grid: GridLayoutConfig { GridLayoutConfig(sizeTier: sizeTier) }

    private var filteredPhotos: [PhotoFile] {
        var list = photos
        if !activeTags.isEmpty {
            let required = Set(activeTags.map { $0.fullPath.lowercased() })
            list = list.filter { photo in
                let tags = Set(photo.hierarchicalTags.map { $0.fullPath.lowercased() })
                return required.isSubset(of: tags)
            }
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = query.lowercased()
            list = list.filter { photo in
                photo.filename.lowercased().contains(q) ||
                photo.hierarchicalTags.contains { $0.fullPath.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
            }
        }
        return list
    }

    private var sections: [PhotoSection] {
        PhotoSection.group(filteredPhotos)
    }

    private var years: [(year: String, sectionID: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for s in sections where s.id != "unknown" {
            let y = String(s.id.prefix(4))
            if !seen.contains(y) { seen.insert(y); out.append((y, s.id)) }
        }
        return out
    }

    private var suggestions: [TagSuggestion] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let activeIDs = Set(activeTags.map(\.id))
        return Array(manager.allTags.lazy.filter {
            !activeIDs.contains($0.id) &&
            ($0.displayName.lowercased().contains(q) || $0.fullPath.lowercased().contains(q))
        }.prefix(6))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let cell = grid.cellSize(for: width)

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("__top__")

                    header

                    if !activeTags.isEmpty {
                        tagPills
                    }
                    if showSearch {
                        searchField
                        if !suggestions.isEmpty {
                            suggestionsList
                        }
                    }

                    if filteredPhotos.isEmpty {
                        ContentUnavailableView(
                            "No photos match.",
                            systemImage: "photo.stack"
                        )
                        .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: grid.columns(for: width), spacing: 2, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.photos) { photo in
                                        gridCell(photo: photo, cellSize: cell)
                                    }
                                } header: {
                                    Text(section.title.uppercased())
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .tracking(0.2)
                                        .foregroundStyle(Design.ink2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 14)
                                        .padding(.bottom, 6)
                                        .background(Design.bg)
                                        .id(section.id)
                                }
                            }
                        }
                    }

                    // Select-mode bottom bar inside scroll content so it pushes the grid.
                    if selectMode {
                        Color.clear.frame(height: 72)
                    }
                }
                .refreshable { await manager.rescan() }
                .overlay(alignment: .trailing) {
                    if years.count > 1 && !selectMode {
                        YearScrubber(years: years) { sectionID in
                            withAnimation { proxy.scrollTo(sectionID, anchor: .top) }
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if selectMode { selectBottomBar }
                }
                .onChange(of: scrollToTopTrigger) {
                    withAnimation { proxy.scrollTo("__top__", anchor: .top) }
                }
            }
        }
        .background(Design.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .fullScreenCover(item: $viewerPhoto) { photo in
            PhotoViewerView(photos: filteredPhotos, initialPhoto: photo)
                .id(viewerID)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: Binding<ShareBag?>(
            get: { shareURLs.map { ShareBag(urls: $0) } },
            set: { shareURLs = $0?.urls }
        )) { bag in
            ShareSheet(items: bag.urls)
        }
        .navigationDestination(isPresented: $goToSlideshow) {
            if let m = playableMemory {
                MemorySlideshowView(memory: m)
            }
        }
        .confirmationDialog(
            photoMenu?.filename ?? "",
            isPresented: Binding(get: { photoMenu != nil }, set: { if !$0 { photoMenu = nil } }),
            titleVisibility: .visible
        ) {
            if let p = photoMenu {
                Button("Open") {
                    viewerID = UUID()
                    viewerPhoto = p
                }
                Button("Share") {
                    shareURLs = [p.url]
                }
            }
        }
    }

    // MARK: - Header (custom large title + reserved subtitle slot)

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selectMode
                 ? (selected.isEmpty ? "Select Items" : "\(selected.count) Selected")
                 : title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.6)
                .foregroundStyle(Design.ink)
                .lineLimit(1)

            // Reserve the subtitle slot so toggling Select mode doesn't jump.
            Group {
                if selectMode {
                    Text(selected.isEmpty
                         ? "Tap photos to select"
                         : "Tap Share to send \(selected.count == 1 ? "this photo" : "these photos")")
                } else if let s = subtitle, !s.isEmpty {
                    Text(s)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(Design.ink3)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var tagPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(activeTags) { tag in
                    HStack(spacing: 5) {
                        Image(systemName: tag.icon)
                            .font(.system(size: 9.5))
                        Text(tag.displayName)
                            .font(.system(size: 11.5, weight: .medium))
                        Button {
                            activeTags.removeAll { $0.id == tag.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .foregroundStyle(Design.accentColor)
                    .background(Design.accentSoft, in: Capsule())
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Design.ink3)
            TextField("Search by name or tag", text: $query)
                .font(.system(size: 15))
                .tint(Design.accentColor)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Design.ink3)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(red: 0.235, green: 0.216, blue: 0.176).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var suggestionsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, tag in
                Button {
                    activeTags.append(tag)
                    query = ""
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tag.icon)
                            .font(.system(size: 13))
                            .foregroundStyle(Design.accentColor)
                        Text(tag.displayName)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Design.ink)
                        Spacer()
                        Text("\(tag.count)")
                            .font(.system(size: 12))
                            .foregroundStyle(Design.ink3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                if idx < suggestions.count - 1 {
                    Divider().background(Design.separator).padding(.leading, 14)
                }
            }
        }
        .background(Design.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.03), radius: 1, y: 1)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Grid cell

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        let isSelected = selected.contains(photo.id)
        ZStack {
            ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
                .frame(width: cellSize, height: cellSize)
                .scaleEffect(selectMode && isSelected ? 0.9 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isSelected)

            if selectMode {
                Rectangle()
                    .fill(isSelected ? Design.accentColor.opacity(0.18) : .clear)
                    .animation(.easeInOut(duration: 0.15), value: isSelected)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ZStack {
                            if isSelected {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Design.accentColor, .white)
                            } else {
                                Circle()
                                    .fill(Color.black.opacity(0.25))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            }
                        }
                        .padding(6)
                    }
                }
            }
        }
        .frame(width: cellSize, height: cellSize)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectMode {
                if selected.contains(photo.id) { selected.remove(photo.id) }
                else { selected.insert(photo.id) }
            } else {
                viewerID = UUID()
                viewerPhoto = photo
            }
        }
        .onLongPressGesture {
            if !selectMode { photoMenu = photo }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if selectMode {
                Button("Cancel") {
                    selectMode = false
                    selected.removeAll()
                }
                .foregroundStyle(Design.accentColor)
            } else if isRoot {
                Button { showSettings = true } label: {
                    Image(systemName: "gear")
                }
            }
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectMode {
                Button("Done") {
                    selectMode = false
                    selected.removeAll()
                }
                .fontWeight(.semibold)
                .foregroundStyle(Design.accentColor)
            } else {
                if playableMemory != nil {
                    Button {
                        goToSlideshow = true
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Design.accentColor)
                }

                Button {
                    selectMode = true
                    selected.removeAll()
                } label: {
                    Image(systemName: "checkmark.circle")
                }

                Button { scrollToTopTrigger.toggle() } label: {
                    Image(systemName: "arrow.up")
                }

                Button {
                    sizeTier = (sizeTier + 1) % 3
                } label: {
                    Image(systemName: grid.gridIconName)
                }
            }
        }
    }

    // MARK: - Select bottom bar

    private var selectBottomBar: some View {
        HStack {
            Button {
                let urls = filteredPhotos.filter { selected.contains($0.id) }.map(\.url)
                guard !urls.isEmpty else { return }
                shareURLs = urls
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share")
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected.isEmpty ? Design.ink3 : Design.accentColor)
            }
            .disabled(selected.isEmpty)

            Spacer()

            Text(selected.isEmpty
                 ? "Select items"
                 : "\(selected.count) \(selected.count == 1 ? "photo" : "photos") selected")
                .font(.system(size: 13))
                .foregroundStyle(Design.ink2)

            Spacer()

            Button {
                if selected.count == filteredPhotos.count {
                    selected.removeAll()
                } else {
                    selected = Set(filteredPhotos.map(\.id))
                }
            } label: {
                Text(selected.count == filteredPhotos.count && !filteredPhotos.isEmpty ? "Deselect All" : "Select All")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Design.accentColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 28)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Design.separator)
                .frame(height: 0.5)
        }
    }

}

// MARK: - Section model

struct PhotoSection: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoFile]

    static func group(_ photos: [PhotoFile]) -> [PhotoSection] {
        let sorted = photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        var out: [PhotoSection] = []
        var curKey = ""
        var curTitle = ""
        var bucket: [PhotoFile] = []
        for p in sorted {
            let key: String, title: String
            if let d = p.dateTaken {
                let c = cal.dateComponents([.year, .month], from: d)
                key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
                title = fmt.string(from: d)
            } else {
                key = "unknown"; title = "Unknown Date"
            }
            if key != curKey {
                if !bucket.isEmpty { out.append(PhotoSection(id: curKey, title: curTitle, photos: bucket)) }
                curKey = key; curTitle = title; bucket = [p]
            } else {
                bucket.append(p)
            }
        }
        if !bucket.isEmpty { out.append(PhotoSection(id: curKey, title: curTitle, photos: bucket)) }
        return out
    }
}

// MARK: - Year scrubber

struct YearScrubber: View {
    let years: [(year: String, sectionID: String)]
    let onScrollTo: (String) -> Void

    @State private var isDragging = false
    @State private var lastIndex = -1

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(Array(years.enumerated()), id: \.element.year) { idx, entry in
                    Text("'" + entry.year.suffix(2))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(isDragging && idx == lastIndex
                                         ? Design.accentColor
                                         : (isDragging ? Design.ink : Design.ink3))
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
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastIndex = -1
                    }
            )
        }
        .frame(width: 28)
        .padding(.vertical, 40)
    }
}

// MARK: - Share plumbing (Identifiable wrapper so .sheet(item:) works for arrays of URLs)

private struct ShareBag: Identifiable {
    let id = UUID()
    let urls: [URL]
}
