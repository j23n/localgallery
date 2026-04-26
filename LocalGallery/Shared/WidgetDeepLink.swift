import Foundation

/// URL construction + parsing for widget → app deep links.
///
/// Schemes:
///   localgallery://memory/<id>
///   localgallery://folder/<id>
///   localgallery://tags?paths=<urlencoded>&paths=<urlencoded>...
///
/// Tag paths use repeated query items rather than a comma-joined value so a
/// literal comma in any path round-trips intact.
enum WidgetDeepLink: Equatable {
    case memory(id: String)
    case folder(id: String)
    case tags(paths: [String])

    static let scheme = "localgallery"

    /// Returns the constructed URL, or `nil` when the inputs would produce an
    /// invalid URL. Callers should treat `nil` as "skip the deep link" rather
    /// than crashing — currently only happens for empty/whitespace ids.
    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .memory(let id):
            guard !id.isEmpty else { return nil }
            c.host = "memory"
            c.path = "/" + id
        case .folder(let id):
            guard !id.isEmpty else { return nil }
            c.host = "folder"
            c.path = "/" + id
        case .tags(let paths):
            guard !paths.isEmpty else { return nil }
            c.host = "tags"
            c.queryItems = paths.map { URLQueryItem(name: "paths", value: $0) }
        }
        return c.url
    }

    static func parse(_ url: URL) -> WidgetDeepLink? {
        guard url.scheme == scheme,
              let host = url.host else { return nil }
        switch host {
        case "memory":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : .memory(id: id)
        case "folder":
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : .folder(id: id)
        case "tags":
            // Accept both repeated `paths=` items and the legacy comma-joined
            // form so widgets installed on an older snapshot continue to work
            // until the user replaces them.
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let items = comps?.queryItems?.filter { $0.name == "paths" } ?? []
            var paths: [String] = []
            for item in items {
                guard let v = item.value, !v.isEmpty else { continue }
                if v.contains(",") {
                    paths.append(contentsOf: v.split(separator: ",").map(String.init))
                } else {
                    paths.append(v)
                }
            }
            return paths.isEmpty ? nil : .tags(paths: paths)
        default:
            return nil
        }
    }
}
