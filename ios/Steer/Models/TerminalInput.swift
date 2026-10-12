import UIKit

/// Binding grammar: keystrokes separated by commas or spaces, each with optional modifiers
/// (`C-`/`Ctrl+`, `M-`/`Opt+`/`Alt+`, `S-`/`Shift+`) and a key: one character (case kept), a named key, or F1–F12.
/// `dash` and `plus` stand for `-` and `+`. `text:…` sends the rest literally. Example: `C-b, S-t`.
enum TerminalBinding {
    static func steps(_ binding: String) throws -> [[UInt8]] {
        if binding.hasPrefix("text:") { return [Array(binding.dropFirst(5).utf8)] }
        let tokens = binding.split(whereSeparator: { $0 == "," || $0 == " " })
        guard !tokens.isEmpty else { throw KeySequenceError.invalid }
        return try tokens.map { try keystroke(String($0)) }
    }

    private static let modifierNames: [(prefix: String, bit: Int)] = [
        ("ctrl+", 4), ("c-", 4), ("opt+", 2), ("alt+", 2), ("m-", 2), ("shift+", 1), ("s-", 1)
    ]

    private static func keystroke(_ token: String) throws -> [UInt8] {
        var key = Substring(token)
        var modifiers = 0
        while let match = modifierNames.first(where: { key.lowercased().hasPrefix($0.prefix) && key.count > $0.prefix.count }) {
            modifiers |= match.bit
            key = key.dropFirst(match.prefix.count)
        }
        let (ctrl, alt, shift) = (modifiers & 4 != 0, modifiers & 2 != 0, modifiers & 1 != 0)
        let name = key.lowercased()
        // Keys that xterm encodes with a modifier parameter when modified.
        let cursor: [String: UInt8] = ["up": 65, "down": 66, "right": 67, "left": 68, "home": 72, "end": 70]
        let tilde: [String: Int] = ["pageup": 5, "pagedown": 6, "delete": 3, "insert": 2,
                                    "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24]
        let ss3: [String: UInt8] = ["f1": 80, "f2": 81, "f3": 82, "f4": 83]
        let parameter = modifiers == 0 ? nil : modifiers + 1
        if let final = cursor[name] {
            return parameter.map { Array("\u{1b}[1;\($0)".utf8) + [final] } ?? [27, 91, final]
        }
        if let code = tilde[name] {
            return Array("\u{1b}[\(code)\(parameter.map { ";\($0)" } ?? "")~".utf8)
        }
        if let final = ss3[name] {
            return parameter.map { Array("\u{1b}[1;\($0)".utf8) + [final] } ?? [27, 79, final]
        }
        if name == "tab", shift, !ctrl, !alt { return [27, 91, 90] }
        let named: [String: UInt8] = ["tab": 9, "enter": 13, "esc": 27, "space": 32, "bspace": 127, "dash": 45, "plus": 43]
        var character: UInt8
        if let byte = named[name] {
            character = byte
        } else if key.count == 1, let scalar = key.unicodeScalars.first, scalar.isASCII {
            character = UInt8(scalar.value)
        } else {
            throw KeySequenceError.invalid
        }
        if shift, (97...122).contains(character) { character -= 32 }
        if ctrl {
            switch character {
            case 32: character = 0
            case 45: character = 31
            case 63: character = 127
            case 64...95, 97...122: character &= 31
            default: throw KeySequenceError.invalid
            }
        }
        return alt ? [27, character] : [character]
    }
}

/// The `<C-b>1<Enter>` shortcut syntax: text with `<…>` keys.
enum AngleKeySequence {
    static func bytes(_ text: String) throws -> [UInt8] {
        var result: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            guard character == "<" else { result += String(character).utf8; continue }
            if index < text.endIndex, text[index] == "<" {
                result.append(60)
                index = text.index(after: index)
                continue
            }
            guard let end = text[index...].firstIndex(of: ">") else { throw KeySequenceError.invalid }
            let rawKey = String(text[index..<end])
            let key = rawKey.lowercased()
            index = text.index(after: end)
            let named: [String: [UInt8]] = [
                "esc": [27], "enter": [13], "tab": [9], "backspace": [127], "space": [32],
                "up": [27, 91, 65], "down": [27, 91, 66], "right": [27, 91, 67], "left": [27, 91, 68],
                "home": [27, 91, 72], "end": [27, 91, 70], "delete": [27, 91, 51, 126],
                "pageup": [27, 91, 53, 126], "pagedown": [27, 91, 54, 126], "s-tab": [27, 91, 90]
            ]
            if let bytes = named[key] { result += bytes }
            else if key.hasPrefix("c-"), key.utf8.count == 3, let ascii = key.utf8.last, (64...127).contains(ascii) {
                result.append(ascii == 127 ? 127 : ascii & 31)
            } else if key.hasPrefix("m-"), key.count == 3 {
                result.append(27)
                result += rawKey.suffix(1).utf8
            } else { throw KeySequenceError.invalid }
        }
        return result
    }
}

