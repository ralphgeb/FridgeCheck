import XCTest

/// Opens Today in the simulator and does what people do with it: pull the page down to bring out
/// the calendar, pull again, push it back, tap the date. If Halo crashes, the test fails and the
/// workflow prints the crash report. Screenshots go to $SCREENS_DIR when it's set.
final class CalendarPullTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-onboarded", "YES", "-haloScreenshots", "-haloTab", "0"]
        app.launch()
        sleep(4)
    }

    func testPullDownForTheCalendar() {
        shot("0-today")
        // a pull from the cards, as you'd pull to see the calendar
        drag(from: 0.45, to: 0.85)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Halo stopped after pulling down for the calendar")
        shot("1-calendar-pulled")
        // pull again with the calendar out (that one syncs)
        drag(from: 0.55, to: 0.9)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Halo stopped after pulling again")
        shot("2-pulled-again")
        // push it back up
        drag(from: 0.8, to: 0.2)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Halo stopped after pushing the calendar back")
        shot("3-closed")
        // the date in the header opens it too
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.08)).tap()
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Halo stopped after tapping the date")
        shot("4-calendar-tapped")
        // and a slow pull from the very top, the header itself
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.08)).tap()
        sleep(1)
        drag(from: 0.12, to: 0.7, slowly: true)
        sleep(2)
        XCTAssertEqual(app.state, .runningForeground, "Halo stopped after pulling the header down")
        shot("5-header-pulled")
    }

    private func drag(from: CGFloat, to: CGFloat, slowly: Bool = false) {
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: slowly ? .slow : .default, thenHoldForDuration: 0.1)
    }

    private func shot(_ name: String) {
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENS_DIR"], !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? image.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("iphone-pull-\(name).png"))
        }
    }
}
