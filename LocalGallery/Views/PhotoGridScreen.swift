import SwiftUI
import UIKit

/// Non-observed section visibility tracker. Mutating `counts` does NOT trigger
/// SwiftUI body re-evaluation — only reassigning the @State reference would.
/// This lets onAppear/onDisappear track section visibility silently during
/// scrolling; the visible date-range string is synced to @State on a debounce.
private final class SectionTracker {
    var counts: [String: Int] = [:]
    var visibleIDs: Set<String> {
        Set(counts.compactMap { $0.value > 0 ? $0.key : nil })
    }
    func reset() { counts.removeAll() }
}

/// Unified photo grid used for All Photos, folder/event drill-ins, tag drill-ins,
/// and memory "grid mode". Supports search, tag filtering, year scrubber,
/// Select mode with share, and long-press menus — matching the Quiet design.
struct PhotoGridScreen: View {
    let title: String
    /// Static subtitle shown when no in-screen filter is active and
    /// `showVisibleDateRange` is false. When the user activates a filter
    /// (search query or tag chip), the subtitle switches to the match count;
    /// when `showVisibleDateRange` is true, the subtitle becomes a live
    /// date-range derived from the on-screen sections.
    var subtitle: String?
    let photos: [PhotoFile]
    /// When true, render the gear button (settings) in the toolbar.
    var isRoot: Bool = false
    /// Enable search field + tag suggestions in the header.
    var showSearch: Bool = false
    /// When true, show a live "<first> – <last>" date range derived from the
    /// sections currently scrolled into view, pinned below the nav bar so it
    /// stays visible as the user scrolls. Used by the Photos tab.
    var showVisibleDateRange: Bool = false
    /// When present, shows a "Play" button in the toolbar to jump into slideshow.
    var playableMemory: Memory? = nil
    /// When set, photo long-press offers "Set as featured image" for this person.
    var featureContextPerson: TagSuggestion? = nil
    /// Tags applied as the initial filter — used by widget deep-links that
    /// land on AllPhotos with a specific tag set already chosen.
    var initialTags: [TagSuggestion] = []

    @Environment(GalleryStore.self) private var store
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("gridSizeTier") private var sizeTier: Int = 0

    @State private var query: String = ""
    @State private var activeTags: [TagSuggestion] = []
    @State private var scrollToTopTrigger = false
    @FocusState private var searchFocused: Bool

    // Viewer
    @State private var viewerPhoto: PhotoFile?
    @State private var viewerID = UUID()
    // Tracks the viewer's position by photo id rather than raw index. Two
    // benefits over an Int: (1) it survives transient view recreations such
    // as the foreground rescan rebuilding `filtered`, and (2) if a rescan
    // re-orders or splices photos around the current one, the viewer
    // re-resolves to the same photo at its new index instead of silently
    // landing on whatever ended up at the old index. Initial UUID() is a
    // placeholder — never read because `openViewer(at:)` writes the real id
    // before the cover binds to `viewerPhoto`.
    @State private var viewerCurrentPhotoID: UUID = UUID()

    // Select mode
    @State private var selectMode = false
    @State private var selected: Set<UUID> = []
    @State private var hasSeededInitialTags = false

    // Large title collapsed → show inline principal with date range
    @State private var largeTitleCollapsed = false

    // Pinch-to-zoom grid size
    @State private var isPinching = false
    @State private var pinchBaseTier: Int = 0

    // Share request (drives the unified size-selection share flow)
    @State private var shareRequest: PhotoShareRequest?

    // Settings sheet (root only)
    @State private var showSettings = false

    // Slideshow navigation
    @State private var goToSlideshow = false

    // Cached filter results — recomputed off-main when inputs change.
    // Keeping these in @State (instead of computed properties) means body
    // evaluations don't re-sort/re-filter 20k photos on every keystroke
    // or focus change.
    @State private var filtered: [PhotoFile] = []
    @State private var sectionsCache: [PhotoSection] = []
    @State private var yearsCache: [(year: String, sectionID: String)] = []

