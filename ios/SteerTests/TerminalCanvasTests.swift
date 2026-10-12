import SwiftTerm
import SwiftUI
import Testing
@testable import Steer

@MainActor
struct TerminalCanvasTests {
    @Test
    func commandHistoryChangeDoesNotClearSelection() async throws {
        let suite = "TerminalCanvasTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = TerminalSettingsStore(defaults: defaults)
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        var terminal: TerminalView?
        let screen = UIHostingController(rootView: CanvasHarness(settings: settings, ready: { terminal = $0 }))
        window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
        window.rootViewController = screen
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = try #require(terminal)
        view.feed(text: "review fixture\r\nselected text\r\n")
        view.selectAll()
        #expect(view.selectionActive)
        settings.rememberCommand("review fixture command")
        settings.preferences.notificationsEnabled = true
        settings.preferences.toolbarActions = [.escape]
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.selectionActive)
        let originalSize = view.font.pointSize
        settings.preferences.fontSize = min(28, originalSize + 4)
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.font.pointSize == CGFloat(settings.preferences.fontSize))
        settings.preferences.optionAsMeta = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(view.optionAsMetaKey == false)
    }
}

private struct CanvasHarness: View {
    @ObservedObject var settings: TerminalSettingsStore
    let ready: (TerminalView) -> Void

    var body: some View {
        TerminalCanvas(
            preferences: settings.preferences,
            onReady: ready,
            onSend: { _ in },
            onGestureSend: { _ in },
            onToggleKeyboard: {},
            onResize: { _, _ in },
            onDirectory: { _ in },
            onFontSizeChange: { _ in },
            onMuxCycle: { _ in },
            onOpenShortcuts: {},
            onBell: {}
        )
    }
}
