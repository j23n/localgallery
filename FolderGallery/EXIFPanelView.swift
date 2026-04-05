import SwiftUI
import MapKit

struct EXIFPanelView: View {
    let photo: PhotoFile
    @EnvironmentObject var manager: GalleryManager
    @State private var exifData: EXIFData?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    infoRow("Filename", value: photo.filename)
                    infoRow("Dimensions", value: dimensionsText)
                    infoRow("File Size", value: formattedFileSize(photo.fileSize))
                    infoRow("Date Taken", value: formattedDate)
                }

                Section("Camera") {
                    infoRow("Camera", value: cameraText)
                    infoRow("Lens", value: exifData?.lens)
                    infoRow("Aperture", value: apertureText)
                    infoRow("Shutter Speed", value: shutterSpeedText)
                    infoRow("ISO", value: exifData?.iso.map { "\($0)" })
                }

                Section("Location") {
                    if let lat = exifData?.gpsLatitude, let lon = exifData?.gpsLongitude {
                        infoRow("Coordinates", value: String(format: "%.5f, %.5f", lat, lon))
                        mapView(latitude: lat, longitude: lon)
                    } else {
                        infoRow("Coordinates", value: nil)
                    }
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            exifData = await manager.loadEXIF(for: photo)
            isLoading = false
        }
    }

    // MARK: - Info Row

    private func infoRow(_ label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
                .multilineTextAlignment(.trailing)
        }
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
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .allowsHitTesting(false)
    }
}
