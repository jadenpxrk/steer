import SwiftTerm
import SwiftUI
import Testing
import UIKit
@testable import Steer

@MainActor
final class TerminalScrollTests {
    @Test func sessionChromeRespondsDuringOutput() async throws {
        let suite = "TerminalChromeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TerminalSettingsStore(defaults: defaults)
        let controller = TerminalController(host: Host(name: "Fixture", hostname: "fixture.invalid", username: "fixture"))
        controller.phase = .connecting
        let host = UIHostingController(rootView: NavigationStack {
            TerminalSessionView(controller: controller).environmentObject(settings)
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { controller.detach(); window.isHidden = true; window.rootViewController = nil }
        func terminal(in view: UIView) -> SteerTerminalView? {
            if let terminal = view as? SteerTerminalView { return terminal }
            return view.subviews.lazy.compactMap { terminal(in: $0) }.first
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while terminal(in: host.view) == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let view = try #require(terminal(in: host.view))
        let clock = ContinuousClock()
        var worstUpdate = Duration.zero
        for frame in 0..<60 {
            let text = "\u{1b}[H\u{1b}[32;1mCoding agent\u{1b}[0m\r\n" +
                (0..<30).map { "Working on line \($0) (\(frame))" }.joined(separator: "\r\n")
            view.feed(text: text)
            let start = clock.now
            controller.toggleControl()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            worstUpdate = max(worstUpdate, start.duration(to: clock.now))
            try await Task.sleep(for: .milliseconds(16))
        }
        #expect(view.font.pointSize == CGFloat(settings.preferences.fontSize))
        #expect(worstUpdate < .milliseconds(250))
    }

    @Test func nativeFramesKeepBordersStylesAndRowsWithoutRewrapping() throws {
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        let screen = view.getTerminal()
        let cols = screen.cols
        let rows = screen.rows
        let border = "┌" + String(repeating: "─", count: cols - 2) + "┐"
        let content = "\u{1b}[1;1H\u{1b}[31;1m" + border +
            "\u{1b}[2;1H│Cafe\u{301} 界\u{1b}[2;\(cols)H│" +
            "\u{1b}[3;1H└" + String(repeating: "─", count: cols - 2) + "┘"
        view.feedHerdrFrames([.init(seq: 1, width: cols, height: rows, full: true, bytes: Array(content.utf8))])
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: cols - 1, row: 0))) == "┐")
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: 0, row: 1))) == "│")
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: 0, row: 2))) == "└")
        #expect(screen.getCharData(col: 0, row: 0)?.attribute.fg == .ansi256(code: 1))
        #expect(screen.getCharData(col: 0, row: 0)?.attribute.style.contains(.bold) == true)
        view.feedHerdrFrames([.init(seq: 2, width: cols, height: rows, full: false, bytes: Array("\u{1b}[2;2H\u{1b}[32mNext".utf8))])
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: 1, row: 1))) == "N")
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: cols - 1, row: 0))) == "┐")
        view.feedHerdrFrames([.init(seq: 3, width: 320, height: 90, full: true, bytes: Array("STALE DESKTOP".utf8))])
        #expect(screen.getCharacter(for: try #require(screen.getCharData(col: 0, row: 0))) == "┌")
        #expect(screen.cols == cols)
        #expect(view.font.pointSize == 14)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.contentSize.width == view.bounds.width)
    }

    @Test func herdrScrollingUsesNativeScrollEvenWithoutMouseReporting() {
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 430, height: 700))
        view.allowMouseReporting = false
        var scrolls: [Int] = []
        view.onRemoteScroll = { lines, _, _ in scrolls.append(lines) }
        #expect(view.reportsMouseWheel)
        view.scrollWheel(deltaY: 120, at: .zero)
        view.scrollWheel(deltaY: -120, at: .zero)
        #expect(scrolls.count == 2)
        #expect(scrolls[0] > 0)
        #expect(scrolls[1] < 0)
        view.onRemoteScroll = nil
        #expect(!view.reportsMouseWheel)
    }

    @Test func canvasKeepsReadableFontAtPhoneWidth() async throws {
        var rendered: TerminalView?
        let canvas = TerminalCanvas(
            preferences: TerminalPreferences(),
            onReady: { rendered = $0 }, onSend: { _ in }, onGestureSend: { _ in },
            onToggleKeyboard: {}, onResize: { _, _ in }, onDirectory: { _ in },
            onFontSizeChange: { _ in }, onMuxCycle: { _ in }, onOpenShortcuts: {}, onBell: {}
        )
        let host = UIHostingController(rootView: canvas)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        let view = try #require(rendered)
        #expect(view.bounds.width > 0)
        #expect(view.getTerminal().cols < 100)
        #expect(view.font.pointSize == 14)
        withExtendedLifetime(host) {}
    }

    private var sent: [[UInt8]] = []
    private lazy var coordinator = Coordinator(parent: TerminalCanvas(
        preferences: TerminalPreferences(),
        onReady: { _ in },
        onSend: { [weak self] in self?.sent.append(Array($0)) },
        onGestureSend: { [weak self] in self?.sent.append(Array($0)) },
        onToggleKeyboard: {}, onResize: { _, _ in }, onDirectory: { _ in },
        onFontSizeChange: { _ in }, onMuxCycle: { _ in }, onOpenShortcuts: {}, onBell: {}
    ))
    private lazy var view: SteerTerminalView = {
        let view = SteerTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        view.terminalDelegate = coordinator
        coordinator.installGestures(on: view)
        return view
    }()

    @Test func findsLinksUnderATap() throws {
        view.feed(text: "see example.com/docs and https://github.com/x\r\n")
        let terminal = view.getTerminal()
        let cell = try #require(view.cellSizeInPixels(source: terminal))
        let scale = view.window?.contentScaleFactor ?? 1
        func point(col: Int) -> CGPoint {
            CGPoint(x: (CGFloat(col) + 0.5) * CGFloat(cell.width) / scale, y: 0.5 * CGFloat(cell.height) / scale)
        }
        #expect(view.link(at: point(col: 30)) == "https://github.com/x")
        #expect(view.link(at: point(col: 1)) == nil)
    }

    @Test func rightClickReachesOnlyMouseAwareApps() {
        let cell = view.cellSizeInPixels(source: view.getTerminal())!
        let scale = view.window?.contentScaleFactor ?? 1
        let point = CGPoint(x: CGFloat(cell.width) * 2.5 / scale, y: CGFloat(cell.height) * 3.5 / scale)
        sent = []
        #expect(!view.sendRightClick(at: point))
        #expect(sent.isEmpty)

        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        sent = []
        #expect(view.sendRightClick(at: point))
        #expect(sent.map { String(decoding: $0, as: UTF8.self) }.joined() == "\u{1b}[<2;3;4M\u{1b}[<0;3;4m")
    }

    @Test func alternateScreenWithoutMouseDoesNotSendCommandHistoryKeys() {
        view.feed(text: "\u{1b}[?1049h")
        #expect(view.getTerminal().isCurrentBufferAlternate)
        #expect(!view.reportsMouseWheel)
        sent = []
        view.scrollWheel(deltaY: 120, at: .zero)
        view.scrollWheel(deltaY: -120, at: .zero)
        #expect(sent.isEmpty)
    }

    @Test func dragsSendWheelEventsInBothDirections() {
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1000h\u{1b}[?1006h")
        #expect(view.reportsMouseWheel)
        sent = []
        view.scrollWheel(deltaY: 120, at: .zero)
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { isRepeated($0, Array("\u{1b}[<64;1;1M".utf8)) })
        sent = []
        view.resetWheelScroll()
        view.scrollWheel(deltaY: -120, at: .zero)
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { isRepeated($0, Array("\u{1b}[<65;1;1M".utf8)) })
    }

    @Test func smallDragsAccumulateAndMouseModeChangesClearThem() {
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let cell = view.cellSizeInPixels(source: view.getTerminal())!
        let lineHeight = CGFloat(cell.height) / max(view.traitCollection.displayScale, 1)
        sent = []
        view.scrollWheel(deltaY: lineHeight * 0.6, at: .zero)
        #expect(sent.isEmpty)
        view.scrollWheel(deltaY: lineHeight * 0.6, at: .zero)
        #expect(sent == [Array("\u{1b}[<64;1;1M".utf8)])
        view.feed(text: "\u{1b}[?1000l")
        view.feed(text: "\u{1b}[?1000h")
        sent = []
        view.scrollWheel(deltaY: lineHeight * 0.9, at: .zero)
        #expect(sent.isEmpty)
    }

    @Test func shellScrollbackAndDisabledMouseReportingDoNotSendInput() {
        view.feed(text: (0..<100).map { "line \($0)\r\n" }.joined())
        #expect(!view.getTerminal().isCurrentBufferAlternate)
        sent = []
        view.scrollUp(lines: 10)
        view.scrollWheel(deltaY: 100, at: .zero)
        #expect(sent.isEmpty)
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        view.allowMouseReporting = false
        sent = []
        view.scrollWheel(deltaY: 100, at: .zero)
        #expect(sent.isEmpty)
    }

    @Test func mouseModeDoesNotInstallACompetingDragRecognizer() {
        let pans = view.gestureRecognizers!.filter { $0 is UIPanGestureRecognizer }.count
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        #expect(view.gestureRecognizers!.filter { $0 is UIPanGestureRecognizer }.count == pans)
    }

    @Test func wheelTargetsTheTouchedCellAndClampsToTheScreen() {
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let cell = view.cellSizeInPixels(source: view.getTerminal())!
        let scale = max(view.traitCollection.displayScale, 1)
        let point = CGPoint(x: CGFloat(cell.width) * 2.5 / scale, y: CGFloat(cell.height) * 3.5 / scale)
        sent = []
        view.scrollWheel(deltaY: 120, at: point)
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { isRepeated($0, Array("\u{1b}[<64;3;4M".utf8)) })
        sent = []
        view.scrollWheel(deltaY: -120, at: CGPoint(x: 100_000, y: 100_000))
        let terminal = view.getTerminal()
        #expect(sent.allSatisfy { isRepeated($0, Array("\u{1b}[<65;\(terminal.cols);\(terminal.rows)M".utf8)) })
    }

    @Test func wheelEventsCoalesceIntoOneWriteWithoutLosingDirection() {
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let cell = view.cellSizeInPixels(source: view.getTerminal())!
        let lineHeight = CGFloat(cell.height) / max(view.traitCollection.displayScale, 1)
        sent = []
        view.scrollWheel(deltaY: lineHeight * 6, at: .zero)
        #expect(sent.count == 1)
        #expect(isRepeated(sent[0], Array("\u{1b}[<64;1;1M".utf8)))
        #expect(sent[0].count == Array("\u{1b}[<64;1;1M".utf8).count * 6)
        sent = []
        view.resetWheelScroll()
        view.scrollWheel(deltaY: -lineHeight * 3, at: .zero)
        #expect(sent.count == 1)
        #expect(isRepeated(sent[0], Array("\u{1b}[<65;1;1M".utf8)))
    }
}

private func isRepeated(_ data: [UInt8], _ unit: [UInt8]) -> Bool {
    guard !unit.isEmpty, data.count % unit.count == 0, !data.isEmpty else { return false }
    return stride(from: 0, to: data.count, by: unit.count).allSatisfy {
        Array(data[$0..<$0 + unit.count]) == unit
    }
}
