import SwiftUI
import MapKit

/// Inline info drawer rendered on the same canvas as the photo viewer. Loads
/// EXIF + photo-tools metadata for the visible photo and re-loads as the
/// photo id changes (paging while the drawer is open).
struct PhotoInfoPanel: View {
    let photo: PhotoFile
    @Environment(GalleryStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var exifData: EXIFData?
    @State private var sidecar = SidecarDocument.empty
    @State private var isLoading = true
    @State private var debugExpanded = false

    var body: some View {
        ScrollView {
            content
                .padding(.top, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .task(id: photo.id) {
            isLoading = true
            exifData = nil
            sidecar = SidecarDocument.empty
            async let exif = store.loadEXIF(for: photo)
            sidecar = SidecarDocument.read(imageURL: photo.url)
            exifData = await exif
            isLoading = false
        }
        .onChange(of: store.analysis.isRunning) { _, running in
            guard !running else { return }
            sidecar = SidecarDocument.read(imageURL: photo.url)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                header

                peopleSection

                if hasPlace {
                    placeSection
                }

                seenSection

                if hasShot {
                    shotSection
                }

                debugSection
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let date = takenDate {
                HStack(alignment: .firstTextBaseline) {
                    Text(PhotoInfoFormatting.headerDate(date))
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(PhotoInfoFormatting.headerTime(date))
                        .font(.title3.weight(.regular))
                        .foregroundStyle(.secondary)
                }
            }

            Text(photo.filename)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let meta = headerMetaLine {
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let filesURL = PhotoInfoFormatting.filesAppURL(for: photo.url) {
                Button {
                    openURL(filesURL)
                } label: {
                    Label("Show in Files", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - People

    private var peopleSection: some View {
        section("People") {
            if photo.faceRegions.isEmpty && onFileNoBoxTags.isEmpty {
                Text("No faces on this photo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else if !photo.faceRegions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(photo.faceRegions.enumerated()), id: \.offset) { index, region in
                            faceChip(region, index: index)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if !onFileNoBoxTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On file, no box")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HierarchicalTagFlowView(tags: onFileNoBoxTags)
                }
                .padding(.top, 6)
            }
        }
    }

    private func faceChip(_ region: FaceRegion, index: Int) -> some View {
        let label = region.name ?? "Face \(index + 1)"
        return VStack(spacing: 6) {
            PersonThumbnailView(
                url: photo.url,
                region: region,
                size: 56,
                cornerRadius: 8,
                isRemote: photo.locality.isRemotePlaceholder
            )
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(region.name == nil ? .secondary : .primary)
                .lineLimit(1)
                .frame(width: 56)
        }
    }

    // MARK: - Place

    private var placeSection: some View {
        section("Place") {
            if let title = PhotoChrome.formattedLocation(for: photo) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 2)
            } else {
                Text("No place yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            }

            if let lat = latitude, let lon = longitude {
                Text(String(format: "%.5f, %.5f", lat, lon))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                mapView(latitude: lat, longitude: lon)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Seen

    private var seenSection: some View {
        section("Seen") {
            if objectTags.isEmpty && sceneTags.isEmpty && otherSeenTags.isEmpty {
                Text("Not tagged yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                if !objectTags.isEmpty {
                    tagGroup("Objects", tags: objectTags)
                }
                if !sceneTags.isEmpty {
                    tagGroup("Scenes", tags: sceneTags)
                }
                if !otherSeenTags.isEmpty {
                    tagGroup("Other", tags: otherSeenTags)
                }
            }
        }
    }

    private func tagGroup(_ title: String, tags: [HierarchicalTag]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HierarchicalTagFlowView(tags: tags)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Shot

    private var shotSection: some View {
        section("Shot") {
            if cameraText != nil || exifData?.lens != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let camera = cameraText {
                        Text(camera)
                            .font(.subheadline.weight(.medium))
                    }
                    Spacer(minLength: 8)
                    if let lens = exifData?.lens {
                        Text(lens)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.vertical, 2)
            }

            if hasExposure {
                HStack(spacing: 16) {
                    if let aperture = apertureText {
                        Text(aperture)
                    }
                    if let shutter = shutterSpeedText {
                        Text(shutter)
                    }
                    if let iso = exifData?.iso {
                        Text("ISO \(iso)")
                    }
                }
                .font(.subheadline.monospacedDigit())
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Debug

    private var debugSection: some View {
        section("On-device") {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { debugExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(debugExpanded ? "Hide debug" : "Debug")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if store.analysis.isRunning && debugExpanded {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Image(systemName: debugExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)

            if debugExpanded {
                debugBody
                    .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var debugBody: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            debugRow("Tag", primary: tools.taggerVersion, secondary: taggedAgo, detail: clipDetail)
            debugRow("Face", primary: tools.facePack, secondary: facedAgo, detail: facesDebugText)
            debugRow("Place", primary: placeDebugPrimary, secondary: nil, detail: nil)
            debugRow(
                "Sidecar",
                primary: PhotoInfoFormatting.sidecarOnDiskLabel(photo.sidecarOnDisk || sidecar.exists),
                secondary: PhotoInfoFormatting.sidecarCacheLabel(photo.sidecarStatus),
                detail: nil
            )
            if let source = PhotoInfoFormatting.dateSourceLabel(
                hasDate: takenDate != nil,
                fromMetadata: photo.dateFromMetadata
            ) {
                debugRow("Date", primary: source, secondary: nil, detail: nil)
            }
        }

        Divider()
            .padding(.vertical, 10)

        HStack(spacing: 8) {
            rerunButton("Tag", systemImage: "tag", enabled: canRetag) {
                Task { await store.analysis.startOne(photo, phases: [.tagging]) }
            }
            rerunButton("Faces", systemImage: "person.crop.rectangle", enabled: canRescanFaces) {
                Task { await store.analysis.startOne(photo, phases: [.faces]) }
            }
            rerunButton("Geocode", systemImage: "mappin.and.ellipse", enabled: canRegeocode) {
                Task { await store.analysis.startOne(photo, phases: [.places]) }
            }
        }
    }

    private func debugRow(_ label: String, primary: String?, secondary: String?, detail: String?) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary ?? "—")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Section

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.8)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Derived

    private var takenDate: Date? {
        exifData?.dateTimeOriginal ?? photo.dateTaken
    }

    private var latitude: Double? { exifData?.gpsLatitude ?? photo.gpsLatitude }
    private var longitude: Double? { exifData?.gpsLongitude ?? photo.gpsLongitude }

    private var headerMetaLine: String? {
        var parts: [String] = []
        if let dimensions = dimensionsText { parts.append(dimensions) }
        parts.append(formattedFileSize(photo.fileSize))
        if let format = PhotoInfoFormatting.fileFormat(filename: photo.filename) {
            parts.append(format)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var hasPlace: Bool {
        latitude != nil || PhotoChrome.formattedLocation(for: photo) != nil
    }

    private var hasShot: Bool {
        cameraText != nil || exifData?.lens != nil || hasExposure
    }

    private var hasExposure: Bool {
        apertureText != nil || shutterSpeedText != nil || exifData?.iso != nil
    }

    private var onFileNoBoxTags: [HierarchicalTag] {
        var tags = photo.peopleTagsWithoutFace
        var seen = Set(tags.map { $0.displayName.lowercased() })
        for name in sidecar.namedWithoutBox {
            if seen.insert(name.lowercased()).inserted {
                tags.append(HierarchicalTag(raw: HierarchicalTag.personPath(for: name)))
            }
        }
        return tags
    }

    private var objectTags: [HierarchicalTag] {
        tags(in: "objects")
    }

    private var sceneTags: [HierarchicalTag] {
        tags(in: "scenes")
    }

    private var otherSeenTags: [HierarchicalTag] {
        photo.hierarchicalTags.filter { tag in
            switch tag.namespace?.lowercased() {
            case "people", "places", "objects", "scenes": return false
            default: return true
            }
        }
    }

    private func tags(in namespace: String) -> [HierarchicalTag] {
        photo.hierarchicalTags.filter { $0.namespace?.lowercased() == namespace }
    }

    private var tools: PhotoToolsMetadata {
        photo.photoTools.merging(over: sidecar.tools)
    }

    private var taggedAgo: String? {
        tools.taggedAt.map { PhotoInfoFormatting.relativeTimestamp($0) }
    }

    private var facedAgo: String? {
        tools.faceTaggedAt.map { PhotoInfoFormatting.relativeTimestamp($0) }
    }

    private var clipDetail: String? {
        tools.clipModel.map { "CLIP  \($0)" }
    }

    private var facesDebugText: String? {
        let named = photo.faceRegions.filter { $0.name != nil }.count
        let unnamed = photo.faceRegions.count - named
        let withheld = onFileNoBoxTags.count
        if let summary = PhotoInfoFormatting.facesSummary(
            named: named,
            unnamed: unnamed,
            scanned: tools.facePack != nil
        ) {
            if withheld > 0 {
                return "\(summary) · \(withheld) on file, no box"
            }
            return summary
        }
        if withheld > 0 {
            return withheld == 1 ? "1 on file, no box" : "\(withheld) on file, no box"
        }
        return nil
    }

    private var placeDebugPrimary: String {
        if PhotoChrome.formattedLocation(for: photo) != nil { return "city on file" }
        if latitude != nil { return "not geocoded" }
        return "no GPS"
    }

    private var canRetag: Bool {
        store.tagging.isAvailable && TaggingService.isEligible(photo) && !store.analysis.isRunning
    }

    private var canRescanFaces: Bool {
        store.faces.isAvailable && FaceService.isEligible(photo) && !store.analysis.isRunning
    }

    private var canRegeocode: Bool {
        GeocodingService.isEligible(photo, force: true) && !store.analysis.isRunning
    }

    private func rerunButton(_ title: String, systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.roundedRectangle)
        .disabled(!enabled)
    }

    // MARK: - Formatted Values

    private var dimensionsText: String? {
        EXIFFormatters.dimensions(
            exifWidth: exifData?.pixelWidth,
            exifHeight: exifData?.pixelHeight,
            runtimeSize: photo.dimensions
        )
    }

    private var cameraText: String? {
        EXIFFormatters.camera(make: exifData?.cameraMake, model: exifData?.cameraModel)
    }

    private var apertureText: String? {
        EXIFFormatters.aperture(exifData?.aperture)
    }

    private var shutterSpeedText: String? {
        EXIFFormatters.shutterSpeed(exifData?.shutterSpeed)
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        EXIFFormatters.fileSize(bytes)
    }

    // MARK: - Map

    @ViewBuilder
    private func mapView(latitude: Double, longitude: Double) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 1000,
            longitudinalMeters: 1000
        )
        Map(initialPosition: .region(region)) {
            Marker("", coordinate: coordinate)
        }
        .frame(height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }
}

// MARK: - Tag Flow Layout

private struct HierarchicalTagFlowView: View {
    let tags: [HierarchicalTag]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.fullPath) { tag in
                Label {
                    Text(tag.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: TagNamespace.icon(for: tag.namespace))
                        .font(.system(size: 9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.systemGray5), in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: ProposedViewSize(result.sizes[index]))
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], sizes: [CGSize]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            // Constrain chips wider than the row so their text wraps inside,
            // rather than overflowing and stretching the parent.
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            sizes.append(size)
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions, sizes)
    }
}
