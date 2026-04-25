import Foundation

/// Paths inside the App Group container that both the app and the widget
/// extension access. Anything under `widgetDataDir` is published by the main
/// app and read by widgets.
enum SharedContainer {
    static let appGroupID = "group.com.localgallery.shared"

    static var rootURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var widgetDataDir: URL? {
        guard let root = rootURL else { return nil }
        let dir = root.appendingPathComponent("WidgetData", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var thumbsDir: URL? {
        guard let dir = widgetDataDir else { return nil }
        let t = dir.appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        return t
    }

    static var indexURL: URL? { widgetDataDir?.appendingPathComponent("index.json") }
    static var foldersURL: URL? { widgetDataDir?.appendingPathComponent("folders.json") }
    static var tagsURL: URL? { widgetDataDir?.appendingPathComponent("tags.json") }
    static var memoriesURL: URL? { widgetDataDir?.appendingPathComponent("memories.json") }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
}
