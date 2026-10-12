import SwiftUI
import UIKit

@main
struct SteerApp: App {
    @UIApplicationDelegateAdaptor(SteerAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appLock = AppLock()
    @StateObject private var hostStore = HostStore()
    @State private var terminalWorkspaceStore = TerminalWorkspaceStore()
    @StateObject private var terminalSettingsStore = TerminalSettingsStore()
    @StateObject private var hostKeys = SSHHostKeyStore.shared

    var body: some Scene {
        WindowGroup {
            HostListView()
                .environmentObject(hostStore)
                .environment(terminalWorkspaceStore)
                .environmentObject(terminalSettingsStore)
                .preferredColorScheme(terminalSettingsStore.preferences.palette.light ? .light : .dark)
                .background(AppPaletteBridge(palette: terminalSettingsStore.preferences.palette))
                .background(AppLockBridge(lock: appLock, enabled: terminalSettingsStore.preferences.lockOnResume, phase: scenePhase))
                .tint(Theme.ink)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    terminalWorkspaceStore.setActive(phase == .active)
                }
                .sheet(isPresented: Binding(get: { hostKeys.pending != nil }, set: { _ in })) {
                    if let request = hostKeys.pending {
                        SSHHostKeyView(request: request) { hostKeys.resolve(accept: $0) }
                    }
                }
        }
    }
}
