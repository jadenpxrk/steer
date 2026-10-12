import SwiftUI

enum TerminalShortcutPanelSection: String, CaseIterable, Identifiable {
    case favorites
    case control
    case tmux
    case agent
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .control: "Ctrl"
        case .tmux: "tmux"
        case .agent: "Agents"
        case .history: "History"
        }
    }
}

struct TerminalShortcutPanelView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var section: TerminalShortcutPanelSection

    let sendBytes: (ArraySlice<UInt8>) -> Void
    let sendText: (CustomTerminalShortcut) -> Void
    let showSessions: () -> Void
    let showJump: () -> Void
    let canShowSessions: Bool
    let canShowJump: Bool

    init(
        initialSection: TerminalShortcutPanelSection,
        sendBytes: @escaping (ArraySlice<UInt8>) -> Void,
        sendText: @escaping (CustomTerminalShortcut) -> Void,
        showSessions: @escaping () -> Void,
        showJump: @escaping () -> Void,
        canShowSessions: Bool,
        canShowJump: Bool
    ) {
        _section = State(initialValue: initialSection)
        self.sendBytes = sendBytes
        self.sendText = sendText
        self.showSessions = showSessions
        self.showJump = showJump
        self.canShowSessions = canShowSessions
        self.canShowJump = canShowJump
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SteerTabStrip(tabs: TerminalShortcutPanelSection.allCases.map {
                    SteerTabItem(id: $0.id, title: $0.title, isSelected: section == $0)
                }, select: { id in
                    if let next = TerminalShortcutPanelSection(rawValue: id) { section = next }
                })
                .accessibilityLabel("Shortcut pack")
                .padding()

                List {
                    content
                }
                .listStyle(.plain)
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .favorites:
            if settings.preferences.customShortcuts.isEmpty {
                ContentUnavailableView(
                    "No custom shortcuts",
                    systemImage: "command",
                    description: Text("Add shortcuts in Terminal Settings.")
                )
            } else {
                ForEach(settings.preferences.customShortcuts) { shortcut in
                    Button(shortcut.label) {
                        sendText(shortcut)
                        dismiss()
                    }
                }
            }
        case .control:
            shortcut("Ctrl-A", bytes: [0x01])
            shortcut("Ctrl-C", bytes: [0x03])
            shortcut("Ctrl-D", bytes: [0x04])
            shortcut("Ctrl-E", bytes: [0x05])
            shortcut("Ctrl-K", bytes: [0x0b])
            shortcut("Ctrl-L", bytes: [0x0c])
            shortcut("Ctrl-R", bytes: [0x12])
            shortcut("Ctrl-U", bytes: [0x15])
            shortcut("Ctrl-Z", bytes: [0x1a])
        case .tmux:
            shortcut("New window", bytes: [0x02, 0x63])
            shortcut("Next window", bytes: [0x02, 0x6e])
            shortcut("Previous window", bytes: [0x02, 0x70])
            shortcut("Choose window", bytes: [0x02, 0x77])
            shortcut("Detach", bytes: [0x02, 0x64])
        case .agent:
            Button("Sessions", systemImage: "square.stack.3d.up", action: showSessions)
                .disabled(!canShowSessions)
            Button("Sidebar", systemImage: "sidebar.left", action: showJump)
                .disabled(!canShowJump)
            shortcut("Interrupt", bytes: [0x03])
            shortcut("End input", bytes: [0x04])
            shortcut("Escape", bytes: Array("\u{1b}".utf8))
            shortcut("Tab", bytes: [0x09])
        case .history:
            if settings.preferences.commandHistory.isEmpty {
                ContentUnavailableView(
                    "No saved history",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Commands sent from custom shortcuts appear here.")
                )
            } else {
                ForEach(settings.preferences.commandHistory, id: \.self) { command in
                    Button {
                        sendText(CustomTerminalShortcut(label: command, text: command))
                        dismiss()
                    } label: {
                        Text(command)
                            .font(.body.monospaced())
                            .lineLimit(3)
                    }
                }
                Button("Clear history", role: .destructive) {
                    settings.clearHistory()
                }
            }
        }
    }

    private func shortcut(_ title: String, bytes: [UInt8]) -> some View {
        Button(title) {
            sendBytes(bytes[...])
            dismiss()
        }
    }
}
