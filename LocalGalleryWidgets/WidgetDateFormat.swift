import Foundation

/// Single shared `DateFormatter` used by every widget for subtitle dates.
/// `DateFormatter` is expensive to allocate, so we keep one alive for the
/// lifetime of the extension process.
enum WidgetDateFormat {
    static let shared: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