    // Per-section count of currently-rendered photo cells. Stored in a
    // reference type so mutations do NOT trigger body re-evaluation —
    // critical for the 20k All Photos grid where per-cell onAppear would
    // otherwise force SwiftUI to diff the entire ForEach tree every frame.
    // The date-range @State string is synced on a debounce (~300ms).
    @State private var sectionTracker = SectionTracker()
    @State private var liveDateRange: String = ""
    @State private var dateRangeUpdateTask: Task<Void, Never>?

    private func grid(isLandscape: Bool) -> GridLayoutConfig {
        GridLayoutConfig(sizeTier: sizeTier, isLandscape: isLandscape)
    }

    // Cheap identity for the photos input: count + first/last date catches
    // both re-scans (count changes) and enrichment (dates change). Exposed
    // as internal so unit tests can build a FilterKey without going through
    // the SwiftUI view — `private` would make it unreachable from the test
    // bundle even with `@testable import`.
    struct FilterKey: Equatable {
        let count: Int
        let firstDate: Date?
        let lastDate: Date?
        let query: String
        let activeTagIDs: [String]
    }

    private var filterKey: FilterKey {
        FilterKey(
            count: photos.count,
            firstDate: photos.first?.dateTaken,
            lastDate: photos.last?.dateTaken,
            query: query.trimmingCharacters(in: .whitespaces),
            activeTagIDs: activeTags.map(\.id)
        )
    }

    /// True when the user has narrowed the grid via the search field or a tag
    /// chip — i.e. `filtered.count` no longer reflects the full input set.
    private var isFiltered: Bool {
        !activeTags.isEmpty || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The title shown in the navigation bar — collapses to the select-mode
    /// status when in select mode so the same chrome conveys both states.
    private var displayTitle: String {
        if selectMode {
            return selected.isEmpty ? "Select Items" : "\(selected.count) Selected"
        }
        return title
    }

    /// The subtitle line rendered just under the large nav title. Three modes,
    /// in priority order: select-mode hint > visible-date-range (Photos tab) >
    /// match-count (when filtered) > caller-supplied static subtitle.
    private var displaySubtitle: String? {
        if selectMode {
            return selected.isEmpty
                ? "Tap photos to select"
                : "Tap Share to send \(selected.count == 1 ? "this photo" : "these photos")"
        }
        if showVisibleDateRange {
            return liveDateRange
        }
        if isFiltered {
            let n = filtered.count
            return "\(n) \(n == 1 ? "match" : "matches")"
        }
        return subtitle
    }

    /// Whether the subtitle bar should currently render visible content. Both
    /// the in-content variant and the pinned safeAreaInset variant gate on
    /// this so they stay in sync.
    private var hasSubtitleContent: Bool {
        guard let sub = displaySubtitle else { return false }
        return !sub.isEmpty
    }

    /// Debounced sync of the non-observed section tracker to the @State
    /// `liveDateRange` string. At most one body re-evaluation per 300ms
    /// instead of one per cell onAppear — eliminates the 20k-item ForEach
    /// diff that was causing scroll stutter on the All Photos grid.
    private func scheduleDateRangeUpdate() {
        dateRangeUpdateTask?.cancel()
        dateRangeUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            liveDateRange = computeDateRange()
        }
    }

    /// Compute the date range from the non-observed section tracker.
    private func computeDateRange() -> String {
        let visible = sectionTracker.visibleIDs
        var minDate: Date?
        var maxDate: Date?
        for section in sectionsCache where visible.contains(section.id) {
            guard let range = section.dateRange else { continue }
            if minDate == nil || range.lowerBound < minDate! { minDate = range.lowerBound }
            if maxDate == nil || range.upperBound > maxDate! { maxDate = range.upperBound }
        }
        guard let first = minDate, let last = maxDate else { return "" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return Self.dateRangeFormatter.string(from: first)
        }
        return "\(Self.dateRangeFormatter.string(from: first)) – \(Self.dateRangeFormatter.string(from: last))"
    }

