import SwiftUI
import Testing
import UIKit
@testable import Steer

struct ApplicationAppearanceTests {
    @Test @MainActor func appColorsResolveUsingTheSelectedPalette() {
        var preferences = TerminalPreferences()
        preferences.theme = .light
        let palette = preferences.palette
        let traits = UITraitCollection { $0[SteerPaletteTrait.self] = palette }
        let color = UIColor(Theme.ink).resolvedColor(with: traits)
        var actualRed: CGFloat = 0, expectedRed: CGFloat = 0
        color.getRed(&actualRed, green: nil, blue: nil, alpha: nil)
        palette.foregroundColor.getRed(&expectedRed, green: nil, blue: nil, alpha: nil)
        #expect(abs(actualRed - expectedRed) < 0.01)
    }

    @Test @MainActor func lockCoversContentAndRestoresTheOriginalWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let content = UIWindow(windowScene: scene)
        content.rootViewController = UIViewController()
        content.makeKeyAndVisible()
        defer {
            content.isHidden = true
            previous?.makeKey()
        }
        let lock = AppLock()
        lock.attach(to: content)
        lock.update(enabled: true, phase: .active)
        let curtain = try #require(scene.keyWindow)
        #expect(curtain !== content)
        #expect(curtain.windowLevel > .alert)
        #expect(curtain.backgroundColor != nil)
        lock.update(enabled: true, phase: .background)
        #expect(!curtain.isHidden)
        lock.update(enabled: false, phase: .active)
        #expect(curtain.isHidden)
        #expect(scene.keyWindow === content)
    }
}
