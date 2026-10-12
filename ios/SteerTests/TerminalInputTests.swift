import Foundation
import Testing
@testable import Steer

struct TerminalInputTests {
    @Test @MainActor
    func rejectedSendsKeepTheCallerFromClearingState() {
        let controller = TerminalController(host: Host(name: "Mac", hostname: "mac.invalid", username: "me"))
        #expect(!controller.canAcceptInput)
        #expect(!controller.send(Array("echo hi\r".utf8)[...]))
        #expect(controller.errorMessage == SSHExecError.notConnected.localizedDescription)
        let pane = HerdrAgent(
            paneID: "p1",
            agent: "",
            status: nil,
            cwd: nil,
            foregroundCWD: nil,
            terminalTitle: nil,
            focused: true,
            workspaceID: "w",
            tabID: "t",
            terminalID: nil
        )
        controller.pendingMux = .herdrAgent(pane)
        controller.errorMessage = nil
        #expect(!controller.canAcceptInput)
        #expect(!controller.send(Array("echo hi\r".utf8)[...]))
        #expect(controller.muxAttachError == HerdrSessionError.disconnected.errorDescription)
    }

    @Test func encodesBindings() throws {
        #expect(try TerminalBinding.steps("C-c") == [[3]])
        #expect(try TerminalBinding.steps("C-b, T") == [[2], [84]])
        #expect(try TerminalBinding.steps("Ctrl+b, Shift+t") == [[2], [84]])
        #expect(try TerminalBinding.steps("F12, h") == [Array("\u{1b}[24~".utf8), [104]])
        #expect(try TerminalBinding.steps("S-Tab") == [[27, 91, 90]])
        #expect(try TerminalBinding.steps("C-dash") == [[31]])
        #expect(try TerminalBinding.steps("M-x Esc BSpace") == [[27, 120], [27], [127]])
        #expect(try TerminalBinding.steps("S-Up F1 C-F5") == [Array("\u{1b}[1;2A".utf8), [27, 79, 80], Array("\u{1b}[15;5~".utf8)])
        #expect(try TerminalBinding.steps("text:/clear, now") == [Array("/clear, now".utf8)])
        #expect(throws: KeySequenceError.self) { try TerminalBinding.steps("Contrl-b") }
        #expect(throws: KeySequenceError.self) { try TerminalBinding.steps("F13") }
        #expect(throws: KeySequenceError.self) { try TerminalBinding.steps("C-1") }

        let shortcut = CustomTerminalShortcut(label: "tmux", text: "C-b, 1", appendReturn: true, keySequence: true, bindingSyntax: true)
        #expect(try shortcut.steps == [[2], [49], [13]])
        #expect(try CustomTerminalShortcut(label: "literal", text: "C-b").steps == [Array("C-b".utf8), [13]])
    }

    @Test @MainActor func dPadCornersDefaultToInterruptAndBackspace() async throws {
        let preferences = TerminalPreferences()
        #expect(preferences.action(for: .dpadTopLeft) == .interrupt)
        #expect(preferences.action(for: .dpadTopRight) == .backspace)
        var sent: [[UInt8]] = []
        let handlers = TerminalActionHandlers(
            send: { sent.append(Array($0)); return true },
            openShortcuts: {}, muxCycle: { _ in }, toggleKeyboard: {}, armControl: {}, armRightClick: {}
        )
        TerminalGestureAction.backspace.perform(shortcuts: [], handlers)
        let chord = CustomTerminalShortcut(label: "next", text: "C-b, n", appendReturn: false, keySequence: true, bindingSyntax: true)
        TerminalGestureAction.shortcut(chord.id).perform(shortcuts: [chord], handlers)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent == [[127], [2], [110]])
    }

    @Test func migratesOldGesturePreferences() throws {
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: Data(#"{"twoFingerMuxSwipe":false}"#.utf8))
        #expect(preferences.action(for: .left) == .none)
        #expect(preferences.action(for: .tap) == .shortcuts)
        #expect(preferences.action(for: .up) == .none)
    }

    @Test @MainActor func removingShortcutClearsGestureBinding() {
        let suite = "TerminalInputTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TerminalSettingsStore(defaults: defaults)
        let shortcut = CustomTerminalShortcut(label: "Test", text: "echo test")
        settings.addShortcut(shortcut)
        settings.preferences.gestureBindings["tap"] = .shortcut(shortcut.id)
        settings.removeShortcuts(at: IndexSet(integer: 0))
        #expect(settings.preferences.action(for: .tap) == .none)
    }

    @Test func validatesAndRoundTripsThemeFiles() throws {
        let palette = TerminalPalette.midnight
        #expect(try TerminalPalette.decode(JSONEncoder().encode(palette)) == palette)
        var invalid = palette
        invalid.background = "#GG0000"
        #expect(throws: PaletteError.self) { try TerminalPalette.decode(JSONEncoder().encode(invalid)) }
    }

    @Test @MainActor func boundsTranscriptionHistoryAndRestoresIt() {
        let suite = "TranscriptionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = TerminalSettingsStore(defaults: defaults)
        for index in 0..<35 { settings.rememberTranscription("text \(index)") }
        settings.rememberTranscription("text 20")
        let restored = TerminalSettingsStore(defaults: defaults)
        #expect(restored.preferences.transcriptionHistory.count == 30)
        #expect(restored.preferences.transcriptionHistory.first == "text 20")
    }
}
