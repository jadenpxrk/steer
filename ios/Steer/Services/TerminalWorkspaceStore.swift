import Foundation
import Observation
import Network

@MainActor
@Observable
final class TerminalWorkspaceStore {
    private(set) var recentSessionIDs: [UUID]
    private(set) var controllers: [UUID: TerminalController] = [:]

    private let defaults: UserDefaults
    private let storageKey = "recent-terminal-sessions"
    private let recordsKey = "terminal-session-records"
    private let lastOpenedKey = "last-opened-terminal"
    private var didRestore = false
    private var networkMonitor: NWPathMonitor?
    private var networkMonitorID = UUID()
    private var receivedInitialPath = false

    private struct SavedSession: Codable {
        let id: UUID
        let hostID: UUID
        let mux: MuxRow?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSessionIDs = defaults.stringArray(forKey: storageKey)?.compactMap(UUID.init(uuidString:)) ?? []
    }

    func setActive(_ active: Bool) {
        networkMonitor?.cancel()
        networkMonitor = nil
        networkMonitorID = UUID()
        receivedInitialPath = false
        guard active else { return }
        let monitor = NWPathMonitor()
        let monitorID = networkMonitorID
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.networkMonitorID == monitorID else { return }
                guard self.receivedInitialPath else {
                    self.receivedInitialPath = true
                    return
                }
                guard path.status == .satisfied else { return }
                for controller in self.controllers.values {
                    Task { await controller.recoverConnection() }
                }
            }
        }
        networkMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "app.steer.network"))
    }

    var recentHostIDs: [UUID] {
        var seen = Set<UUID>()
        return recentSessionIDs.compactMap { sessionID in
            guard let hostID = controllers[sessionID]?.host.id, seen.insert(hostID).inserted else {
                return nil
            }
            return hostID
        }
    }

    func controller(for host: Host) -> TerminalController {
        if let existing = sessions(for: host.id).first {
            existing.updateHost(host)
            markRecent(existing.id)
            return existing
        }
        return openNewSession(for: host)
    }

    func session(for host: Host, mux: MuxRow) -> TerminalController {
        for controller in sessions(for: host.id) { controller.updateHost(host) }
        if let existing = sessions(for: host.id).first(where: {
            ($0.pendingMux ?? $0.attachedMux)?.id == mux.id
        }) {
            markRecent(existing.id)
            return existing
        }
        if let idle = sessions(for: host.id).first(where: {
            $0.attachedMux == nil && $0.pendingMux == nil
        }) {
            idle.pendingMux = mux
            markRecent(idle.id)
            return idle
        }
        let controller = openNewSession(for: host)
        controller.pendingMux = mux
        return controller
    }

    func openNewSession(for host: Host) -> TerminalController {
        let controller = TerminalController(host: host)
        controllers[controller.id] = controller
        controller.onTargetChange = { [weak self] in self?.persistRecentSessions() }
        markRecent(controller.id)
        return controller
    }

    func existingController(for sessionID: UUID) -> TerminalController? {
        controllers[sessionID]
    }

    func sessions(for hostID: UUID) -> [TerminalController] {
        let recent = recentSessionIDs.compactMap { controllers[$0] }
        let remaining = controllers.values.filter { !recentSessionIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        return (recent + remaining).filter { $0.host.id == hostID }
    }

    func restore(hosts: [Host]) {
        guard !didRestore else { return }
        didRestore = true
        let saved = defaults.data(forKey: recordsKey)
            .flatMap { try? JSONDecoder().decode([SavedSession].self, from: $0) } ?? []
        for record in saved {
            guard let host = hosts.first(where: { $0.id == record.hostID }) else { continue }
            let controller = TerminalController(host: host, id: record.id)
            controller.pendingMux = record.mux
            controllers[controller.id] = controller
            controller.onTargetChange = { [weak self] in self?.persistRecentSessions() }
        }
        recentSessionIDs.removeAll { controllers[$0] == nil }
        persistRecentSessions()
    }

    func markOpened(_ controller: TerminalController) {
        defaults.set(controller.id.uuidString, forKey: lastOpenedKey)
        markRecent(controller.id)
    }

    var lastOpenedSession: TerminalController? {
        guard let value = defaults.string(forKey: lastOpenedKey), let id = UUID(uuidString: value) else {
            return nil
        }
        return controllers[id]
    }

    func close(sessionID: UUID) {
        controllers[sessionID]?.onTargetChange = nil
        controllers[sessionID]?.disconnect()
        controllers[sessionID] = nil
        recentSessionIDs.removeAll { $0 == sessionID }
        persistRecentSessions()
    }

    func closeSessions(for hostID: UUID) {
        for controller in sessions(for: hostID) {
            close(sessionID: controller.id)
        }
    }

    private func markRecent(_ sessionID: UUID) {
        guard recentSessionIDs.first != sessionID else { return }
        recentSessionIDs.removeAll { $0 == sessionID }
        recentSessionIDs.insert(sessionID, at: 0)
        if recentSessionIDs.count > 12 {
            recentSessionIDs.removeLast(recentSessionIDs.count - 12)
        }
        persistRecentSessions()
    }

    private func persistRecentSessions() {
        defaults.set(recentSessionIDs.map(\.uuidString), forKey: storageKey)
        let records = controllers.values.map {
            SavedSession(id: $0.id, hostID: $0.host.id, mux: $0.pendingMux ?? $0.attachedMux)
        }
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: recordsKey)
        }
    }
}
