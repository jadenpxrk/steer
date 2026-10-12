import CoreText
import Foundation
import UIKit

struct TerminalFontChoice: Hashable, Identifiable, Sendable {
    var id: String { postScriptName ?? "system" }
    let title: String
    let postScriptName: String?
    let bundledFile: String?
}

enum TerminalFontRegistry {
    static let builtIn: [TerminalFontChoice] = [
        TerminalFontChoice(title: "System Mono", postScriptName: nil, bundledFile: nil),
        TerminalFontChoice(title: "Menlo", postScriptName: "Menlo-Regular", bundledFile: nil),
        TerminalFontChoice(title: "Courier New", postScriptName: "CourierNewPSMT", bundledFile: nil),
        TerminalFontChoice(title: "JetBrains Mono", postScriptName: "JetBrainsMono-Regular", bundledFile: "JetBrainsMono-Regular"),
        TerminalFontChoice(title: "Fira Code", postScriptName: "FiraCode-Regular", bundledFile: "FiraCode-Regular"),
        TerminalFontChoice(title: "IBM Plex Mono", postScriptName: "IBMPlexMono", bundledFile: "IBMPlexMono-Regular"),
        TerminalFontChoice(title: "Source Code Pro", postScriptName: "SourceCodePro-Regular", bundledFile: "SourceCodePro-Regular"),
        TerminalFontChoice(title: "Hack", postScriptName: "Hack-Regular", bundledFile: "Hack-Regular"),
    ]

    static func registerBundledFonts() {
        for choice in builtIn {
            guard let file = choice.bundledFile else { continue }
            if let postScriptName = choice.postScriptName, UIFont(name: postScriptName, size: 12) != nil {
                continue
            }
            let url = Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: file, withExtension: "ttf")
            if let url {
                _ = registerFont(url)
            }
        }
    }

    private static func registerFont(_ url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else {
            return []
        }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }
    }
}