    /// Shared `DateFormatter` for the visible-date-range subtitle. Stable per
    /// process — avoids re-allocating on every body re-evaluation.
    private static let dateRangeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return fmt
    }()

    private var suggestions: [TagSuggestion] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        let activeIDs = Set(activeTags.map(\.id))
        return Array(store.allTags.lazy.filter {
            !activeIDs.contains($0.id) &&
            ($0.displayName.lowercased().contains(q) || $0.fullPath.lowercased().contains(q))
        }.prefix(6))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let isLandscape = verticalSizeClass == .compact
            let grid = grid(isLandscape: isLandscape)
            let cell = grid.cellSize(for: width)

            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("__top__")

                    // On the Photos tab the live date-range subtitle lives in
                    // the toolbar .principal — keep it OUT of scroll content so
                    // per-cell visibleSectionCounts mutations don't force
                    // LazyVGrid layout invalidation every frame.
                    if !showVisibleDateRange || selectMode, hasSubtitleContent {
                        inContentSubtitle(displaySubtitle ?? "")
                    }

                    if !activeTags.isEmpty {
                        tagPills
                    }
                    if showSearch {
                        searchField
                        if !suggestions.isEmpty {
                            suggestionsList
                        }
                    }

                    if filtered.isEmpty {
                        ContentUnavailableView(
                            "No photos match.",
                            systemImage: "photo.stack"
                        )
                        .padding(.top, 48)
                    } else {
                        LazyVGrid(columns: grid.columns(for: width), spacing: 2) {
                            ForEach(sectionsCache) { section in
                                Section {
                                    ForEach(section.photos) { photo in
                                        gridCell(photo: photo, cellSize: cell)
                                            .onAppear {
                                                guard showVisibleDateRange else { return }
                                                sectionTracker.counts[section.id, default: 0] += 1
                                                scheduleDateRangeUpdate()
                                            }
                                            .onDisappear {
                                                guard showVisibleDateRange else { return }
                                                let next = (sectionTracker.counts[section.id] ?? 0) - 1
                                                if next <= 0 {
                                                    sectionTracker.counts.removeValue(forKey: section.id)
                                                } else {
                                                    sectionTracker.counts[section.id] = next
                                                }
                                            }
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
                .scrollDismissesKeyboard(.interactively)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y > 20
                } action: { _, collapsed in
                    largeTitleCollapsed = collapsed
                }
                .refreshable { await store.rescan(kind: .light) }
                .overlay(alignment: .trailing) {
                    if yearsCache.count > 1 && !selectMode {
                        YearScrubber(years: yearsCache) { sectionID in
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
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { scale in
                            if !isPinching {
                                isPinching = true
                                pinchBaseTier = sizeTier
                            }
                            let delta: Int
                            if scale > 1.5 { delta = -2 }
                            else if scale > 1.15 { delta = -1 }
                            else if scale < 0.67 { delta = 2 }
                            else if scale < 0.85 { delta = 1 }
                            else { delta = 0 }
                            sizeTier = max(0, min(GridLayoutConfig.tierCount - 1, pinchBaseTier + delta))
                        }
                        .onEnded { _ in isPinching = false }
                )
            }
        }
        .background(Design.bg)
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .toolbar { toolbarContent }
        .task(id: filterKey) {
            // Seed only once per deep-link mount. Using a flag rather than
            // `activeTags.isEmpty` prevents re-seeding when the user removes
            // all tag chips (which also makes activeTags empty).
            if !initialTags.isEmpty && !hasSeededInitialTags {
                hasSeededInitialTags = true
                activeTags = initialTags
                return
            }
            sectionTracker.reset()
            liveDateRange = ""
            await recomputeFilter()
        }
        .fullScreenCover(item: $viewerPhoto) { _ in
            PhotoViewerView(photos: filtered, currentPhotoID: $viewerCurrentPhotoID)
                .id(viewerID)
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .photoShareSheet(request: $shareRequest)
        .navigationDestination(isPresented: $goToSlideshow) {
            if let m = playableMemory {
                MemorySlideshowView(memory: m)
            }
        }
    }

    // MARK: - Subtitle (in-content for static, pinned for live date range)

    private func inContentSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Design.ink3)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 8)
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
                .focused($searchFocused)
                .submitLabel(.done)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Design.ink3)
                }
            } else if searchFocused {
                Button("Done") {
                    searchFocused = false
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Design.accentColor)
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
            ThumbnailView(
                url: photo.url,
                size: cellSize,
                isVideo: photo.isVideo,
                isLivePhoto: photo.livePhotoVideoURL != nil,
                isRemote: photo.locality.isRemotePlaceholder
            )
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
                openViewer(at: photo)
            }
        }
        .contextMenu {
            if !selectMode {
                Button {
                    openViewer(at: photo)
                } label: {
                    Label("Open", systemImage: "eye")
                }
                PhotoShareMenu(
                    canResize: !photo.isVideo,
                    onSelect: { quality in
                        shareRequest = PhotoShareRequest(photos: [photo], quality: quality)
                    }
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    selectMode = true
                    selected.insert(photo.id)
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                if let person = featureContextPerson {
                    Button {
                        store.people.setFeaturedPhoto(personPath: person.fullPath, photoID: photo.id)
                    } label: {
                        Label("Set as featured image", systemImage: "star")
                    }
                }
            }
        }
    }

    private func openViewer(at photo: PhotoFile) {
        viewerCurrentPhotoID = photo.id
        viewerID = UUID()
        viewerPhoto = photo
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
            }
        }

        // Principal slot: scan progress takes priority over the date-range
        // title button when a scan is running, so the user sees live
        // "X / Y · ~M:SS" instead of a stale date range. The branch lives
        // inside `PrincipalToolbarContent` so the `store.scanProgress` read
        // stays scoped to that view — otherwise every progress tick would
        // re-evaluate this entire screen body and re-diff every visible
        // grid cell, starving thumbnail `.task` closures on the main actor.
        ToolbarItem(placement: .principal) {
            PrincipalToolbarContent(
                title: title,
                displaySubtitle: displaySubtitle,
                showVisibleDateRange: showVisibleDateRange,
                selectMode: selectMode,
                isRoot: isRoot,
                largeTitleCollapsed: largeTitleCollapsed,
                onTitleTap: { scrollToTopTrigger.toggle() }
            )
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

                if isRoot {
                    SettingsToolbarButton(isPresented: $showSettings)
                }
            }
        }
    }

    // MARK: - Select bottom bar

    private var selectBottomBar: some View {
        let selectedPhotos = filtered.filter { selected.contains($0.id) }
        let canResize = !selectedPhotos.isEmpty && selectedPhotos.allSatisfy { !$0.isVideo }

        return HStack {
            PhotoShareMenu(
                canResize: canResize,
                onSelect: { quality in
                    guard !selectedPhotos.isEmpty else { return }
                    shareRequest = PhotoShareRequest(photos: selectedPhotos, quality: quality)
                }
            ) {
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
                if selected.count == filtered.count {
                    selected.removeAll()
                } else {
                    selected = Set(filtered.map(\.id))
                }
            } label: {
                Text(selected.count == filtered.count && !filtered.isEmpty ? "Deselect All" : "Select All")
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

    // MARK: - Filter & sort (off-main)

    /// Sort + filter + group the photos input off the main thread, then publish
    /// to @State. Called by `.task(id: filterKey)` — SwiftUI will cancel the
    /// previous task when inputs change, so only the latest result is applied.
    @MainActor
    private func recomputeFilter() async {
        let snapshotPhotos = photos
        let snapshotQuery = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Hierarchical namespaces (Places, Objects, Scenes) use prefix matching —
        // selecting a parent tag matches all its nested leaves.
        let snapshotRequiredTags: [(path: String, isPrefixMatch: Bool)] = activeTags.map {
            ($0.fullPath.lowercased(), TagNamespace.matchesByPrefix($0.namespace))
        }

        let result: (filtered: [PhotoFile], sections: [PhotoSection], years: [(String, String)]) =
        await Task.detached(priority: .userInitiated) {
            // Filter first (cheap), then sort (expensive — once per input change).
            var list = snapshotPhotos
            if !snapshotRequiredTags.isEmpty {
                list = list.filter { photo in
                    let photoPaths = photo.hierarchicalTags.map { $0.fullPath.lowercased() }
                    return snapshotRequiredTags.allSatisfy { required in
                        photoPaths.contains { hp in
                            if hp == required.path { return true }
                            if required.isPrefixMatch, hp.hasPrefix(required.path + "/") { return true }
                            return false
                        }
                    }
                }
            }
            if !snapshotQuery.isEmpty {
                list = list.filter { photo in
                    if photo.filename.lowercased().contains(snapshotQuery) { return true }
                    for tag in photo.hierarchicalTags {
                        if tag.fullPath.lowercased().contains(snapshotQuery) { return true }
                        if tag.displayName.lowercased().contains(snapshotQuery) { return true }
                    }
                    return false
                }
            }
            let sorted = list.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) }
            let secs = PhotoSection.group(presorted: sorted)
            var years: [(String, String)] = []
            var seen = Set<String>()
            for s in secs where s.id != "unknown" {
                let y = String(s.id.prefix(4))
                if !seen.contains(y) { seen.insert(y); years.append((y, s.id)) }
            }
            return (sorted, secs, years)
        }.value

        // Drop the result if inputs have moved on since we started.
        guard !Task.isCancelled else { return }
        self.filtered = result.filtered
        self.sectionsCache = result.sections
        self.yearsCache = result.years
    }
}

