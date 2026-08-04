import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LocalGallery

/// The core decides what is a photo from a hand-maintained extension table.
/// `FolderScanner` asked `UTType`. There is no `UTType` off Apple's platforms,
/// so the table exists — and this is the only thing that keeps it honest.
///
/// # Why drift here is worse than it sounds
///
/// The two directions fail differently and both fail quietly:
///
/// * an extension **missing** from the table that `UTType` accepts is a
///   *deletion*. Those files were in the library before the port, so the first
///   scan after the upgrade does not merely skip them — it reports them
///   **removed**, and their tags, GPS and enrichment go with them.
/// * an extension **present** that `UTType` rejects surfaces files the app has
///   never shown, which is a behaviour change in the other direction and a
///   different set of surprised users.
///
/// Neither produces an error anywhere. A failing test is the only signal.
///
/// # And the reference platform is iOS
///
/// macOS and iOS do not declare the same set. macOS calls `hdr`, `pbm`, `pgm`,
/// `ppm`, `dds`, `astc`, `ktx`, `mts` and `m2ts` images or movies; iOS returns
/// undeclared `dyn.*` types for all nine. A table checked against a Mac would
/// therefore surface nine file types the app has never shown. This suite runs
/// on the simulator, which is the only place the question has the right answer.
final class ExtensionTableDriftTests: XCTestCase {

    /// Everything the core claims is an image or a video.
    private func coreTable() -> (images: Set<String>, videos: Set<String>) {
        (Set(scannerImageExtensions()), Set(scannerVideoExtensions()))
    }

    private func kind(of ext: String) -> String {
        guard let type = UTType(filenameExtension: ext) else { return "none" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) { return "video" }
        return "other"
    }

    /// Every entry in the table must be something `UTType` agrees with.
    ///
    /// This is the direction that catches an over-eager addition — and it
    /// caught three that were already there: `jfif`, `kdc` and `x3f` all resolve
    /// to an undeclared `dyn.*` type that conforms to nothing, so the pre-port
    /// scanner walked straight past them.
    func testEveryExtensionTheCoreClassifiesIsOneUTTypeClassifiesTheSameWay() {
        let (images, videos) = coreTable()
        XCTAssertFalse(images.isEmpty)
        XCTAssertFalse(videos.isEmpty)

        var wrong: [String] = []
        for ext in images.sorted() where kind(of: ext) != "image" {
            wrong.append("\(ext): core says image, UTType says \(kind(of: ext))")
        }
        for ext in videos.sorted() where kind(of: ext) != "video" {
            wrong.append("\(ext): core says video, UTType says \(kind(of: ext))")
        }
        XCTAssertEqual(wrong, [], "the core surfaces files the app never showed:\n\(wrong.joined(separator: "\n"))")
    }

    /// The other direction, over the formats a photo library realistically
    /// contains.
    ///
    /// It cannot be exhaustive — `UTType` has no enumeration API and the OS
    /// declares hundreds — so this is the curated list of everything a camera,
    /// a phone, a RAW converter or a screen recorder writes. A new OS that
    /// starts declaring a format nobody here anticipated is still invisible;
    /// one that starts declaring a format on this list is not.
    func testEveryCommonMediaExtensionUTTypeAcceptsIsInTheTable() {
        let candidates = [
            // Everyday photos.
            "jpg", "jpeg", "jpe", "png", "gif", "bmp", "tiff", "tif", "webp",
            "heic", "heif", "heics", "heifs", "avif", "avci", "avcs",
            "jp2", "j2k", "jxl", "mpo", "psd", "ico", "icns", "exr", "hdr", "svg",
            "tga", "pict", "pbm", "pgm", "ppm", "sgi", "xbm", "dds", "astc", "ktx",
            // RAW, one per vendor the app is likely to meet.
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf",
            "rw2", "raw", "raf", "srw", "pef", "erf", "3fr", "fff", "mos", "iiq",
            "rwl", "dcr", "mrw",
            // Video.
            "mov", "mp4", "mpg4", "m4v", "qt", "avi", "mpg", "mpeg", "mpe", "m2v",
            "3gp", "3gpp", "3g2", "3gp2", "mts", "m2ts", "ts", "dv", "vfw",
            "webm", "wmv", "flv", "f4v", "mxf", "rm",
        ]

        let (images, videos) = coreTable()
        var missing: [String] = []
        for ext in candidates {
            switch kind(of: ext) {
            case "image" where !images.contains(ext):
                missing.append("\(ext): UTType says image, the core skips it")
            case "video" where !videos.contains(ext):
                missing.append("\(ext): UTType says video, the core skips it")
            default:
                continue
            }
        }
        XCTAssertEqual(missing, [], """
            these were scanned before the port and are now reported REMOVED, \
            taking their tags with them:
            \(missing.joined(separator: "\n"))
            """)
    }

    /// Sidecars and ordinary junk stay out of both tables — `.xmp` is an input
    /// to the manifest, never a photo row.
    func testSidecarsAndNonMediaAreInNeitherTable() {
        let (images, videos) = coreTable()
        for ext in ["xmp", "txt", "pdf", "zip", "json", "aae"] {
            XCTAssertFalse(images.contains(ext), ext)
            XCTAssertFalse(videos.contains(ext), ext)
        }
        XCTAssertTrue(images.isDisjoint(with: videos), "an extension cannot be both")
        XCTAssertTrue(images.allSatisfy { $0 == $0.lowercased() },
                      "the core lowercases before it looks up")
    }
}
