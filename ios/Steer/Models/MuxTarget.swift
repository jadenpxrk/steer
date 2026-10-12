import Foundation

struct HerdrAgent: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { MuxCommands.herdrTargetID(paneID, session: sessionName) }

    /// Stable attach/focus target (`herdr agent attach` / `focus`).
    let paneID: String
    let agent: String
    let status: String?
    let cwd: String?
    let foregroundCWD: String?
    let terminalTitle: String?
    let focused: Bool
    let workspaceID: String?
    let tabID: String?
    let terminalID: String?
    var sessionName: String? = nil

    var workspaceKey: String? {
        workspaceID.map { MuxCommands.herdrTargetID($0, session: sessionName) }
    }
}

struct HerdrSession: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name }

    /// Stable attach target (`herdr session attach`).
    let name: String
    let isRunning: Bool
    let isDefault: Bool
}

struct TmuxSession: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name }

    let name: String
    let windowCount: Int?
    let isAttached: Bool
}

struct ZellijSession: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String { name }

    let name: String
}

struct HerdrWorkspace: Equatable, Hashable, Identifiable, Sendable {
    var id: String { MuxCommands.herdrTargetID(workspaceID, session: sessionName) }

    let workspaceID: String
    let label: String?
    let number: Int?
    let tabCount: Int?
    let focused: Bool
    var sessionName: String? = nil
}

struct HerdrTab: Equatable, Hashable, Identifiable, Sendable {
    var id: String { MuxCommands.herdrTargetID(tabID, session: sessionName) }

    let tabID: String
    let workspaceID: String?
    let label: String?
    let number: Int?
    let focused: Bool

    var sessionName: String? = nil

    func displayTitle(agent: HerdrAgent? = nil) -> String {
        let label = self.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.isMeaningfulName(label) { return label }
        if let title = Self.paneTitle(agent?.terminalTitle), Self.isMeaningfulName(title) {
            return Self.chipTitle(title)
        }
        let agentName = agent?.agent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !agentName.isEmpty {
            return agentName.localizedCapitalized
        }
        return number.map { "Tab \($0)" } ?? "Tab"
    }

