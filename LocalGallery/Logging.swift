import os

/// Thin wrapper around `os.Logger` that mirrors every call into
/// `LogStore.shared` so the in-app LogsView can surface them. The signature
/// matches the `os.Logger` methods we actually call (`debug` / `info` /
/// `notice` / `warning` / `error`) so existing call sites compile unchanged.
///
/// `@autoclosure` defers string composition until we know we're going to
/// emit; today both sinks always emit so the cost is paid eagerly, but the
/// shape leaves room to add a level filter later without touching call sites.
struct TeeLogger: Sendable {
    let logger: Logger
    let category: String

    func debug(_ message: @autoclosure () -> String) {
        let s = message()
        logger.debug("\(s, privacy: .public)")
        LogStore.shared.append(level: .debug, category: category, message: s)
    }

    func info(_ message: @autoclosure () -> String) {
        let s = message()
        logger.info("\(s, privacy: .public)")
        LogStore.shared.append(level: .info, category: category, message: s)
    }

    /// Aliased to `info` in the in-app store; `os.Logger.notice` still goes
    /// through the underlying logger at its normal level.
    func notice(_ message: @autoclosure () -> String) {
        let s = message()
        logger.notice("\(s, privacy: .public)")
        LogStore.shared.append(level: .info, category: category, message: s)
    }

    func warning(_ message: @autoclosure () -> String) {
        let s = message()
        logger.warning("\(s, privacy: .public)")
        LogStore.shared.append(level: .warning, category: category, message: s)
    }

    func error(_ message: @autoclosure () -> String) {
        let s = message()
        logger.error("\(s, privacy: .public)")
        LogStore.shared.append(level: .error, category: category, message: s)
    }
}

enum Log {
    private static let subsystem = "localgallery"

    private static func tee(_ category: String) -> TeeLogger {
        TeeLogger(logger: Logger(subsystem: subsystem, category: category), category: category)
    }

    static let scan     = tee("scan")
    static let enrich   = tee("enrich")
    static let thumb    = tee("thumbnail")
    static let cache    = tee("cache")
    static let search   = tee("search")
    static let memory   = tee("memory")
    static let index    = tee("index")
    static let ui       = tee("ui")
    static let contacts = tee("contacts")
    static let bg       = tee("background")
    static let widget   = tee("widget")
}
