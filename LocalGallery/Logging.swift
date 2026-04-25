import os

enum Log {
    private static let subsystem = "localgallery"

    static let scan    = Logger(subsystem: subsystem, category: "scan")
    static let enrich  = Logger(subsystem: subsystem, category: "enrich")
    static let thumb   = Logger(subsystem: subsystem, category: "thumbnail")
    static let cache   = Logger(subsystem: subsystem, category: "cache")
    static let search  = Logger(subsystem: subsystem, category: "search")
    static let memory  = Logger(subsystem: subsystem, category: "memory")
    static let index   = Logger(subsystem: subsystem, category: "index")
    static let ui      = Logger(subsystem: subsystem, category: "ui")
    static let contacts = Logger(subsystem: subsystem, category: "contacts")
    static let bg      = Logger(subsystem: subsystem, category: "background")
    static let widget  = Logger(subsystem: subsystem, category: "widget")
}
