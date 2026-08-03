#!/usr/bin/env swift
//
// Regenerates LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json —
// the conformance vectors shared by the Swift and Rust `StableUUID`
// implementations.
//
//     swift scripts/gen_stable_uuid_vectors.swift
//
// The expected UUIDs are produced by the Swift algorithm (below), which is a
// copy of `StableUUID.derive(from:)` in LocalGallery/Models/PhotoFile.swift —
// the app is the source of truth. The copy exists only because a standalone
// script can't `@testable import LocalGallery`; `StableUUIDVectorTests` asserts
// the real implementation against every generated vector, so a drift between
// this copy and the app fails the test suite rather than passing silently.
//
// Non-ASCII is emitted as \uXXXX escapes so the NFC/NFD pairs survive any
// editor, filesystem or diff tool that would otherwise normalize them.

import CryptoKit
import Foundation

// MARK: - The algorithm under test (mirror of PhotoFile.swift)

func derive(_ input: String) -> UUID {
    let digest = SHA256.hash(data: Data(input.utf8))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5
    bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant RFC 4122
    return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                       bytes[4],  bytes[5],  bytes[6],  bytes[7],
                       bytes[8],  bytes[9],  bytes[10], bytes[11],
                       bytes[12], bytes[13], bytes[14], bytes[15]))
}

// MARK: - Vectors

struct Vector {
    let label: String
    let input: String
}

let base = "/Users/j/Pictures"

// Unicode built from explicit scalars so nothing here depends on how this
// source file happens to be normalized on disk.
let cafeNFC  = "Caf\u{00E9}"                                   // é as one scalar
let cafeNFD  = "Cafe\u{0301}"                                  // e + combining acute
let zurichNFC = "Z\u{00FC}rich"                                // ü as one scalar
let zurichNFD = "Zu\u{0308}rich"                               // u + combining diaeresis
let hangulNFC = "\u{D55C}\u{AD6D}"                             // 한국, precomposed
let hangulNFD = "\u{1112}\u{1161}\u{11AB}\u{1100}\u{116E}\u{11A8}" // conjoining jamo

