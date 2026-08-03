import XCTest

/// Temporary headless profiling driver. Each test method is one scenario,
/// invoked individually via `xcodebuild test-without-building -only-testing:`.
/// Host <-> test sync happens through marker files in `signalDir` (the
/// simulator shares the host filesystem).
final class DriverUITests: XCTestCase {

    let signalDir = "/private/tmp/claude-501/-Volumes-My-Shared-Files-dev-public-localgallery/d2f5eb75-dd8c-458d-8269-4b2691a32bc1/scratchpad/signals"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try? FileManager.default.createDirectory(atPath: signalDir, withIntermediateDirectories: true)
    }

    func signal(_ name: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        try? ts.write(toFile: signalDir + "/" + name, atomically: true, encoding: .utf8)
        NSLog("DRIVER-SIGNAL %@ %@", name, ts)
    }

    @discardableResult
    func waitForHostFile(_ name: String, timeout: TimeInterval) -> Bool {
        let path = signalDir + "/" + name
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }

    func dumpTree(_ app: XCUIApplication, _ label: String) {
        NSLog("DRIVER-TREE %@ >>>\n%@\n<<< DRIVER-TREE %@", label, app.debugDescription, label)
    }

    // MARK: - Scenario 1: onboarding + cold full scan

    func testOnboardAndScan() throws {
        let app = XCUIApplication()
        app.launch()
        signal("launched")
        sleep(3)

        // Open Settings via the gear toolbar button.
        let gear = app.buttons["gear"].exists ? app.buttons["gear"]
                 : app.buttons["Gear"].exists ? app.buttons["Gear"]
                 : app.buttons["Settings"]
        if !gear.waitForExistence(timeout: 10) {
            dumpTree(app, "no-gear")
            XCTFail("gear button not found")
        }
        gear.tap()
        sleep(2)

        // Tap the "Folder" row.
        let folderRow = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] 'Folder'")).firstMatch
        if !folderRow.waitForExistence(timeout: 10) {
            dumpTree(app, "no-folder-row")
            XCTFail("Folder row not found")
        }
        folderRow.tap()
        sleep(5)
        dumpTree(app, "picker")

        // Document picker: find TestLibrary, possibly via Browse > On My iPhone.
        var testLib = app.staticTexts["TestLibrary"].firstMatch
        if !testLib.waitForExistence(timeout: 5) {
            let onMyPhone = app.staticTexts["On My iPhone"].firstMatch
            if onMyPhone.waitForExistence(timeout: 3) { onMyPhone.tap(); sleep(2) }
            testLib = app.staticTexts["TestLibrary"].firstMatch
        }
        if !testLib.waitForExistence(timeout: 10) {
            dumpTree(app, "no-testlibrary")
            XCTFail("TestLibrary not found in picker")
        }
        testLib.tap()
        sleep(2)

        let openBtn = app.buttons["Open"].firstMatch
        if !openBtn.waitForExistence(timeout: 5) {
            dumpTree(app, "no-open")
            XCTFail("Open button not found")
        }
        openBtn.tap()
        sleep(2)

        // Dismiss the Settings sheet so the main UI shows the scan.
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 5) { done.tap() }
        signal("picked")

        // Keep the app foreground until the host says the scan finished.
        let ok = waitForHostFile("scan_done", timeout: 1800)
        NSLog("DRIVER onboard finished, scan_done=%d", ok ? 1 : 0)
        signal("onboard_exit")
    }

    // MARK: - Remote control: host-driven coordinate input
    //
    // Reads numbered command files `cmd_<seq>.txt` from signalDir and acks
    // via `ack_<seq>.txt`. Commands (whitespace-separated):
    //   tap X Y            (points, app window coords)
    //   swipe X1 Y1 X2 Y2 DUR
    //   type TEXT...
    //   launch | activate | terminate
    //   sleep SECONDS
    //   tree LABEL
    //   exit
    func testRemoteControl() throws {
        let app = XCUIApplication()
        app.activate()
        var seq = 0
        let deadline = Date().addingTimeInterval(3000)
        while Date() < deadline {
            let cmdPath = signalDir + "/cmd_\(seq).txt"
            guard let raw = try? String(contentsOfFile: cmdPath, encoding: .utf8) else {
                Thread.sleep(forTimeInterval: 0.3)
                continue
            }
            let parts = raw.split(separator: " ").map(String.init)
            var result = "ok"
            switch parts.first ?? "" {
            case "tap":
                let x = Double(parts[1])!, y = Double(parts[2])!
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: x, dy: y)).tap()
            case "swipe":
                let x1 = Double(parts[1])!, y1 = Double(parts[2])!
                let x2 = Double(parts[3])!, y2 = Double(parts[4])!
                let dur = parts.count > 5 ? Double(parts[5])! : 0.1
                let a = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x1, dy: y1))
                let b = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x2, dy: y2))
                a.press(forDuration: dur, thenDragTo: b)
            case "type":
                let text = parts.dropFirst().joined(separator: " ")
                app.typeText(text)
            case "launch": app.launch()
            case "activate": app.activate()
            case "terminate": app.terminate()
            case "sleep": Thread.sleep(forTimeInterval: Double(parts[1]) ?? 1)
            case "tree": dumpTree(app, parts.count > 1 ? parts[1] : "rc")
            case "exit":
                try? "done".write(toFile: signalDir + "/ack_\(seq).txt", atomically: true, encoding: .utf8)
                return
            default: result = "unknown"
            }
            try? result.write(toFile: signalDir + "/ack_\(seq).txt", atomically: true, encoding: .utf8)
            seq += 1
        }
    }

    // MARK: - Scenario 2: fast scroll through All Photos

    func testFastScrollAllPhotos() throws {
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.tabBars.buttons["Photos"].tap()
        sleep(3)
        signal("scroll_start")

        // 40 fast flicks down the 20k grid.
        let window = app.windows.firstMatch
        for i in 0..<40 {
            window.swipeUp(velocity: XCUIGestureVelocity(rawValue: 5000))
            if i % 10 == 9 { NSLog("DRIVER scroll flick %d", i + 1) }
        }
        signal("scroll_mid")
        sleep(2)
        // Reverse direction.
        for _ in 0..<15 {
            window.swipeDown(velocity: XCUIGestureVelocity(rawValue: 5000))
        }
        // Scroll-to-top via status-bar tap.
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        top.tap()
        sleep(3)
        signal("scroll_done")
        waitForHostFile("scenario_ack", timeout: 60)
    }

    // MARK: - Scenario 3: large folders

    func testOpenLargeFolder() throws {
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.tabBars.buttons["Folders"].tap()
        sleep(2)
        signal("folders_start")

        func openFolder(_ names: [String]) {
            for name in names {
                let cell = app.staticTexts[name].firstMatch
                if !cell.waitForExistence(timeout: 8) {
                    dumpTree(app, "no-folder-\(name)")
                    XCTFail("folder \(name) not found")
                }
                cell.tap()
                sleep(2)
            }
        }

        // Largest leaf: a full year of Everyday photos.
        openFolder(["2023", "Everyday"])
        sleep(2)
        let window = app.windows.firstMatch
        for _ in 0..<12 { window.swipeUp(velocity: XCUIGestureVelocity(rawValue: 5000)) }
        for _ in 0..<6 { window.swipeDown(velocity: XCUIGestureVelocity(rawValue: 5000)) }
        signal("folder_scrolled")

        // Back out twice, then into another year.
        let back = app.navigationBars.buttons.firstMatch
        back.tap(); sleep(1)
        app.navigationBars.buttons.firstMatch.tap(); sleep(1)
        openFolder(["2024", "Everyday"])
        sleep(2)
        for _ in 0..<8 { window.swipeUp(velocity: XCUIGestureVelocity(rawValue: 5000)) }
        signal("folders_done")
        waitForHostFile("scenario_ack", timeout: 60)
    }

    // MARK: - Scenario 4: viewer paging

    func testViewerPaging() throws {
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.tabBars.buttons["Photos"].tap()
        sleep(2)
        // Ensure we're at the top, then tap the first thumbnail.
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        top.tap()
        sleep(2)
        signal("viewer_start")
        let firstCell = app.images.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
        } else {
            // Tap where the first grid cell should be.
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.35)).tap()
        }
        sleep(3)
        dumpTree(app, "viewer")

        for i in 0..<30 {
            window.swipeLeft(velocity: XCUIGestureVelocity(rawValue: 4000))
            if i % 10 == 9 { NSLog("DRIVER viewer page %d", i + 1) }
        }
        sleep(2)
        for _ in 0..<10 {
            window.swipeRight(velocity: XCUIGestureVelocity(rawValue: 4000))
        }
        signal("viewer_paged")
        // Dismiss.
        window.swipeDown(velocity: XCUIGestureVelocity(rawValue: 3000))
        sleep(2)
        signal("viewer_done")
        waitForHostFile("scenario_ack", timeout: 60)
    }

    // MARK: - Scenario 5: search

    func testSearch() throws {
        let app = XCUIApplication()
        app.activate()
        sleep(2)
        app.tabBars.buttons["Photos"].tap()
        sleep(2)
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01)).tap()
        sleep(2)
        signal("search_start")

        let field = app.textFields["Search by name or tag"].firstMatch
        if !field.waitForExistence(timeout: 8) {
            dumpTree(app, "no-search-field")
            XCTFail("search field not found")
        }
        field.tap()
        sleep(1)
        field.typeText("anna")
        sleep(3)
        signal("search_typed_anna")
        // Clear.
        let clear = app.buttons["xmark.circle.fill"].firstMatch
        if clear.exists { clear.tap() } else {
            field.doubleTap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        sleep(1)
        field.tap()
        field.typeText("rome")
        sleep(3)
        signal("search_typed_rome")
        field.typeText("\n")
        sleep(2)
        signal("search_done")
        waitForHostFile("scenario_ack", timeout: 60)
    }

    // MARK: - Scenario 6: warm relaunch (cache restore)

    func testWarmRelaunch() throws {
        let app = XCUIApplication()
        app.terminate()
        sleep(2)
        signal("relaunch_begin")
        app.launch()
        signal("relaunched")
        // Hold foreground while the host measures restore + rescan from logs.
        waitForHostFile("relaunch_done", timeout: 900)
        signal("relaunch_exit")
    }
}
