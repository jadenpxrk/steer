import Foundation
import Observation

@MainActor
@Observable
final class TerminalNavigation {
    var jumpTargets: [MuxJumpTarget] = []
    var jumpError: String?
    var jumpIsLoading = false
    var jumpIsFocusing = false
    private(set) var requestedTab: HerdrTab?
    private var isSwitchingTab = false
    private let connection: TerminalConnection
    private let mux: MuxCatalogLoader
    private let live: HerdrLiveAttachment
    @ObservationIgnored var attachedTarget: () -> MuxRow? = { nil }
    @ObservationIgnored var selectedTarget: () -> MuxRow? = { nil }
    @ObservationIgnored var workspaceTarget: () -> MuxRow? = { nil }
    @ObservationIgnored var loadMux: () async -> Void = {}
    @ObservationIgnored var attach: (MuxRow) async throws -> Void = { _ in throw SSHExecError.notConnected }

    init(connection: TerminalConnection, mux: MuxCatalogLoader, live: HerdrLiveAttachment) {
        self.connection = connection
        self.mux = mux
        self.live = live
    }

    private var generation: Int { connection.generation }

    func sessionTitle(target: MuxRow?, hostName: String) -> String {
        guard let target else { return hostName }
        guard let listing = mux.catalog?.listings.first(where: {
            $0.attach.id == target.id || $0.tabs.contains { $0.attach.id == target.id }
        }) else { return target.title }
        let tab = listing.tabs.first { $0.attach.id == target.id }
        return [target.herdrSessionName, listing.title, tab?.title].compactMap { $0 }.joined(separator: " · ")
    }

    var workspaceTabs: [HerdrTab] {
        let attached = workspaceTarget()
        guard case .herdrAgent(let agent) = attached, let workspaceID = agent.workspaceID else {
            return []
        }
        let fromJump = jumpTargets.compactMap { target -> HerdrTab? in
            guard case .herdrTab(let tab) = target, tab.workspaceID == workspaceID, tab.sessionName == agent.sessionName else { return nil }
            return tab
        }
        if !fromJump.isEmpty { return fromJump }
        return mux.catalog?.tabs.filter { $0.workspaceID == workspaceID && $0.sessionName == agent.sessionName } ?? []
    }

    var selectedTabID: String? {
        if let requestedTab { return requestedTab.id }
        if case .herdrAgent(let agent) = selectedTarget() {
            return agent.tabID.map { MuxCommands.herdrTargetID($0, session: agent.sessionName) }
        }
        return nil
    }

    func reset() {
        jumpTargets = []
        jumpError = nil
        jumpIsLoading = false
        jumpIsFocusing = false
        requestedTab = nil
    }

    func switchToTab(_ tab: HerdrTab) async {
        await switchToTab(tab, attach: attachHerdrTab)
    }

    func switchToTab(_ tab: HerdrTab, attach: (HerdrTab) async throws -> Void) async {
        requestedTab = tab
        guard !isSwitchingTab else { return }
        isSwitchingTab = true
        defer { isSwitchingTab = false }
        while let next = requestedTab {
            let token = generation
            do {
                try await attach(next)
            } catch {
                if generation == token { jumpError = TerminalController.pickerMessage(for: error) }
            }
            if requestedTab?.id == next.id { requestedTab = nil }
        }
    }

    private func attachHerdrTab(_ tab: HerdrTab) async throws {
        let token = generation
        let matches: (HerdrAgent) -> Bool = {
            $0.tabID == tab.tabID && $0.workspaceID == tab.workspaceID && $0.sessionName == tab.sessionName
        }
        if mux.catalog?.agents.contains(where: matches) != true {
            await loadMux()
        }
        guard generation == token else { throw CancellationError() }
        guard let agent = mux.catalog?.agents.first(where: { matches($0) && $0.focused })
            ?? mux.catalog?.agents.first(where: matches) else {
            throw MuxDiscoveryError.missingTarget
        }
        let row = MuxRow.herdrAgent(agent)
        guard attachedTarget()?.id != row.id || live.acceptsInput != true else { return }
        jumpError = nil
        try await attach(row)
    }