var vectors: [Vector] = [
    // Plain ASCII paths.
    .init(label: "ascii-basic", input: "\(base)/2024/IMG_0001.jpg"),
    .init(label: "ascii-sibling", input: "\(base)/2024/IMG_0002.jpg"),
    .init(label: "ascii-lowercase-name", input: "\(base)/2024/img_0001.jpg"),
    .init(label: "ascii-uppercase-extension", input: "\(base)/2024/IMG_0001.JPG"),
    .init(label: "ascii-sidecar", input: "\(base)/2024/IMG_0001.jpg.xmp"),

    // Degenerate inputs — nothing in the app should feed these in, but the
    // hash must still be defined and agree across languages.
    .init(label: "empty", input: ""),
    .init(label: "root", input: "/"),
    .init(label: "single-dot", input: "."),

    // URL-encoding hazards. These are `url.standardized.path` strings, i.e.
    // decoded percent-escapes and literal separators — record exactly what
    // Swift feeds in so a future percent-encoding bug is visible.
    .init(label: "spaces", input: "/Volumes/My Shared Files/dev public/IMG 0001.jpg"),
    .init(label: "hash", input: "\(base)/Party #3/IMG_0001.jpg"),
    .init(label: "percent", input: "\(base)/100%/IMG_0001.jpg"),
    .init(label: "plus", input: "\(base)/A+B/IMG_0001.jpg"),
    .init(label: "query-chars", input: "\(base)/q?x=1&y=2/IMG_0001.jpg"),
    .init(label: "literal-percent-escape", input: "\(base)/a%20b/IMG_0001.jpg"),
    .init(label: "ampersand", input: "\(base)/Ampersand & Co/IMG_0001.jpg"),
    .init(label: "quotes-and-backslash", input: "\(base)/say \"hi\"\\back/IMG_0001.jpg"),
    .init(label: "control-chars", input: "\(base)/tab\tand\nnewline/IMG_0001.jpg"),

    // Forms that `URL.standardized` collapses. Standardization happens in the
    // caller (`PhotoFile.stableID(for:)`), *before* hashing — so these strings
    // hash differently from their standardized equivalents, by design.
    .init(label: "folder-no-trailing-slash", input: "\(base)/2024"),
    .init(label: "folder-trailing-slash", input: "\(base)/2024/"),
    .init(label: "dot-dot-unstandardized", input: "\(base)/../Pictures/2024/IMG_0001.jpg"),
    .init(label: "dot-segment-unstandardized", input: "\(base)/./IMG_0001.jpg"),
    .init(label: "double-separators", input: "//Users//j//Pictures//IMG_0001.jpg"),

    // Unicode: NFC vs NFD of the same visible name are *distinct* vectors.
    // APFS hands back decomposed names; other platforms hand back whatever was
    // written. Phase 0 only pins today's behaviour (no normalization).
    .init(label: "nfc-cafe", input: "\(base)/\(cafeNFC)/IMG_0001.jpg"),
    .init(label: "nfd-cafe", input: "\(base)/\(cafeNFD)/IMG_0001.jpg"),
    .init(label: "nfc-zurich", input: "\(base)/\(zurichNFC) 2019/IMG_0001.jpg"),
    .init(label: "nfd-zurich", input: "\(base)/\(zurichNFD) 2019/IMG_0001.jpg"),
    .init(label: "nfc-hangul", input: "\(base)/\(hangulNFC)/IMG_0001.jpg"),
    .init(label: "nfd-hangul", input: "\(base)/\(hangulNFD)/IMG_0001.jpg"),

    // Emoji, including a ZWJ sequence and a regional-indicator pair.
    .init(label: "emoji-single", input: "\(base)/\u{1F305} Sunrise/IMG_0001.jpg"),
    .init(label: "emoji-zwj-family",
          input: "\(base)/family \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}/IMG_0001.jpg"),
    .init(label: "emoji-flag", input: "\(base)/flag \u{1F1EF}\u{1F1F5}/IMG_0001.jpg"),

    // CJK, including a non-BMP (surrogate-pair) ideograph.
    .init(label: "cjk-japanese",
          input: "\(base)/\u{5199}\u{771F}/2024\u{5E74}/\u{753B}\u{50CF}_0001.jpg"),
    .init(label: "cjk-chinese", input: "\(base)/\u{7167}\u{7247}/IMG_0001.jpg"),
    .init(label: "cjk-non-bmp", input: "\(base)/\u{20BB7}\u{91CE}\u{5BB6}/IMG_0001.jpg"),
]

// Very long paths: deep nesting and a filename at the usual 255-byte limit.
let deep = (1...40).map { "level\($0)" }.joined(separator: "/")
vectors.append(.init(label: "deep-nesting", input: "\(base)/\(deep)/IMG_0001.jpg"))
vectors.append(.init(label: "long-filename",
                     input: "\(base)/\(String(repeating: "x", count: 251)).jpg"))

// MARK: - Emit

/// JSON string literal with every non-ASCII scalar escaped as \uXXXX
/// (surrogate pairs for non-BMP), so the file is pure ASCII on disk.
func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 || scalar.value > 0x7E {
                for unit in String(scalar).utf16 {
                    out += String(format: "\\u%04x", unit)
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

let body = vectors.map { v in
    """
      {
        "label": \(jsonString(v.label)),
        "input": \(jsonString(v.input)),
        "uuid": "\(derive(v.input).uuidString.lowercased())"
      }
    """
}.joined(separator: ",\n")

let json = "[\n" + body + "\n]\n"

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1]
               : FileManager.default.currentDirectoryPath)
let out = root
    .appendingPathComponent("LocalGalleryTests/Support/Fixtures/stable_uuid_vectors.json")
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try json.write(to: out, atomically: true, encoding: .utf8)
print("wrote \(vectors.count) vectors to \(out.path)")
