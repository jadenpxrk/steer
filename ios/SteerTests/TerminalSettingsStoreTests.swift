import Foundation
import Testing
@testable import Steer

struct TerminalSettingsStoreTests {
    @Test @MainActor
    func persistsAppearanceToolbarAndShortcuts() {
        let suite = "TerminalSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalSettingsStore(defaults: defaults)
        store.preferences.fontSize = 19
        store.preferences.theme = .solarizedDark
        store.preferences.toolbarActions = [.escape, .paste]
        store.addShortcut(CustomTerminalShortcut(label: "Status", text: "git status"))

        let restored = TerminalSettingsStore(defaults: defaults)

        #expect(restored.preferences.fontSize == 19)
        #expect(restored.preferences.theme == .solarizedDark)
        #expect(restored.preferences.toolbarActions == [.escape, .paste])
        #expect(restored.preferences.customShortcuts.map(\.text) == ["git status"])
    }

    @Test @MainActor
    func commandHistoryIsUniqueAndBounded() {
        let suite = "TerminalSettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TerminalSettingsStore(defaults: defaults)

        for index in 0..<35 {
            store.rememberCommand("command-\(index)")
        }
        store.rememberCommand("command-20")

        #expect(store.preferences.commandHistory.count == 30)
        #expect(store.preferences.commandHistory.first == "command-20")
        #expect(store.preferences.commandHistory.filter { $0 == "command-20" }.count == 1)
    }

    @Test
    func olderPreferencesKeepNewDefaults() throws {
        let data = #"{"fontSize":18,"theme":"graphite"}"#.data(using: .utf8)!
        let preferences = try JSONDecoder().decode(TerminalPreferences.self, from: data)

        #expect(preferences.fontSize == 18)
        #expect(preferences.theme == .graphite)
        #expect(preferences.ligaturesEnabled)
        #expect(!preferences.toolbarActions.isEmpty)
    }

    @Test
    func builtInFontsAreUniqueAndIncludeSystemMono() {
        let ids = TerminalFontRegistry.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(TerminalFontRegistry.builtIn.contains { $0.postScriptName == nil })
        #expect(TerminalFontRegistry.builtIn.map(\.title).contains("JetBrains Mono"))
        #expect(TerminalFontRegistry.builtIn.map(\.title).contains("Fira Code"))
    }

    @Test
    func wordReplacementsMatchWholeWordsIgnoringCase() {
        let rules = [
            WordReplacement(heard: "cloud code", replacement: "claude code"),
            WordReplacement(heard: "get", replacement: "git"),
            WordReplacement(heard: "", replacement: "ignored"),
        ]
        #expect(WordReplacement.apply(rules, to: "Open Cloud Code then get status") == "Open claude code then git status")
        #expect(WordReplacement.apply(rules, to: "target getter") == "target getter")
        #expect(WordReplacement.apply([WordReplacement(heard: "dollar", replacement: "$HOME")], to: "cd dollar") == "cd $HOME")
    }
}
