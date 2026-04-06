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
    @AppStorage("gridColumnCount") private var columnCount: Int = 3
    @State private var searchText: String = ""
    @State private var selectedPhoto: PhotoFile?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showShareSheet = false

    private var filteredPhotos: [PhotoFile] {
        manager.search(query: searchText)
    }

    private var isDateSorted: Bool {
        manager.currentSortOrder == .dateAscending || manager.currentSortOrder == .dateDescending
    }

    private var photoSections: [PhotoSection] {
        let photos = filteredPhotos
        guard isDateSorted else {
            return [PhotoSection(id: "all", title: "", photos: photos)]
        }

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

    private var yearIndex: [(year: String, sectionID: String)] {
        var result: [(year: String, sectionID: String)] = []
        var seen = Set<String>()
        for section in photoSections where section.id != "all" {
            let year = String(section.id.prefix(4))
            if !seen.contains(year) {
                seen.insert(year)
                result.append((year, section.id))
            }
        }
        return result
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: columnCount)
    }

    var body: some View {
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
                            Text("Choose a folder in the Folders tab to get started.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(32)
                }
            } else {
                photoGrid
            }
        }
        .navigationTitle("All Photos")
        .searchable(text: $searchText, prompt: "Search by filename")
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        isSelecting = false
                        selectedIDs.removeAll()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("\(selectedIDs.count) selected")
                        .font(.headline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selectedIDs.count == filteredPhotos.count ? "Deselect All" : "Select All") {
                        if selectedIDs.count == filteredPhotos.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(filteredPhotos.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedIDs.isEmpty)
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $manager.currentSortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { cycleColumnCount() } label: {
                        Image(systemName: gridIconName)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isSelecting = true } label: {
                        Image(systemName: "checkmark.circle")
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoViewerView(photos: filteredPhotos, initialPhoto: photo)
        }
        .sheet(isPresented: $showShareSheet) {
            let urls: [Any] = filteredPhotos.filter { selectedIDs.contains($0.id) }.map(\.url)
            ShareSheet(items: urls)
        }
    }

    private var photoGrid: some View {
        GeometryReader { geo in
            let cellSize = max(1, (geo.size.width - CGFloat(columnCount - 1) * 2) / CGFloat(columnCount))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(photoSections) { section in
                            Section {
                                ForEach(section.photos) { photo in
                                    gridCell(photo: photo, cellSize: cellSize)
                                }
                            } header: {
                                if !section.title.isEmpty {
                                    Text(section.title)
                                        .font(.title3)
                                        .fontWeight(.bold)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.top, 16)
                                        .padding(.bottom, 6)
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
                    if isDateSorted && yearIndex.count > 1 {
                        YearScrubber(years: yearIndex) { sectionID in
                            withAnimation {
                                proxy.scrollTo(sectionID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gridCell(photo: PhotoFile, cellSize: CGFloat) -> some View {
        ThumbnailView(url: photo.url, size: cellSize, isVideo: photo.isVideo, isLivePhoto: photo.livePhotoVideoURL != nil)
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if isSelecting && selectedIDs.contains(photo.id) {
                    Color.black.opacity(0.2)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    ZStack {
                        if selectedIDs.contains(photo.id) {
                            Circle()
                                .fill(Design.accentColor)
                                .frame(width: 26, height: 26)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
                                .frame(width: 26, height: 26)
                                .shadow(color: .black.opacity(0.4), radius: 3)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selectedIDs.contains(photo.id))
                    .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelecting {
                    if selectedIDs.contains(photo.id) {
                        selectedIDs.remove(photo.id)
                    } else {
                        selectedIDs.insert(photo.id)
                    }
                } else {
                    selectedPhoto = photo
                }
            }
    }

    private var gridIconName: String {
        switch columnCount {
        case 3: return "square.grid.3x3"
        case 4: return "rectangle.grid.3x2"
        default: return "rectangle.grid.3x2"
        }
    }

    private func cycleColumnCount() {
        switch columnCount {
        case 3: columnCount = 4
        case 4: columnCount = 5
        default: columnCount = 3
        }
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
