import Foundation

/// One read of a photo's sidecar. Every surface that needs tags, boxes,
/// or photo-tools stamps goes through here.
///
/// Disk reads use `readSidecar`; already-held bytes use `parseXmpBytes`.
/// Both are the same cheap substring walk the scanner uses.
struct SidecarDocument: Equatable, Sendable {
    /// Path that was read, when `exists`.
    var url: URL?
    var exists: Bool
    var rawTags: [String]
    var countryCode: String?
    var faceRegions: [FaceRegion]
    var tools: PhotoToolsMetadata
    /// Raw `CoreFaceDecisions` entries (`"x,y,w,h named Ada"`).
    var decisions: [String]

    static let empty = SidecarDocument(
        url: nil,
        exists: false,
        rawTags: [],
        countryCode: nil,
        faceRegions: [],
        tools: PhotoToolsMetadata(),
        decisions: []
    )

    static func read(imagePath path: String) -> SidecarDocument {
        from(readSidecar(imagePath: path))
    }

    static func read(imageURL: URL) -> SidecarDocument {
        read(imagePath: imageURL.path)
    }

    static func parse(data: Data, url: URL?) -> SidecarDocument {
        from(parseXmpBytes(bytes: data), url: url, exists: url != nil)
    }

    /// People names claimed in decisions but not boxed on the public MWG list.
    var namedWithoutBox: [String] {
        namedPeopleWithoutBox(regionNames: faceRegions.map(\.name), decisions: decisions)
    }

    private static func from(_ view: SidecarViewRecord) -> SidecarDocument {
        SidecarDocument(
            url: view.sidecarPath.map { URL(fileURLWithPath: $0) },
            exists: view.exists,
            rawTags: view.rawTags,
            countryCode: view.countryCode,
            faceRegions: view.faceRegions.map(Self.region),
            tools: tools(from: view),
            decisions: view.faceDecisions
        )
    }

    private static func from(_ parsed: SidecarParseRecord, url: URL?, exists: Bool) -> SidecarDocument {
        SidecarDocument(
            url: url,
            exists: exists,
            rawTags: parsed.rawTags,
            countryCode: parsed.countryCode,
            faceRegions: parsed.faceRegions.map(Self.region),
            tools: PhotoToolsMetadata(
                taggerVersion: parsed.taggerVersion,
                taggedAt: parsed.taggedAt,
                clipModel: parsed.clipModel,
                clipTimestamp: parsed.clipTimestamp,
                facePack: parsed.facePack,
                faceTaggedAt: parsed.faceTaggedAt
            ),
            decisions: parsed.faceDecisions
        )
    }

    private static func tools(from view: SidecarViewRecord) -> PhotoToolsMetadata {
        PhotoToolsMetadata(
            taggerVersion: view.taggerVersion,
            taggedAt: view.taggedAt,
            clipModel: view.clipModel,
            clipTimestamp: view.clipTimestamp,
            facePack: view.facePack,
            faceTaggedAt: view.faceTaggedAt
        )
    }

    private static func region(_ r: ScanRegion) -> FaceRegion {
        FaceRegion(
            name: r.name,
            centerX: r.centerX,
            centerY: r.centerY,
            width: r.width,
            height: r.height
        )
    }
}

extension PhotoFile {
    /// Union a sidecar document onto this library row.
    mutating func apply(_ doc: SidecarDocument) {
        sidecarOnDisk = doc.exists
        photoTools = doc.tools.merging(over: photoTools)
        faceDecisions = doc.decisions
        if let code = doc.countryCode { countryCode = code }
        var seen = Set(hierarchicalTags.map { $0.fullPath.lowercased() })
        for raw in doc.rawTags {
            if seen.insert(raw.lowercased()).inserted {
                hierarchicalTags.append(HierarchicalTag(raw: raw))
            }
        }
        for name in doc.namedWithoutBox {
            let path = HierarchicalTag.personPath(for: name)
            if seen.insert(path.lowercased()).inserted {
                hierarchicalTags.append(HierarchicalTag(raw: path))
            }
        }
        if !doc.faceRegions.isEmpty {
            faceRegions = doc.faceRegions
        }
    }
}