    func loadJumpTargets() async {
        guard let ssh = connection.readySSH else {
            jumpError = SSHExecError.notConnected.localizedDescription
            jumpTargets = []
            return
        }
        guard let attached = attachedTarget() else {
            jumpError = "Attach to a Herdr or tmux session first."
            jumpTargets = []
            return
        }
        let token = generation
        jumpIsLoading = true
        defer { if generation == token { jumpIsLoading = false } }
        jumpError = nil
        do {
            let targets = try await MuxDiscovery.discoverJumpTargets(for: attached) { command in
                try await ssh.exec(command)
            }
            guard generation == token else { return }
            jumpTargets = targets
        } catch is CancellationError {
            return
        } catch {
            guard generation == token else { return }
            jumpTargets = []
            jumpError = TerminalController.pickerMessage(for: error)
        }
    }

    func focusJumpTarget(_ target: MuxJumpTarget) async throws {
        if case .herdrTab(let tab) = target, case .herdrAgent = attachedTarget() {
            do {
                try await attachHerdrTab(tab)
            } catch {
                if !(error is CancellationError) { jumpError = TerminalController.pickerMessage(for: error) }
                throw error
            }
            return
        }
        guard let ssh = connection.readySSH else {
            jumpError = SSHExecError.notConnected.localizedDescription
            throw SSHExecError.notConnected
        }
        let token = generation
        jumpIsFocusing = true
        jumpError = nil
        do {
            let result = try await ssh.exec(target.focusCommand)
            try MuxDiscovery.requireSuccess(result)
            guard generation == token else { return }
            jumpIsFocusing = false
            if attachedTarget() != nil { await loadJumpTargets() }
        } catch {
            guard generation == token else { throw error }
            jumpIsFocusing = false
            jumpError = TerminalController.pickerMessage(for: error)
            throw error
        }
    }

    /// Runs a Herdr tab change from the sidebar, then refreshes the destinations.
    func runJumpCommand(_ command: String) async {
        guard let ssh = connection.readySSH else {
            jumpError = SSHExecError.notConnected.localizedDescription
            return
        }
        do {
            try MuxDiscovery.requireSuccess(try await ssh.exec(command))
        } catch {
            jumpError = TerminalController.pickerMessage(for: error)
        }
        await loadJumpTargets()
    }

    /// Git state for each sidebar workspace, keyed by workspace id, using its focused pane's directory.
    func workspaceGitSummaries() async -> [String: GitSummary] {
        guard let ssh = connection.readySSH else { return [:] }
        var directories: [String: String] = [:]
        for target in jumpTargets {
            guard case .herdrWorkspace(let workspace) = target else { continue }
            let panes = mux.catalog?.agents.filter { $0.workspaceKey == workspace.id } ?? []
            let pane = panes.first(where: \.focused) ?? panes.first
            if let directory = pane?.foregroundCWD ?? pane?.cwd { directories[workspace.id] = directory }
        }
        guard !directories.isEmpty,
              let result = try? await ssh.exec(RemoteGit.summaryCommand(directories: Array(Set(directories.values)))) else { return [:] }
        let byDirectory = RemoteGit.summaries(from: result.stdout)
        return directories.compactMapValues { byDirectory[$0] }
    }

    func cycleJumpTarget(offset: Int) async {
        guard attachedTarget() != nil, offset != 0 else { return }
        if case .herdrAgent = attachedTarget(), !workspaceTabs.isEmpty {
            let tabs = workspaceTabs
            let currentIndex = tabs.firstIndex { $0.id == selectedTabID } ?? 0
            let nextIndex = ((currentIndex + offset) % tabs.count + tabs.count) % tabs.count
            await switchToTab(tabs[nextIndex])
            return
        }
        if jumpTargets.isEmpty {
            await loadJumpTargets()
        }
        guard !jumpTargets.isEmpty else { return }
        let currentIndex = jumpTargets.firstIndex(where: \.isCurrent) ?? 0
        let nextIndex = (currentIndex + offset + jumpTargets.count) % jumpTargets.count
        try? await focusJumpTarget(jumpTargets[nextIndex])
    }
}
