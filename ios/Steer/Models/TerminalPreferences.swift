import Foundation

enum TerminalTheme: String, Codable, CaseIterable, Identifiable {
    case midnight
    case graphite
    case solarizedDark
    case light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .midnight: "Midnight"
        case .graphite: "Graphite"
        case .solarizedDark: "Solarized Dark"
        case .light: "Light"
        }
    }
}

enum TerminalCursor: String, Codable, CaseIterable, Identifiable {
    case block
    case bar
    case underline

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

enum TerminalToolbarAction: String, Codable, CaseIterable, Identifiable {
    case control
    case escape
    case tab
    case enter
    case left
    case up
    case down
    case right
    case paste
    case history
    case shortcuts
    case sessions
    case jump
    case rightClick

    var id: String { rawValue }

    var title: String {
        switch self {
        case .control: "Ctrl"
        case .escape: "Esc"
        case .tab: "Tab"
        case .enter: "Enter"
        case .left: "Left"
        case .up: "Up"
        case .down: "Down"
        case .right: "Right"
        case .paste: "Paste"
        case .history: "History"
        case .shortcuts: "Shortcuts"
        case .sessions: "Sessions"
        case .jump: "Sidebar"
        case .rightClick: "Right Click"
        }
    }

    var compactTitle: String {
        switch self {
        case .left: "←"
        case .up: "↑"
        case .down: "↓"
        case .right: "→"
        case .enter: "↵"
        default: title
        }
    }

    var systemImage: String? {
        switch self {
        case .paste: "doc.on.clipboard"
        case .history: "clock.arrow.circlepath"
        case .shortcuts: "command"
        case .sessions: "square.stack.3d.up"
        case .jump: "sidebar.left"
        case .rightClick: "cursorarrow.click.2"
        default: nil
        }
    }
}

struct CustomTerminalShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var text: String
    var appendReturn = true
    var keySequence: Bool?
    /// True for the binding syntax (`C-b, 1`); otherwise `keySequence` selects the `<C-b>1` syntax.
    var bindingSyntax: Bool?
}

enum SteerClientFlag {
    static let name = "STEER_CLIENT"
    /// The login shell started with the flag; used instead of a plain shell request, which sshd's default
    /// AcceptEnv (LANG, LC_*) would strip.
    static let loginShell = "STEER_CLIENT=1 exec \"${SHELL:-/bin/sh}\" -l"

    static var enabled: Bool { TerminalSettingsStore.stored().exportClientFlag }
}

