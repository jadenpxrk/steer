import SwiftUI

struct ZenAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var enabled = true
    let action: () -> Void
}

/// Zen mode's only chrome: a status handle that opens a ring of terminal actions.
struct ZenOverlay: View {
    let phase: TerminalController.Phase
    let actions: [ZenAction]
    @State private var isOpen = false

    var body: some View {
        ZStack {
            if isOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { isOpen = false }
                ring
            }
            VStack {
                Button { isOpen.toggle() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(width: 56, height: 22)
                    .background(Theme.surface2, in: Capsule())
                }
                .accessibilityLabel(isOpen ? "Close actions" : "Terminal actions")
                .accessibilityValue(statusText)
                .padding(.top, 3)
                Spacer()
            }
        }
        .animation(.snappy(duration: 0.2), value: isOpen)
    }

    private var ring: some View {
        ZStack {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                Button {
                    isOpen = false
                    item.action()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 52, height: 52)
                            .foregroundStyle(Theme.ink)
                            .background(Theme.surface2, in: Circle())
                            .overlay { Circle().stroke(Theme.hairline, lineWidth: 1) }
                        Text(item.title)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .fixedSize()
                    }
                }
                .disabled(!item.enabled)
                .accessibilityLabel(item.title)
                .offset(offset(index, of: actions.count))
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private func offset(_ index: Int, of count: Int) -> CGSize {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(max(count, 1))
        return CGSize(width: cos(angle) * 132, height: sin(angle) * 132)
    }

    private var statusColor: Color {
        switch phase {
        case .connected: Theme.ok
        case .connecting: Theme.warn
        case .idle, .failed: Theme.danger
        }
    }

    private var statusText: String {
        switch phase {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .idle: "Disconnected"
        case .failed: "Connection failed"
        }
    }
}
