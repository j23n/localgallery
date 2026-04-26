import Foundation

/// Paths inside the App Group container that both the app and the widget
/// extension access. Anything under `widgetDataDir` is published by the main
/// app and read by widgets.
///
/// URLs are computed once and cached. Directory creation runs in
/// `prepareDirectories()` rather than on every property read — call it from
/// the export site before writing.
enum SharedContainer {
    static let appGroupID = "group.com.localgallery.shared"

    static let rootURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupID
    )

    static let widgetDataDir: URL? = rootURL?.appendingPathComponent("WidgetData", isDirectory: true)
    static let thumbsDir: URL? = widgetDataDir?.appendingPathComponent("thumbs", isDirectory: true)

    static let indexURL: URL? = widgetDataDir?.appendingPathComponent("index.json")
    static let foldersURL: URL? = widgetDataDir?.appendingPathComponent("folders.json")
    static let tagsURL: URL? = widgetDataDir?.appendingPathComponent("tags.json")
    static let memoriesURL: URL? = widgetDataDir?.appendingPathComponent("memories.json")

    static let defaults: UserDefaults? = UserDefaults(suiteName: appGroupID)

    /// Idempotent — call before writing files. Widgets only read, so they
    /// don't need to invoke this.
    static func prepareDirectories() {
        let fm = FileManager.default
        if let dir = widgetDataDir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let dir = thumbsDir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
