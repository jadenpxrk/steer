import XCTest

/// Drives the real app against the throwaway servers from `scripts/e2e.sh` and checks the outcome on the host itself.
/// Skipped unless that script is running.
final class E2ETests: XCTestCase {
    private var app: XCUIApplication!
    private var host: E2EHost!

    override func setUpWithError() throws {
        guard let host = E2EHost() else { throw XCTSkip("Run scripts/e2e.sh") }
        self.host = host
        continueAfterFailure = false
        app = XCUIApplication()
        launch(preferences: [:])
        host.goHome(in: app)
        host.removeStaleHosts(from: app)
    }

    /// Overrides the saved preferences for this launch only: a blinking cursor never lets the app go idle,
    /// and a reopened terminal would cover the host list.
    private func launch(preferences extra: [String: Any]) {
        var preferences: [String: Any] = ["cursorBlinks": false, "reopenLastTerminal": false]
        preferences.merge(extra) { $1 }
        let data = (try? JSONSerialization.data(withJSONObject: preferences)) ?? Data()
        app.terminate()
        app.launchArguments = ["-terminal-preferences", "<" + data.map { String(format: "%02x", $0) }.joined() + ">"]
        app.launch()
    }

    override func tearDownWithError() throws {
        guard let app, let host else { return }
        host.removeFromApp(app)
    }

    func testETSessionLeavesNothingBehind() throws {
        host.add(to: app, transport: "ET")
        host.openTmuxSession("e2e-a", in: app)
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }
        try host.waitForState { $0.tmuxClients == ["e2e-a": 1] && $0.etterminals == 1 }

        host.closeTerminal(in: app)
        try host.waitForState { $0.tmuxClients.isEmpty && $0.etterminals == 0 }
    }

    /// A steer:// link from another app or a terminal must ask before it signs in and attaches.
    func testDeepLinkAsksBeforeConnecting() throws {
        host.add(to: app, transport: "SSH")
        let link = try XCTUnwrap(URL(string: "steer://open?host=\(host.name)&tmux=e2e-a"))
        app.open(link)
        let springboardOpen = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if springboardOpen.waitForExistence(timeout: 3) { springboardOpen.tap() }

        let connect = app.buttons["Connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10), "The link opened without asking")
        try host.waitForState(timeout: 3) { $0.tmuxClients.isEmpty }
        connect.tap()
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }
        try host.waitForState { $0.tmuxClients == ["e2e-a": 1] }

        host.closeTerminal(in: app)
        try host.waitForState { $0.tmuxClients.isEmpty }
    }

    /// A shortcut in the `<…>` syntax sends its keys.
    func testAngleBracketShortcutSends() throws {
        launch(preferences: ["customShortcuts": [[
            "id": UUID().uuidString, "label": "angle", "text": "echo angle-$((6*7))<Enter>",
            "appendReturn": false, "keySequence": true,
        ]]])
        host.goHome(in: app)
        host.add(to: app, transport: "SSH")
        host.openTmuxSession("e2e-a", in: app)
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }

        app.buttons["Terminal Actions"].tapWhenReady()
        app.buttons["Shortcuts"].tapWhenReady()
        app.buttons["angle"].tapWhenReady()
        try host.waitForScreen(in: app) { $0.contains("angle-42\n") }

        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        host.closeTerminal(in: app)
        try host.waitForState { $0.tmuxClients.isEmpty }
    }

    /// If a new Mosh server never answers (UDP blocked) while a tab switches sessions, the tab keeps its working one.
    func testUnansweredMoshSwitchKeepsTheTabUsable() throws {
        try host.requireControl()
        launch(preferences: ["customShortcuts": [["id": UUID().uuidString, "label": "alive", "text": "echo alive-$((6*7))", "appendReturn": true]]])
        host.goHome(in: app)
        host.add(to: app, transport: "Mosh", moshPath: ProcessInfo.processInfo.environment["STEER_E2E_MOSH_WRAPPER"])
        // A tab with a working Mosh shell, then a switch to a session whose server will be unreachable.
        host.row(in: app).press(forDuration: 1)
        app.buttons["New Session"].tapWhenReady()
        try host.waitForScreen(in: app) { $0.contains("%") || $0.contains("$") }
        try host.waitForState { $0.moshServers == 1 }
        _ = try host.fetch("block-new-mosh")
        host.goHome(in: app)
        host.openTmuxSession("e2e-a", in: app)
        // The new server gets 5 s to answer before the switch is abandoned.
        Thread.sleep(forTimeInterval: 15)
        XCTAssertFalse(app.staticTexts["No contact"].exists, "The tab lost its working session")
        XCTAssertTrue(app.buttons["Retry"].exists, "The failed switch was not reported")

        app.buttons["Terminal Actions"].tapWhenReady()
        app.buttons["Shortcuts"].tapWhenReady()
        app.buttons["alive"].tapWhenReady()
        try host.waitForScreen(in: app) { $0.contains("alive-42\n") }
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        host.closeTerminal(in: app)
    }

    /// When mosh-server goes away (host rebooted, server killed), the tab must say so rather than look connected.
    func testDeadMoshServerIsReported() throws {
        try host.requireControl()
        host.add(to: app, transport: "Mosh")
        host.openTmuxSession("e2e-a", in: app)
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }
        _ = try host.fetch("kill-mosh")
        XCTAssertTrue(app.staticTexts["No contact"].waitForExistence(timeout: 25), "A dead Mosh session still looks connected")
        host.closeTerminal(in: app)
    }

    /// The sidebar lists the attached tmux session's windows.
    func testSidebarListsTmuxWindows() throws {
        host.add(to: app, transport: "SSH")
        host.openTmuxSession("e2e-a", in: app)
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }
        app.buttons["Terminal Actions"].tapWhenReady()
        app.buttons["Sidebar"].tapWhenReady()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'zsh' OR label CONTAINS 'bash'")).firstMatch
            .waitForExistence(timeout: 15), "The sidebar shows no windows")
        app.buttons["Close Sidebar"].tapWhenReady()
        host.closeTerminal(in: app)
    }

    func testMoshSessionLeavesNothingBehind() throws {
        host.add(to: app, transport: "Mosh")
        host.openTmuxSession("e2e-a", in: app)
        try host.waitForScreen(in: app) { $0.contains("[e2e-a]") }
        try host.waitForState { $0.tmuxClients == ["e2e-a": 1] && $0.moshServers == 1 }

        host.closeTerminal(in: app)
        try host.waitForState { $0.tmuxClients.isEmpty && $0.moshServers == 0 }
    }
}

