import SwiftUI

/// Arrow keys plus two configurable corner slots (Interrupt and Backspace by default).
struct ArrowDialView: View {
    var send: (ArraySlice<UInt8>) -> Void
    var topLeft: TerminalGestureAction = .interrupt
    var topRight: TerminalGestureAction = .backspace
    var perform: (TerminalGestureAction) -> Void = { _ in }

    var body: some View {
        ZStack {
            ForEach(Array(arrows.enumerated()), id: \.element.id) { index, item in
                dialButton(item.title, systemImage: item.systemImage, action: item.action)
                    .offset(offset(for: index))
            }
            ForEach([(topLeft, -1.0), (topRight, 1.0)], id: \.1) { action, side in
                if action != .none {
                    dialButton(action.title, systemImage: Self.symbol(for: action)) { perform(action) }
                        .offset(x: side * 52, y: -52)
                }
            }
        }
        .frame(width: 160, height: 160)
        .allowsHitTesting(true)
    }

    private func dialButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.ink)
                .background(Theme.surface2, in: Circle())
                .overlay {
                    Circle().stroke(Theme.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .accessibilityLabel(title)
        .transition(.scale.combined(with: .opacity))
    }

    private static func symbol(for action: TerminalGestureAction) -> String {
        switch action {
        case .interrupt: "xmark.octagon"
        case .backspace: "delete.left"
        case .escape: "escape"
        case .enter: "return"
        case .paste: "doc.on.clipboard"
        case .keyboard: "keyboard"
        case .shortcuts, .shortcut: "command"
        case .control: "control"
        case .nextTab: "arrow.right.to.line"
        case .previousTab: "arrow.left.to.line"
        case .rightClick: "cursorarrow.click.2"
        case .none: "circle"
        }
    }

    private var arrows: [DialAction] {
        [
            DialAction(id: "up", title: "Up", systemImage: "arrow.up") {
                send(Array("\u{1b}[A".utf8)[...])
            },
            DialAction(id: "right", title: "Right", systemImage: "arrow.right") {
                send(Array("\u{1b}[C".utf8)[...])
            },
            DialAction(id: "down", title: "Down", systemImage: "arrow.down") {
                send(Array("\u{1b}[B".utf8)[...])
            },
            DialAction(id: "left", title: "Left", systemImage: "arrow.left") {
                send(Array("\u{1b}[D".utf8)[...])
            },
        ]
    }

    private func offset(for index: Int) -> CGSize {
        let angle = -Double.pi / 2 + (Double.pi / 2) * Double(index)
        let radius = 52.0
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}

private struct DialAction {
    let id: String
    let title: String
    let systemImage: String
    let action: () -> Void
}
