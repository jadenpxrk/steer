import Foundation
import LocalAuthentication

@MainActor
final class TerminalSettingsStore: ObservableObject {
    @Published var preferences: TerminalPreferences {
        didSet { persist() }
    }
    private let defaults: UserDefaults
    nonisolated private static let storageKey = "terminal-preferences"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        TerminalFontRegistry.registerBundledFonts()
        preferences = Self.stored(defaults)
        if let name = preferences.fontName,
           !TerminalFontRegistry.builtIn.contains(where: { $0.postScriptName == name }) {
            preferences.fontName = nil
        }
    }

    nonisolated static func stored(_ defaults: UserDefaults = .standard) -> TerminalPreferences {
        defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode(TerminalPreferences.self, from: $0) } ?? TerminalPreferences()
    }

    func moveToolbarActions(from offsets: IndexSet, to destination: Int) {
        preferences.toolbarActions.move(fromOffsets: offsets, toOffset: destination)
    }

    func addToolbarAction(_ action: TerminalToolbarAction) {
        guard !preferences.toolbarActions.contains(action) else { return }
        preferences.toolbarActions.append(action)
    }

    func removeToolbarActions(at offsets: IndexSet) {
        preferences.toolbarActions.remove(atOffsets: offsets)
    }

    func addShortcut(_ shortcut: CustomTerminalShortcut) {
        preferences.customShortcuts.append(shortcut)
    }

    func removeShortcuts(at offsets: IndexSet) {
        let removed = Set(offsets.map { preferences.customShortcuts[$0].id })
        preferences.customShortcuts.remove(atOffsets: offsets)
        for (gesture, action) in preferences.gestureBindings {
            if case .shortcut(let id) = action, removed.contains(id) {
                preferences.gestureBindings[gesture] = TerminalGestureAction.none
            }
        }
    }

    func rememberCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        preferences.commandHistory.removeAll { $0 == trimmed }
        preferences.commandHistory.insert(trimmed, at: 0)
        if preferences.commandHistory.count > 30 {
            preferences.commandHistory.removeLast(preferences.commandHistory.count - 30)
        }
    }

    func setAppLock(_ enabled: Bool) async throws {
        let context = LAContext()
        guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: enabled ? "Require authentication when opening Steer." : "Turn off the Steer app lock.") else { return }
        preferences.lockOnResume = enabled
    }

    func rememberTranscription(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        preferences.transcriptionHistory.removeAll { $0 == text }
        preferences.transcriptionHistory.insert(text, at: 0)
        preferences.transcriptionHistory = Array(preferences.transcriptionHistory.prefix(30))
    }

    func clearHistory() {
        preferences.commandHistory = []
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await SteerNotifications.requestAuthorization()
            preferences.notificationsEnabled = granted
            SteerNotifications.isEnabled = granted
        } else {
            preferences.notificationsEnabled = false
            SteerNotifications.isEnabled = false
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