/// What the harness reports is running on the host.
struct HostState: Decodable, Equatable {
    var moshServers: Int
    var etterminals: Int
    var tmuxClients: [String: Int]
}

struct E2EHost {
    let address: String
    let port: String
    let user: String
    let control: URL
    let name = "e2e-\(UUID().uuidString.prefix(6))"

    init?() {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["STEER_E2E_ADDRESS"], let port = environment["STEER_LIVE_SSH_PORT"],
              let user = environment["STEER_LIVE_SSH_USER"], let control = environment["STEER_E2E_CONTROL"].flatMap(URL.init) else {
            return nil
        }
        (self.address, self.port, self.user, self.control) = (address, port, user, control)
    }

    /// The app may reopen the last terminal or ask to verify a host; back out to the host list.
    func goHome(in app: XCUIApplication) {
        let cancel = app.buttons["Cancel"]
        let back = app.navigationBars.buttons["Steer"]
        for _ in 0..<4 {
            if cancel.exists { cancel.tap() } else if back.exists { back.tap() } else { break }
        }
    }

    /// Hosts left by an interrupted run would be probed on launch and interrupt this one.
    func removeStaleHosts(from app: XCUIApplication) {
        let stale = app.buttons.matching(NSPredicate(format: "identifier == 'connections-card' AND label CONTAINS ', e2e-'")).firstMatch
        search("e2e-", in: app)
        for _ in 0..<10 where stale.exists {
            goHome(in: app)
            stale.press(forDuration: 1)
            app.buttons["Delete"].tapWhenReady(timeout: 3)
        }
    }

    func add(to app: XCUIApplication, transport: String, moshPath: String? = nil) {
        app.buttons["add-connection"].tapWhenReady()
        type(name, into: app.textFields["Name"])
        type(address, into: app.textFields["Hostname"])
        type(user, into: app.textFields["User"])
        let portField = app.textFields["Port"]
        portField.tapWhenReady()
        portField.clearText()
        portField.typeText(port)
        app.buttons[transport].tapWhenReady()
        if let moshPath { type(moshPath, into: app.textFields["mosh-server path"]) }
        let key = app.textViews["private-key"]
        for _ in 0..<6 where !key.isHittable { app.collectionViews.firstMatch.swipeUp() }
        key.tapWhenReady()
        key.typeText(RSAFixture.privateKey)
        app.buttons["Save"].tapWhenReady()
        // The home screen probes new hosts right away, which asks to verify the server's key.
        trustServer(in: app)
    }