// MARK: - Principal toolbar content

/// Wraps the principal toolbar slot so the `store.scanProgress` read stays
/// scoped to this view's body. If `PhotoGridScreen.body` read scanProgress
/// directly (which it used to, via the `if store.scanProgress != nil`
/// branch), every progress tick during a scan would re-evaluate the whole
/// screen body — re-diffing every visible cell on the main actor and
/// starving the thumbnail `.task` closures that are queued on it.
private struct PrincipalToolbarContent: View {
    @Environment(GalleryStore.self) private var store
    let title: String
    let displaySubtitle: String?
    let showVisibleDateRange: Bool
    let selectMode: Bool
    let isRoot: Bool
    let largeTitleCollapsed: Bool
    let onTitleTap: () -> Void

    var body: some View {
        if store.scanProgress != nil {
            ScanProgressBanner()
        } else if showVisibleDateRange && !selectMode {
            Button(action: onTitleTap) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .fontWeight(.semibold)
                    if let sub = displaySubtitle, !sub.isEmpty {
                        Text(sub)
                            .font(.caption2)
                            .foregroundStyle(Design.ink2)
                    }
                }
                .foregroundStyle(Design.ink)
            }
            .buttonStyle(.plain)
            // Root uses .large title mode — fade the principal in only
            // after the large title has scrolled away to avoid duplication.
            .opacity(isRoot && !largeTitleCollapsed ? 0 : 1)
            .animation(.easeInOut(duration: 0.15), value: largeTitleCollapsed)
        }
    }
}

// MARK: - Section model

struct PhotoSection: Identifiable {
    let id: String
    let title: String
    let photos: [PhotoFile]
    /// Pre-computed min/max of `dateTaken` across this section's photos.
    /// Cached at grouping time so the live visible-date-range subtitle on
    /// the Photos tab doesn't re-flatten every section's photos on each
    /// SwiftUI body re-evaluation.
    let dateRange: ClosedRange<Date>?

    init(id: String, title: String, photos: [PhotoFile]) {
        self.id = id
        self.title = title
        self.photos = photos
        let dates = photos.compactMap(\.dateTaken)
        if let first = dates.min(), let last = dates.max() {
            self.dateRange = first...last
        } else {
            self.dateRange = nil
        }
    }

    static func group(_ photos: [PhotoFile]) -> [PhotoSection] {
        group(presorted: photos.sorted { ($0.dateTaken ?? .distantPast) > ($1.dateTaken ?? .distantPast) })
    }

    /// Group an array that is already sorted newest-first by dateTaken — skips
    /// the sort pass so the caller can reuse a pre-sorted array.
    static func group(presorted sorted: [PhotoFile]) -> [PhotoSection] {
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