    static func isMeaningfulName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count <= 2 {
            return trimmed.contains { $0.isLetter }
        }
        return !trimmed.allSatisfy(\.isNumber)
    }

    static func paneTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        while let first = text.first, !first.isLetter, !first.isNumber {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let dash = text.range(of: " - ", options: .backwards) {
            let suffix = text[dash.upperBound...]
            if suffix.count <= 12 {
                text = String(text[..<dash.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text.isEmpty ? nil : text
    }

    static func chipTitle(_ value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).filter { !$0.isEmpty }
        if words.count >= 3 {
            return words.prefix(3).joined(separator: " ")
        }
        if value.count <= 24 { return value }
        return String(value.prefix(23)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

struct TmuxWindow: Equatable, Hashable, Identifiable, Sendable {
    var id: String { "\(sessionName):\(index)" }

    let sessionName: String
    let index: Int
    let name: String
    let active: Bool
}

struct MuxCatalog: Equatable, Sendable {
    var agents: [HerdrAgent]
    var sessions: [HerdrSession]
    var tmux: [TmuxSession]
    var zellij: [ZellijSession] = []
    var workspaceNames: [String: String] = [:]
    var tabs: [HerdrTab] = []
    var unavailableSessions: [String] = []

    var isEmpty: Bool {
        listings.isEmpty
    }

    var rows: [MuxRow] {
        agents.map(MuxRow.herdrAgent)
            + tmux.map(MuxRow.tmux)
            + zellij.map(MuxRow.zellij)
    }

    var listings: [MuxListing] {
        var workspaceOrder: [String] = []
        var grouped: [String: [HerdrAgent]] = [:]
        var ungrouped: [HerdrAgent] = []
        for agent in agents {
            if let workspaceID = agent.workspaceKey, !workspaceID.isEmpty {
                if grouped[workspaceID] == nil {
                    workspaceOrder.append(workspaceID)
                }
                grouped[workspaceID, default: []].append(agent)
            } else {
                ungrouped.append(agent)
            }
        }

        var result: [MuxListing] = []
        for workspaceID in workspaceOrder {
            let members = grouped[workspaceID] ?? []
            guard let attachAgent = members.first(where: \.focused) ?? members.first else { continue }
            let attach = MuxRow.herdrAgent(attachAgent)
            let listingTabs = Self.listingTabs(
                members: members,
                knownTabs: tabs
            )
            result.append(
                MuxListing(
                    id: "workspace:\(workspaceID)",
                    title: workspaceNames[workspaceID] ?? attach.title,
                    attach: attach,
                    tabs: listingTabs,
                    tabCount: max(listingTabs.count, 1)
                )
            )
        }
        for agent in ungrouped {
            let attach = MuxRow.herdrAgent(agent)
            result.append(MuxListing(id: attach.id, title: attach.title, attach: attach, tabs: [], tabCount: 1))
        }
        for session in tmux {
            let attach = MuxRow.tmux(session)
            result.append(
                MuxListing(
                    id: attach.id,
                    title: attach.title,
                    attach: attach,
                    tabs: [],
                    tabCount: session.windowCount ?? 1
                )
            )
        }
        for session in zellij {
            let attach = MuxRow.zellij(session)
            result.append(MuxListing(id: attach.id, title: attach.title, attach: attach, tabs: [], tabCount: 1))
        }
        return result
    }

    var previewTargets: [MuxRow] {
        var seen = Set<String>()
        return listings.flatMap { [$0.attach] + $0.tabs.map(\.attach) }
            .filter { seen.insert($0.id).inserted }
    }

    var herdrListings: [MuxListing] {
        listings.filter {
            switch $0.attach {
            case .herdrAgent, .herdrSession: true
            default: false
            }
        }
    }

    var tmuxListings: [MuxListing] {
        listings.filter {
            if case .tmux = $0.attach { return true }
            return false
        }
    }

    var zellijListings: [MuxListing] {
        listings.filter {
            if case .zellij = $0.attach { return true }
            return false
        }
    }

    private static func listingTabs(
        members: [HerdrAgent],
        knownTabs: [HerdrTab]
    ) -> [MuxListingTab] {
        guard let first = members.first else { return [] }
        let listed = knownTabs.filter {
            $0.workspaceID == first.workspaceID && $0.sessionName == first.sessionName
        }
        var result = listed.compactMap { tab -> MuxListingTab? in
            guard let agent = members.first(where: { $0.tabID == tab.tabID && $0.focused })
                ?? members.first(where: { $0.tabID == tab.tabID }) else { return nil }
            return MuxListingTab(tab: tab, attach: .herdrAgent(agent))
        }
        var seen = Set(result.map(\.tab.tabID))
        for agent in members {
            guard let tabID = agent.tabID, seen.insert(tabID).inserted else { continue }
            result.append(
                MuxListingTab(
                    tab: HerdrTab(
                        tabID: tabID,
                        workspaceID: agent.workspaceID,
                        label: agent.terminalTitle,
                        number: nil,
                        focused: agent.focused,
                        sessionName: agent.sessionName
                    ),
                    attach: .herdrAgent(agent)
                )
            )
        }
        return result
    }
}

struct MuxListingTab: Equatable, Identifiable, Sendable {
    var id: String { tab.id }
    let tab: HerdrTab
    let attach: MuxRow

    private var agent: HerdrAgent? {
        if case .herdrAgent(let agent) = attach { return agent }
        return nil
    }

    var title: String {
        tab.displayTitle(agent: agent)
    }
}

struct MuxListing: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let attach: MuxRow
    var tabs: [MuxListingTab] = []
    let tabCount: Int
}

struct TerminalPreviewSnapshot: Equatable, Sendable {
    var bytes: [UInt8]
}

enum MuxRow: Codable, Equatable, Hashable, Identifiable, Sendable {
    case herdrAgent(HerdrAgent)
    case herdrSession(HerdrSession)
    case tmux(TmuxSession)
    case zellij(ZellijSession)

    var id: String {
        switch self {
        case .herdrAgent(let agent):
            "agent:\(agent.id)"
        case .herdrSession(let session):
            "session:\(session.name)"
        case .tmux(let session):
            "tmux:\(session.name)"
        case .zellij(let session):
            "zellij:\(session.name)"
        }
    }

    var attachCommand: String {
        switch self {
        case .herdrAgent(let agent):
            MuxCommands.herdr("agent attach \(ShellQuote.posixSingle(agent.paneID)) --takeover", session: agent.sessionName)
        case .herdrSession(let session):
            MuxCommands.withUserPath("herdr session attach \(ShellQuote.posixSingle(session.name))")
        case .tmux(let session):
            MuxCommands.withUserPath("tmux attach -t \(ShellQuote.posixSingle(session.name))")
        case .zellij(let session):
            MuxCommands.withUserPath("zellij attach \(ShellQuote.posixSingle(session.name))")
        }
    }

    var previewCommand: String? {
        switch self {
        case .herdrAgent(let agent):
            MuxCommands.herdrPaneRead(agent.paneID, session: agent.sessionName, source: "visible")
        case .tmux(let session):
            MuxCommands.withUserPath(
                "tmux capture-pane -ept \(ShellQuote.posixSingle(session.name)) -S -12"
            )
        case .herdrSession, .zellij:
            nil
        }
    }

    var paneID: String? {
        switch self {
        case .herdrAgent(let agent): agent.paneID
        case .herdrSession, .tmux, .zellij: nil
        }
    }

    var herdrSessionName: String? {
        switch self {
        case .herdrAgent(let agent): agent.sessionName
        case .herdrSession(let session): session.name
        case .tmux, .zellij: nil
        }
    }

    var isHerdr: Bool {
        switch self {
        case .herdrAgent, .herdrSession: true
        case .tmux, .zellij: false
        }
    }

    var workspaceID: String? {
        switch self {
        case .herdrAgent(let agent): agent.workspaceID
        case .herdrSession, .tmux, .zellij: nil
        }
    }

    var title: String {
        switch self {
        case .herdrAgent(let agent):
            agentWorkspaceName(agent) ?? (agent.agent.isEmpty ? "Agent" : agent.agent)
        case .herdrSession(let session):
            session.name
        case .tmux(let session):
            session.name
        case .zellij(let session):
            session.name
        }
    }

    var subtitle: String? {
        switch self {
        case .herdrAgent(let agent):
            return agent.terminalTitle
        case .herdrSession(let session):
            var parts: [String] = []
            if session.isDefault { parts.append("Default") }
            parts.append(session.isRunning ? "Running" : "Stopped")
            return parts.joined(separator: " · ")
        case .tmux(let session):
            var parts: [String] = []
            if let count = session.windowCount {
                parts.append(count == 1 ? "1 window" : "\(count) windows")
            }
            if session.isAttached { parts.append("Attached") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .zellij:
            return "Zellij session"
        }
    }

    private func agentWorkspaceName(_ agent: HerdrAgent) -> String? {
        if let cwd = agent.cwd ?? agent.foregroundCWD {
            let name = (cwd as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }

        guard let terminalTitle = agent.terminalTitle else { return nil }
        let name = terminalTitle
            .split(separator: "·")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty, name.caseInsensitiveCompare(agent.agent) != .orderedSame else {
            return nil
        }
        return name
    }
}

enum MuxJumpTarget: Equatable, Hashable, Identifiable, Sendable {
    case herdrWorkspace(HerdrWorkspace)
    case herdrTab(HerdrTab)
    case tmuxWindow(TmuxWindow)

    var id: String {
        switch self {
        case .herdrWorkspace(let workspace):
            "workspace:\(workspace.id)"
        case .herdrTab(let tab):
            "tab:\(tab.id)"
        case .tmuxWindow(let window):
            "tmux-window:\(window.id)"
        }
    }

    var focusCommand: String {
        switch self {
        case .herdrWorkspace(let workspace):
            MuxCommands.herdr("workspace focus \(ShellQuote.posixSingle(workspace.workspaceID))", session: workspace.sessionName)
        case .herdrTab(let tab):
            MuxCommands.herdr("tab focus \(ShellQuote.posixSingle(tab.tabID))", session: tab.sessionName)
        case .tmuxWindow(let window):
            MuxCommands.withUserPath(
                "tmux select-window -t \(ShellQuote.posixSingle("\(window.sessionName):\(window.index)"))"
            )
        }
    }

    var title: String {
        switch self {
        case .herdrWorkspace(let workspace):
            workspace.label ?? workspace.number.map { "Workspace \($0)" } ?? "Workspace"
        case .herdrTab(let tab):
            tab.label ?? tab.number.map { "Tab \($0)" } ?? "Tab"
        case .tmuxWindow(let window):
            window.name.isEmpty ? "Window \(window.index)" : window.name
        }
    }

    var subtitle: String? {
        switch self {
        case .herdrWorkspace(let workspace):
            var parts: [String] = []
            if workspace.focused { parts.append("Current") }
            if let tabCount = workspace.tabCount {
                parts.append(tabCount == 1 ? "1 tab" : "\(tabCount) tabs")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .herdrTab(let tab):
            return tab.focused ? "Current" : nil
        case .tmuxWindow(let window):
            return window.active ? "Current · Window \(window.index)" : "Window \(window.index)"
        }
    }

    var isCurrent: Bool {
        switch self {
        case .herdrWorkspace(let workspace): workspace.focused
        case .herdrTab(let tab): tab.focused
        case .tmuxWindow(let window): window.active
        }
    }
}

enum ShellQuote {
    /// POSIX single-quoting so the value is one argv word, including dashes and metacharacters.
    static func posixSingle(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
