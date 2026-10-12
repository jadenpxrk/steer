import Foundation

struct TerminalPalette: Codable, Equatable, Sendable {
    var name: String
    var background: String
    var foreground: String
    var cursor: String
    var light: Bool

    static let midnight = TerminalPalette(name: "Midnight", background: "#000000", foreground: "#FFFFFF", cursor: "#FFFFFF", light: false)

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw PaletteError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard !value.name.isEmpty, value.name.count <= 80,
              [value.background, value.foreground, value.cursor].allSatisfy(validHex) else {
            throw PaletteError.invalid
        }
        return value
    }

    static func validHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }
}

enum PaletteError: LocalizedError {
    case invalid
    var errorDescription: String? { "Choose a theme JSON file with a name, background, foreground, cursor (#RRGGBB colors), and light (true or false)." }
}

extension TerminalPreferences {
    var palette: TerminalPalette {
        if let customPalette { return customPalette }
        switch theme {
        case .midnight: return .midnight
        case .graphite: return TerminalPalette(name: "Graphite", background: "#141414", foreground: "#E0E0E0", cursor: "#FFFFFF", light: false)
        case .solarizedDark: return TerminalPalette(name: "Solarized Dark", background: "#002B36", foreground: "#829496", cursor: "#B58A00", light: false)
        case .light: return TerminalPalette(name: "Light", background: "#F5F7FA", foreground: "#1F242E", cursor: "#1961D9", light: true)
        }
    }
}