struct TerminalPreferences: Codable, Equatable {
    var fontSize = 14.0
    var fontName: String?
    var cjkLanguage = ""
    var ligaturesEnabled = true
    var theme = TerminalTheme.midnight
    var customPalette: TerminalPalette?
    var lockOnResume = false
    var scrollbackLines = 10_000
    var speechLanguage = ""
    var transcriptionHistory: [String] = []
    var dictationReplacements: [WordReplacement] = []
    var cursor = TerminalCursor.block
    var cursorBlinks = true
    var optionAsMeta = true
    var keepScreenOn = true
    /// Exports STEER_CLIENT=1 into remote shells so startup files and scripts can detect Steer.
    var exportClientFlag = false
    var hideToolbarWithHardwareKeyboard = true
    var reopenLastTerminal = true
    var glassToolbar = true
    var pinchToResizeFont = true
    var twoFingerMuxSwipe = true
    var twoFingerTapShortcuts = true
    var gestureBindings: [String: TerminalGestureAction] = [:]
    var notificationsEnabled = false
    var toolbarActions: [TerminalToolbarAction] = [
        .control, .escape, .tab, .shortcuts, .paste, .history
    ]
    var customShortcuts: [CustomTerminalShortcut] = []
    var commandHistory: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        fontName = try values.decodeIfPresent(String.self, forKey: .fontName)
        cjkLanguage = try values.decodeIfPresent(String.self, forKey: .cjkLanguage) ?? ""
        ligaturesEnabled = try values.decodeIfPresent(Bool.self, forKey: .ligaturesEnabled) ?? ligaturesEnabled
        customPalette = try values.decodeIfPresent(TerminalPalette.self, forKey: .customPalette)
        lockOnResume = try values.decodeIfPresent(Bool.self, forKey: .lockOnResume) ?? false
        scrollbackLines = min(100_000, max(1_000, try values.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10_000))
        speechLanguage = try values.decodeIfPresent(String.self, forKey: .speechLanguage) ?? ""
        transcriptionHistory = try values.decodeIfPresent([String].self, forKey: .transcriptionHistory) ?? []
        dictationReplacements = try values.decodeIfPresent([WordReplacement].self, forKey: .dictationReplacements) ?? []
        theme = try values.decodeIfPresent(TerminalTheme.self, forKey: .theme) ?? theme
        cursor = try values.decodeIfPresent(TerminalCursor.self, forKey: .cursor) ?? cursor
        cursorBlinks = try values.decodeIfPresent(Bool.self, forKey: .cursorBlinks) ?? cursorBlinks
        optionAsMeta = try values.decodeIfPresent(Bool.self, forKey: .optionAsMeta) ?? optionAsMeta
        keepScreenOn = try values.decodeIfPresent(Bool.self, forKey: .keepScreenOn) ?? keepScreenOn
        exportClientFlag = try values.decodeIfPresent(Bool.self, forKey: .exportClientFlag) ?? exportClientFlag
        hideToolbarWithHardwareKeyboard = try values.decodeIfPresent(Bool.self, forKey: .hideToolbarWithHardwareKeyboard)
            ?? hideToolbarWithHardwareKeyboard
        reopenLastTerminal = try values.decodeIfPresent(Bool.self, forKey: .reopenLastTerminal) ?? reopenLastTerminal
        glassToolbar = try values.decodeIfPresent(Bool.self, forKey: .glassToolbar) ?? glassToolbar
        pinchToResizeFont = try values.decodeIfPresent(Bool.self, forKey: .pinchToResizeFont) ?? pinchToResizeFont
        twoFingerMuxSwipe = try values.decodeIfPresent(Bool.self, forKey: .twoFingerMuxSwipe) ?? twoFingerMuxSwipe
        gestureBindings = try values.decodeIfPresent([String: TerminalGestureAction].self, forKey: .gestureBindings) ?? [:]
        twoFingerTapShortcuts = try values.decodeIfPresent(Bool.self, forKey: .twoFingerTapShortcuts) ?? twoFingerTapShortcuts
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? notificationsEnabled
        toolbarActions = try values.decodeIfPresent([TerminalToolbarAction].self, forKey: .toolbarActions) ?? toolbarActions
        customShortcuts = try values.decodeIfPresent([CustomTerminalShortcut].self, forKey: .customShortcuts) ?? customShortcuts
        commandHistory = try values.decodeIfPresent([String].self, forKey: .commandHistory) ?? commandHistory
    }

    func matchesRendering(_ other: TerminalPreferences) -> Bool {
        fontSize == other.fontSize
            && fontName == other.fontName
            && cjkLanguage == other.cjkLanguage
            && ligaturesEnabled == other.ligaturesEnabled
            && theme == other.theme
            && customPalette == other.customPalette
            && scrollbackLines == other.scrollbackLines
            && cursor == other.cursor
            && cursorBlinks == other.cursorBlinks
            && optionAsMeta == other.optionAsMeta
    }
}

/// Fixes a word the recogniser keeps mishearing, e.g. "cloud code" → "claude code".
struct WordReplacement: Codable, Hashable, Identifiable {
    var id = UUID()
    var heard: String
    var replacement: String

    /// Applies each rule as a whole-word, case-insensitive match, in order.
    static func apply(_ rules: [WordReplacement], to text: String) -> String {
        rules.reduce(text) { text, rule in
            let heard = rule.heard.trimmingCharacters(in: .whitespaces)
            guard !heard.isEmpty,
                  let pattern = try? NSRegularExpression(
                      pattern: "\\b\(NSRegularExpression.escapedPattern(for: heard))\\b",
                      options: .caseInsensitive
                  ) else { return text }
            return pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
            )
        }
    }
}
