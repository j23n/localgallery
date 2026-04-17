import SwiftUI
import MapKit

struct EXIFSheetView: View {
    let photo: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @State private var exifData: EXIFData?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                EXIFContentView(photo: photo, exifData: exifData, isLoading: isLoading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            exifData = await manager.loadEXIF(for: photo)
            isLoading = false
        }
    }
}

struct EXIFContentView: View {
    let photo: PhotoFile
    let exifData: EXIFData?
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    section("File") {
                        infoRow("Filename", value: photo.filename)
                        infoRow("Dimensions", value: dimensionsText)
                        infoRow("File Size", value: formattedFileSize(photo.fileSize))
                        infoRow("Date Taken", value: formattedDate)
                    }

                    if !photo.hierarchicalTags.isEmpty {
                        section("Tags") {
                            HierarchicalTagFlowView(tags: photo.hierarchicalTags)
                                .padding(.vertical, 2)
                        }
                    }

                    section("Camera") {
                        infoRow("Camera", value: cameraText)
                        infoRow("Lens", value: exifData?.lens)
                        infoRow("Aperture", value: apertureText)
                        infoRow("Shutter Speed", value: shutterSpeedText)
                        infoRow("ISO", value: exifData?.iso.map { "\($0)" })
                    }

                    section("Location") {
                        if let lat = exifData?.gpsLatitude, let lon = exifData?.gpsLongitude {
                            infoRow("Coordinates", value: String(format: "%.5f, %.5f", lat, lon))
                            mapView(latitude: lat, longitude: lon)
                        } else {
                            infoRow("Coordinates", value: nil)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
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
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Info Row

    private func infoRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value ?? "—")
                .font(.subheadline)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Formatted Values

    private var dimensionsText: String? {
        if let w = exifData?.pixelWidth, let h = exifData?.pixelHeight {
            return "\(w) × \(h) px"
        }
        if let dim = photo.dimensions {
            return "\(Int(dim.width)) × \(Int(dim.height)) px"
        }
        return nil
    }

    private var formattedDate: String? {
        let date = exifData?.dateTimeOriginal ?? photo.dateTaken
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var cameraText: String? {
        let make = exifData?.cameraMake
        let model = exifData?.cameraModel
        switch (make, model) {
        case let (m?, mod?):
            if mod.localizedCaseInsensitiveContains(m) {
                return mod
            }
            return "\(m) \(mod)"
        case let (m?, nil): return m
        case let (nil, mod?): return mod
        case (nil, nil): return nil
        }
    }

    private var apertureText: String? {
        guard let aperture = exifData?.aperture else { return nil }
        return String(format: "f/%.1f", aperture)
    }

    private var shutterSpeedText: String? {
        guard let speed = exifData?.shutterSpeed else { return nil }
        if speed >= 1.0 {
            return String(format: "%.1fs", speed)
        } else if speed > 0 {
            let denominator = Int(round(1.0 / speed))
            return "1/\(denominator)s"
        }
        return nil
    }

    private func formattedFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                  proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
