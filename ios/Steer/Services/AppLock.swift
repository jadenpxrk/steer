import LocalAuthentication
import SwiftUI
import UIKit

@MainActor
final class AppLock: ObservableObject {
    private(set) var errorMessage: String?
    private(set) var authenticating = false
    private var enabled = false
    private var unlocked = false
    private var phase = ScenePhase.inactive
    private var context: LAContext?
    private var attempt = UUID()
    private var curtain: UIWindow?
    private weak var contentWindow: UIWindow?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        for (name, phase) in [(UIApplication.willResignActiveNotification, ScenePhase.inactive),
                              (UIApplication.didEnterBackgroundNotification, .background),
                              (UIApplication.didBecomeActiveNotification, .active)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.update(enabled: self.enabled, phase: phase)
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func attach(to window: UIWindow) {
        guard contentWindow !== window, let scene = window.windowScene else { return }
        contentWindow = window
        curtain?.isHidden = true
        let curtain = UIWindow(windowScene: scene)
        curtain.windowLevel = .alert + 1
        curtain.backgroundColor = .systemBackground
        curtain.rootViewController = UIHostingController(rootView: unlockView)
        self.curtain = curtain
        updateVisibility()
    }

    func update(enabled: Bool, phase: ScenePhase) {
        self.enabled = enabled
        self.phase = phase
        if phase == .background || !enabled {
            unlocked = false
            attempt = UUID()
            context?.invalidate()
            context = nil
            authenticating = false
        }
        updateVisibility()
    }

    func unlock() {
        guard enabled, phase == .active, !authenticating else { return }
        authenticating = true
        errorMessage = nil
        let context = LAContext()
        self.context = context
        let attempt = UUID()
        self.attempt = attempt
        updateVisibility()
        Task {
            do {
                let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Steer to access your terminals.")
                guard self.attempt == attempt else { return }
                unlocked = success
            } catch {
                guard self.attempt == attempt else { return }
                errorMessage = error.localizedDescription
            }
            authenticating = false
            self.context = nil
            updateVisibility()
        }
    }

    private func updateVisibility() {
        let visible = enabled && (phase != .active || !unlocked)
        guard let curtain else { return }
        (curtain.rootViewController as? UIHostingController<AppUnlockView>)?.rootView = unlockView
        if visible {
            if curtain.isHidden { curtain.makeKeyAndVisible() }
        } else if !curtain.isHidden {
            curtain.isHidden = true
            contentWindow?.makeKey()
        }
    }

    private var unlockView: AppUnlockView {
        AppUnlockView(authenticating: authenticating, errorMessage: errorMessage) { [weak self] in self?.unlock() }
    }
}

private struct AppUnlockView: View {
    let authenticating: Bool
    let errorMessage: String?
    let unlock: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill").font(.largeTitle)
            Text("Steer is locked").font(.title2.bold())
            Button("Unlock", systemImage: "faceid", action: unlock)
                .buttonStyle(.borderedProminent)
                .disabled(authenticating)
            if authenticating { ProgressView() }
            if let errorMessage { Text(errorMessage).font(.caption).multilineTextAlignment(.center) }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(Theme.ink)
        .background(Theme.bg.ignoresSafeArea())
    }
}

struct AppLockBridge: UIViewRepresentable {
    let lock: AppLock
    var enabled: Bool
    var phase: ScenePhase

    func makeUIView(context: Context) -> LockAnchor { LockAnchor() }
    func updateUIView(_ view: LockAnchor, context: Context) {
        view.lock = lock
        lock.update(enabled: enabled, phase: phase)
        if let window = view.window { lock.attach(to: window) }
    }

    final class LockAnchor: UIView {
        weak var lock: AppLock?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { lock?.attach(to: window) }
        }
    }
}
