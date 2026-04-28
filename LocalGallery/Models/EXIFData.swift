import Foundation

struct EXIFData: Equatable, Sendable {
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var dateTimeOriginal: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
}