enum KeySequenceError: LocalizedError {
    case invalid
    var errorDescription: String? { "Use keys such as C-c, C-b, S-t, F12, h, S-Tab, or text:/clear." }
}

extension CustomTerminalShortcut {
    /// Keystrokes to send in order; advanced bindings are sent one step at a time.
    var steps: [[UInt8]] {
        get throws {
            var steps: [[UInt8]]
            switch (keySequence, bindingSyntax) {
            case (true, true): steps = try TerminalBinding.steps(text)
            case (true, _): steps = [try AngleKeySequence.bytes(text)]
            default: steps = [Array(text.utf8)]
            }
            if appendReturn { steps.append([13]) }
            return steps
        }
    }

    /// Sends each step with a short pause so multiplexer prefixes register.
    @MainActor
    func send(via send: @escaping @MainActor (ArraySlice<UInt8>) -> Bool) -> Bool {
        guard let steps = try? steps, let first = steps.first, send(first[...]) else { return false }
        guard steps.count > 1 else { return true }
        Task { @MainActor in
            for step in steps.dropFirst() {
                try? await Task.sleep(for: .milliseconds(50))
                _ = send(step[...])
            }
        }
        return true
    }
}

/// What a gesture or D-pad slot can do. The terminal canvas and the D-pad both run actions through here.
struct TerminalActionHandlers {
    var send: @MainActor (ArraySlice<UInt8>) -> Bool
    var openShortcuts: () -> Void
    var muxCycle: (Int) -> Void
    var toggleKeyboard: () -> Void
    var armControl: () -> Void
    var armRightClick: () -> Void
}

enum TerminalGesture: String, CaseIterable, Identifiable {
    case left, right, up, down, tap, volumeUp, volumeDown, dpadTopLeft, dpadTopRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tap: "Two-finger tap"
        case .volumeUp: "Volume up button"
        case .volumeDown: "Volume down button"
        case .dpadTopLeft: "D-pad top-left"
        case .dpadTopRight: "D-pad top-right"
        case .left, .right, .up, .down: "Two-finger swipe " + rawValue
        }
    }
}

enum TerminalGestureAction: Codable, Hashable {
    case none, shortcuts, nextTab, previousTab, escape, enter, backspace, interrupt, paste, keyboard, control, rightClick
    case shortcut(UUID)
    static let builtIn: [Self] = [.none, .shortcuts, .nextTab, .previousTab, .escape, .enter, .backspace, .interrupt, .paste, .keyboard, .control, .rightClick]
    var title: String {
        switch self {
        case .none: "None"
        case .shortcuts: "Open shortcuts"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .escape: "Escape"
        case .enter: "Enter"
        case .backspace: "Backspace"
        case .interrupt: "Interrupt (Ctrl-C)"
        case .paste: "Paste"
        case .keyboard: "Toggle keyboard"
        case .control: "Arm Ctrl"
        case .rightClick: "Arm right click"
        case .shortcut: "Custom shortcut"
        }
    }
}

extension TerminalGestureAction {
    @MainActor
    func perform(shortcuts: [CustomTerminalShortcut], _ handlers: TerminalActionHandlers) {
        switch self {
        case .none: break
        case .shortcuts: handlers.openShortcuts()
        case .nextTab: handlers.muxCycle(1)
        case .previousTab: handlers.muxCycle(-1)
        case .escape: _ = handlers.send([27][...])
        case .enter: _ = handlers.send([13][...])
        case .backspace: _ = handlers.send([127][...])
        case .interrupt: _ = handlers.send([3][...])
        case .paste:
            if let text = UIPasteboard.general.string { _ = handlers.send(Array(text.utf8)[...]) }
        case .keyboard: handlers.toggleKeyboard()
        case .control: handlers.armControl()
        case .rightClick: handlers.armRightClick()
        case .shortcut(let id):
            _ = shortcuts.first(where: { $0.id == id })?.send(via: handlers.send)
        }
    }
}

extension TerminalPreferences {
    func action(for gesture: TerminalGesture) -> TerminalGestureAction {
        if let action = gestureBindings[gesture.rawValue] { return action }
        switch gesture {
        case .left: return twoFingerMuxSwipe ? .nextTab : .none
        case .right: return twoFingerMuxSwipe ? .previousTab : .none
        case .tap: return twoFingerTapShortcuts ? .shortcuts : .none
        case .dpadTopLeft: return .interrupt
        case .dpadTopRight: return .backspace
        case .up, .down, .volumeUp, .volumeDown: return .none
        }
    }
}
