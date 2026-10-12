import SwiftUI
import UIKit

enum Theme {
    static let bg = Color(uiColor: UIColor { $0[SteerPaletteTrait.self].backgroundColor })
    static let ink = Color(uiColor: UIColor { $0[SteerPaletteTrait.self].foregroundColor })
    static let bgElevated = surfaceColor(0.08)
    static let surface = surfaceColor(0.13)
    static let surface2 = surfaceColor(0.18)
    static let muted = ink.opacity(0.58)
    static let faint = ink.opacity(0.28)
    static let hairline = ink.opacity(0.08)
    static let accent = ink

    private static func surfaceColor(_ amount: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let palette = traits[SteerPaletteTrait.self]
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            palette.backgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let target: CGFloat = palette.light ? 0 : 1
            return UIColor(red: red + (target - red) * amount, green: green + (target - green) * amount,
                           blue: blue + (target - blue) * amount, alpha: 1)
        })
    }
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)
    static let ok = Color(red: 0.42, green: 0.86, blue: 0.58)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.32)
}

extension View {
    func steerChrome() -> some View {
        tint(Theme.ink)
    }

    /// OK-only alert shown while `message` is non-nil; dismissing clears it.
    func errorAlert(_ title: String, message: Binding<String?>) -> some View {
        alert(title, isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

struct SteerTabItem: Identifiable, Equatable {
    let id: String
    let title: String
    let isSelected: Bool
}

struct SteerTabStrip: View {
    let tabs: [SteerTabItem]
    let select: @MainActor (String) async -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    Button {
                        Task { await select(tab.id) }
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minWidth: 44, minHeight: 44)
                            .foregroundStyle(tab.isSelected ? Theme.ink : Theme.muted)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(tab.isSelected ? Theme.ink : .clear)
                                    .frame(height: 2)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab.isSelected ? .isSelected : [])
                }
            }
        }
        .frame(height: 44)
        .background(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SteerStatusDot: View {
    var color: Color
    var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: pulse ? 4 : 0)
    }
}

struct SteerKeycapStyle: ButtonStyle {
    var prominent = false
    var armed = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 15 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(armed || prominent ? Theme.bg : Theme.ink)
            .frame(maxWidth: compact ? .infinity : nil)
            .frame(minWidth: compact ? 44 : 42, minHeight: compact ? 44 : 36)
            .padding(.horizontal, compact ? 0 : 4)
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                    .fill(armed || prominent ? Theme.accent : Theme.surface2)
            )
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 8 : 9, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

struct SteerPaletteTrait: UITraitDefinition {
    static let defaultValue = TerminalPalette.midnight
    static let affectsColorAppearance = true
}

extension TerminalPalette {
    var backgroundColor: UIColor { color(background) }
    var foregroundColor: UIColor { color(foreground) }
    var cursorColor: UIColor { color(cursor) }

    private func color(_ hex: String) -> UIColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

struct AppPaletteBridge: UIViewRepresentable {
    var palette: TerminalPalette

    func makeUIView(context: Context) -> PaletteView { PaletteView() }
    func updateUIView(_ view: PaletteView, context: Context) {
        view.palette = palette
        view.apply()
    }

    final class PaletteView: UIView {
        var palette = TerminalPalette.midnight
        override func didMoveToWindow() { super.didMoveToWindow(); apply() }
        func apply() {
            window?.windowScene?.traitOverrides[SteerPaletteTrait.self] = palette
            window?.tintColor = palette.foregroundColor
        }
    }
}