    func trustServer(in app: XCUIApplication) {
        let trust = app.buttons["Trust and Connect"]
        // On a phone, the first connection to a LAN address asks for Local Network access and fails meanwhile,
        // so reconnect from the host's row once it is allowed, as a user would.
        if allowLocalNetwork(), !trust.waitForExistence(timeout: 5) {
            row(in: app).tapWhenReady()
        }
        if trust.waitForExistence(timeout: 15) { trust.tap() }
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
    }

    func allowLocalNetwork(timeout: TimeInterval = 1) -> Bool {
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        guard allow.waitForExistence(timeout: timeout) else { return false }
        allow.tap()
        return true
    }

    func row(in app: XCUIApplication) -> XCUIElement {
        search(name, in: app)
        // The label also carries the connection status, e.g. "Connected, e2e-1A2B3C".
        return app.buttons.matching(NSPredicate(format: "identifier == 'connections-card' AND label ENDSWITH %@", ", " + name)).firstMatch
    }

    /// A search that matches no workspace hides your workspaces, which otherwise push the connection list off screen.
    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.textFields["workspace-search"]
        guard field.waitForExistence(timeout: 10), (field.value as? String) != text else { return }
        field.tap()
        field.clearText()
        field.typeText(text + "\n")
    }

    /// Taps the session's workspace card on the home screen.
    func openTmuxSession(_ session: String, in app: XCUIApplication) {
        search(name, in: app)
        app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@ AND label CONTAINS %@", ":tmux:" + session, name))
            .firstMatch.tapWhenReady(timeout: 30)
    }

    func closeTerminal(in app: XCUIApplication) {
        app.buttons["Terminal Actions"].tapWhenReady()
        app.buttons["Close Session"].tapWhenReady()
    }

    func removeFromApp(_ app: XCUIApplication) {
        // Best effort, so a phone's own hosts are left as they were.
        app.activate()
        goHome(in: app)
        let row = row(in: app)
        guard row.waitForExistence(timeout: 5) else { return }
        row.press(forDuration: 1)
        let delete = app.buttons["Delete"]
        if delete.waitForExistence(timeout: 3) { delete.tap() }
    }

    func waitForScreen(in app: XCUIApplication, timeout: TimeInterval = 20, until condition: (String) -> Bool) throws {
        let terminal = app.textViews["terminal"]
        func screen() -> String { terminal.exists ? (terminal.value as? String) ?? "" : "" }
        try wait(timeout, "terminal to show the expected text; last screen:\n\(screen())") { condition(screen()) }
    }

    func waitForState(timeout: TimeInterval = 20, until condition: (HostState) -> Bool) throws {
        // On a phone the runner can't reach the Mac (iOS denies it local network access); scripts/e2e.sh
        // checks the host after the run instead.
        guard ProcessInfo.processInfo.environment["STEER_E2E_ON_DEVICE"] != "1" else { return }
        var last: HostState?
        var lastError: Error?
        try wait(timeout, "host state; last: \(String(describing: last)), error: \(String(describing: lastError))") {
            _ = allowLocalNetwork()
            do { last = try state() } catch { lastError = error }
            return last.map(condition) ?? false
        }
    }

    func requireControl() throws {
        if ProcessInfo.processInfo.environment["STEER_E2E_ON_DEVICE"] == "1" {
            throw XCTSkip("On a phone the runner can't reach the Mac's test helper.")
        }
    }

    func state() throws -> HostState {
        try JSONDecoder().decode(HostState.self, from: fetch("state"))
    }

    func fetch(_ path: String) throws -> Data {
        var result: Result<Data, Error> = .failure(URLError(.timedOut))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: control.appendingPathComponent(path)) { data, _, error in
            result = data.map(Result.success) ?? .failure(error ?? URLError(.badServerResponse))
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return try result.get()
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tapWhenReady()
        field.typeText(text)
    }

    private func wait(_ timeout: TimeInterval, _ what: @autoclosure () -> String, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw XCTestError(.timeoutWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(what())"]) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }
}

extension XCUIElement {
    func tapWhenReady(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        guard waitForExistence(timeout: timeout) else {
            XCTFail("Missing \(self)\n\(XCUIApplication().debugDescription)", file: file, line: line)
            return
        }
        tap()
    }

    func clearText() {
        guard let value = value as? String, !value.isEmpty else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    }
}
