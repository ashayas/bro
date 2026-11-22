import XCTest

/// End to end over real Bonjour and TCP. Run through Scripts/e2e.sh, which starts the bots:
/// Turbo Brad (open, hosts CAMP2345), Neon Roxy (open), Gator Dale (code only, CAMP2345).
final class BroChatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reset", "-noNotificationPrompt"]
        app.launch()
    }

    private func shot(_ name: String) {
        Thread.sleep(forTimeInterval: 1.3)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tap(_ id: String, timeout: TimeInterval = 12, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(id)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "missing \(id)", file: file, line: line)
        allowPermissions()
        target.tap()
    }

    private func allowPermissions() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Continue"] where springboard.alerts.buttons[label].exists {
            springboard.alerts.buttons[label].tap()
        }
    }

    private func onboard(screenshots: Bool = false) {
        XCTAssertTrue(element("onboarding-start").waitForExistence(timeout: 15))
        if screenshots { shot("01-welcome") }
        tap("onboarding-start")
        if screenshots { shot("02-profile") }
        tap("onboarding-profile")
        if screenshots { shot("03-reach") }
        tap("onboarding-finish")
        XCTAssertTrue(element("open-strip").waitForExistence(timeout: 10))
    }

    func testWholeNightOut() {
        onboard(screenshots: true)
        allowPermissions()

        XCTAssertTrue(element("person-Turbo Brad").waitForExistence(timeout: 30), "no LAN discovery")
        XCTAssertTrue(element("person-Neon Roxy").waitForExistence(timeout: 20))
        XCTAssertFalse(element("person-Gator Dale").exists, "code-only bro visible without the code")
        shot("04-nearby")

        // The Strip
        tap("open-strip")
        tap("send-party")
        XCTAssertTrue(element("bubble-out-party").waitForExistence(timeout: 5))
        XCTAssertTrue(element("bubble-in-respect").waitForExistence(timeout: 15), "nobody bro'd back")
        shot("05-strip")
        tap("pad-expand")
        shot("06-all-moods")
        tap("pad-expand")
        tap("chat-back")

        // Direct
        tap("person-Turbo Brad")
        tap("send-angry")
        XCTAssertTrue(element("bubble-in-shocked").waitForExistence(timeout: 15), "no direct reply")
        shot("07-direct")
        tap("chat-back")

        // A crew, by code
        tap("tab-Crews")
        shot("08-crews")
        tap("join-field")
        app.textFields["join-field"].typeText("CAMP2345")
        tap("join-button")
        let online = app.staticTexts.matching(NSPredicate(format: "label == %@", "You + 2 online")).firstMatch
        XCTAssertTrue(online.waitForExistence(timeout: 30), "crew members missing")
        tap("send-happy")
        XCTAssertTrue(element("bubble-in-respect").waitForExistence(timeout: 15), "no crew reply")
        shot("09-crew")
        tap("chat-back")
        shot("10-crews-joined")

        tap("tab-Nearby")
        XCTAssertTrue(element("person-Gator Dale").waitForExistence(timeout: 20), "crewmate missing after joining")
        shot("11-nearby-crewmate")

        tap("tab-Me")
        shot("12-me")
    }

    func testHistoryAndIdentitySurviveRelaunch() {
        onboard()
        tap("open-strip")
        tap("send-chill")
        XCTAssertTrue(element("bubble-out-chill").waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        app.terminate()
        app.launchArguments = ["-noNotificationPrompt"]
        app.launch()
        tap("open-strip", timeout: 15)
        XCTAssertTrue(element("bubble-out-chill").waitForExistence(timeout: 8))
    }

    func testClosingTakesYouOffTheStrip() {
        onboard()
        let toggle = app.switches["open-switch"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        tap("open-strip")
        XCTAssertTrue(app.buttons["OPEN UP TO BRO HERE"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("send-party").exists)
        shot("13-closed")
    }
}
