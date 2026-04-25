import Foundation

/// URL construction + parsing for widget → app deep links.
///
/// Schemes:
///   localgallery://memory/<id>
///   localgallery://folder/<id>
///   localgallery://tags?paths=<comma-separated, percent-encoded>
enum WidgetDeepLink: Equatable {
    case memory(id: String)
    case folder(id: String)
    case tags(paths: [String])

    static let scheme = "localgallery"

    var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .memory(let id):
            c.host = "memory"
            c.path = "/" + id
        case .folder(let id):
            c.host = "folder"
            c.path = "/" + id
        case .tags(let paths):
            c.host = "tags"
            c.queryItems = [URLQueryItem(name: "paths", value: paths.joined(separator: ","))]
        }
        return c.url!
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
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let raw = comps?.queryItems?.first(where: { $0.name == "paths" })?.value ?? ""
            let paths = raw.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
            return paths.isEmpty ? nil : .tags(paths: paths)
        default:
            return nil
        }
    }
}
