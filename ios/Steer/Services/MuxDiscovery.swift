import Foundation

enum MuxCommands {
    private static let userPath = #"PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; "#

    static let herdrSessionList = withUserPath("herdr session list --json")
    static let tmuxList = withUserPath("tmux ls")
    static let zellijList = withUserPath("zellij list-sessions --short --no-formatting")

    static func withUserPath(_ command: String) -> String {
        userPath + command
    }

    static func herdrTargetID(_ target: String, session: String?) -> String {
        guard let session else { return target }
        return "\(session.utf8.count):\(session):\(target)"
    }

    static func herdr(_ arguments: String, session: String?) -> String {
        withUserPath(herdrExecutable(session: session) + " " + arguments)
    }

    private static func herdrExecutable(session: String?) -> String {
        session.map { "herdr --session \(ShellQuote.posixSingle($0))" } ?? "herdr"
    }

    static func herdrPaneRead(_ paneID: String, session: String?, source: String) -> String {
        herdr("pane read \(ShellQuote.posixSingle(paneID)) --source \(source) --format ansi --raw", session: session)
    }

    static func tmuxWindowList(session: String) -> String {
        withUserPath(
            // tmux formats don't expand \t, so fields are colon-separated with the name, which may contain colons, last.
            "tmux list-windows -t \(ShellQuote.posixSingle(session)) -F '#{window_index}:#{window_active}:#{window_name}'"
        )
    }

    static func herdrTabCreate(workspace: String, session: String?) -> String {
        herdr("tab create --workspace \(ShellQuote.posixSingle(workspace)) --focus", session: session)
    }

    static func herdrTabRename(_ tab: String, to label: String, session: String?) -> String {
        herdr("tab rename \(ShellQuote.posixSingle(tab)) \(ShellQuote.posixSingle(label))", session: session)
    }

    static func herdrTabClose(_ tab: String, session: String?) -> String {
        herdr("tab close \(ShellQuote.posixSingle(tab))", session: session)
    }

    static func herdrWorkspaceCreate(session: String?) -> String {
        herdr("workspace create --focus", session: session)
    }

    static func herdrWorkspaceRename(_ workspace: String, to label: String, session: String?) -> String {
        herdr("workspace rename \(ShellQuote.posixSingle(workspace)) \(ShellQuote.posixSingle(label))", session: session)
    }

    static func herdrWorkspaceClose(_ workspace: String, session: String?) -> String {
        herdr("workspace close \(ShellQuote.posixSingle(workspace))", session: session)
    }

    /// A new Git worktree on `branch`, from the repository of `workspace`, opened as its own workspace.
    static func herdrWorktreeCreate(from workspace: String, branch: String, session: String?) -> String {
        herdr("worktree create --workspace \(ShellQuote.posixSingle(workspace)) --branch \(ShellQuote.posixSingle(branch)) --focus",
              session: session)
    }

    static func herdrAgentRename(_ pane: String, to name: String, session: String?) -> String {
        herdr("agent rename \(ShellQuote.posixSingle(pane)) \(ShellQuote.posixSingle(name))", session: session)
    }

    static func herdrControl(target: String, cols: Int, rows: Int, session: String? = nil) -> String {
        herdr(
            "terminal session control \(ShellQuote.posixSingle(target)) --takeover --cols \(max(cols, 1)) --rows \(max(rows, 1))",
            session: session
        )
    }
}

enum MuxDiscoveryError: LocalizedError, Equatable {
    case execRejected
    case execFailed
    case commandMissing
    case invalidJSON
    case missingTarget
    case unusableOutput
    case neitherMuxAvailable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .execRejected:
            return "The SSH server rejected the command."
        case .execFailed:
            return "The remote command failed."
        case .commandMissing:
            return "The required command is not available on the remote host."
        case .invalidJSON:
            return "The remote command returned invalid JSON."
        case .missingTarget:
            return "The remote listing omitted a session target."
        case .unusableOutput:
            return "The remote command returned unusable output."
        case .neitherMuxAvailable:
            return "Herdr, tmux, and Zellij are not available on this host."
        case .timedOut:
            return "Session discovery timed out. Pull to refresh and try again."
        }
    }
}

enum MuxDiscovery {
    static func parseHerdrAgents(_ json: String) throws -> [HerdrAgent] {
        try decodeList(AgentDTO.self, at: ["result", "agents"], in: json).map(herdrAgent(from:))
    }

    static func parseHerdrPanes(_ json: String) throws -> [HerdrAgent] {
        try decodeList(AgentDTO.self, at: ["result", "panes"], in: json).map(herdrAgent(from:))
    }

    static func parseHerdrSessions(_ json: String) throws -> [HerdrSession] {
        try decodeList(SessionDTO.self, at: ["sessions"], in: json).map(herdrSession(from:))
    }

    static func parseTmuxSessions(_ output: String) -> [TmuxSession] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            tmuxSession(from: String(line))
        }
    }

    static func parseZellijSessions(_ output: String) -> [ZellijSession] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.lowercased().contains("no active zellij sessions") else {
                return nil
            }
            return ZellijSession(name: name)
        }
    }

    static func parseHerdrWorkspaces(_ json: String) throws -> [HerdrWorkspace] {
        try decodeList(WorkspaceDTO.self, at: ["result", "workspaces"], in: json).map { workspace in
            let id = workspace.workspaceId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { throw MuxDiscoveryError.missingTarget }
            return HerdrWorkspace(
                workspaceID: id,
                label: emptyToNil(workspace.label),
                number: workspace.number,
                tabCount: workspace.tabCount,
                focused: workspace.focused ?? false
            )
        }
    }

    static func parseHerdrTabs(_ json: String) throws -> [HerdrTab] {
        try decodeList(TabDTO.self, at: ["result", "tabs"], in: json).map { tab in
            let id = tab.tabId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { throw MuxDiscoveryError.missingTarget }
            return HerdrTab(
                tabID: id,
                workspaceID: emptyToNil(tab.workspaceId),
                label: emptyToNil(tab.label),
                number: tab.number,
                focused: tab.focused ?? false
            )
        }
    }

    static func parseTmuxWindows(_ output: String, session: String) -> [TmuxWindow] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let index = Int(fields[0]) else { return nil }
            return TmuxWindow(
                sessionName: session,
                index: index,
                name: String(fields[2]),
                active: fields[1] == "1"
            )
        }
    }

    @MainActor
    static func discover(
        exec: @escaping @MainActor (String) async throws -> SSHExecResult
    ) async throws -> MuxCatalog {
        let result: SSHExecResult
        do {
            result = try await exec(MuxCommands.herdrSessionList)
        } catch {
            throw mapExecError(error)
        }
        if isMissingCommand(result) {
            try Task.checkCancellation()
            return try await discoverTmux(exec: exec)
        }
        let sessions = try parseHerdrSessions(try stdoutForDiscovery(result))
        var catalog = MuxCatalog(agents: [], sessions: sessions, tmux: [])
        for session in sessions where session.isRunning {
            try Task.checkCancellation()
            // Three channels per server; do not fan out across every saved session.
            let panesRequest = Task { try await exec(MuxCommands.herdr("pane list", session: session.name)) }
            let workspaceRequest = Task { try await exec(MuxCommands.herdr("workspace list", session: session.name)) }
            let tabRequest = Task { try await exec(MuxCommands.herdr("tab list", session: session.name)) }
            defer {
                panesRequest.cancel()
                workspaceRequest.cancel()
                tabRequest.cancel()
            }
            do {
                let panes = try parseHerdrPanes(try stdoutForDiscovery(await panesRequest.value))
                let workspaces = try parseHerdrWorkspaces(try stdoutForDiscovery(await workspaceRequest.value))
                let tabs = try parseHerdrTabs(try stdoutForDiscovery(await tabRequest.value))
                catalog.agents += panes.map { pane in
                    var pane = pane
                    pane.sessionName = session.name
                    return pane
                }
                catalog.tabs += tabs.map { tab in
                    var tab = tab
                    tab.sessionName = session.name
                    return tab
                }
                for workspace in workspaces {
                    let key = MuxCommands.herdrTargetID(workspace.workspaceID, session: session.name)
                    catalog.workspaceNames[key] = workspace.label
                        ?? workspace.number.map { "Workspace \($0)" } ?? workspace.workspaceID
                }
            } catch {
                try Task.checkCancellation()
                catalog.unavailableSessions.append(session.name)
            }
        }
        // Hosts often run tmux or Zellij beside Herdr; list those sessions too.
        if let others = try? await discoverTmux(exec: exec) {
            catalog.tmux = others.tmux
            catalog.zellij = others.zellij
        }
        try Task.checkCancellation()
        return catalog
    }

    @MainActor
    static func discoverJumpTargets(
        for attached: MuxRow,
        exec: (String) async throws -> SSHExecResult
    ) async throws -> [MuxJumpTarget] {
        switch attached {
        case .herdrAgent, .herdrSession:
            let workspaceResult = try await exec(MuxCommands.herdr("workspace list", session: attached.herdrSessionName))
            let workspaces = try parseHerdrWorkspaces(try stdoutForDiscovery(workspaceResult))
            try Task.checkCancellation()
            let tabResult = try await exec(MuxCommands.herdr("tab list", session: attached.herdrSessionName))
            let tabs = try parseHerdrTabs(try stdoutForDiscovery(tabResult))
            return workspaces.map { workspace in
                var workspace = workspace
                workspace.sessionName = attached.herdrSessionName
                return MuxJumpTarget.herdrWorkspace(workspace)
            } + tabs.map { tab in
                var tab = tab
                tab.sessionName = attached.herdrSessionName
                return MuxJumpTarget.herdrTab(tab)
            }
        case .tmux(let session):
            let result = try await exec(MuxCommands.tmuxWindowList(session: session.name))
            return parseTmuxWindows(try stdoutForDiscovery(result), session: session.name)
                .map(MuxJumpTarget.tmuxWindow)
        case .zellij:
            return []
        }
    }

    static func requireSuccess(_ result: SSHExecResult) throws {
        _ = try stdoutForDiscovery(result)
    }

    @MainActor
    private static func discoverTmux(
        exec: (String) async throws -> SSHExecResult
    ) async throws -> MuxCatalog {
        let result: SSHExecResult
        do {
            result = try await exec(MuxCommands.tmuxList)
        } catch {
            throw mapExecError(error)
        }
        if isMissingCommand(result) {
            return try await discoverZellij(exec: exec)
        }
        if isTmuxNoServer(result) {
            return MuxCatalog(agents: [], sessions: [], tmux: [])
        }
        let stdout = try stdoutForDiscovery(result)
        return MuxCatalog(
            agents: [],
            sessions: [],
            tmux: parseTmuxSessions(stdout)
        )
    }

    @MainActor
    private static func discoverZellij(
        exec: (String) async throws -> SSHExecResult
    ) async throws -> MuxCatalog {
        let result: SSHExecResult
        do {
            result = try await exec(MuxCommands.zellijList)
        } catch {
            throw mapExecError(error)
        }
        if isMissingCommand(result) {
            throw MuxDiscoveryError.neitherMuxAvailable
        }
        let stdout = try stdoutForDiscovery(result)
        return MuxCatalog(
            agents: [],
            sessions: [],
            tmux: [],
            zellij: parseZellijSessions(stdout)
        )
    }

    static func isTmuxNoServer(_ result: SSHExecResult) -> Bool {
        let blob = (result.stdout + "\n" + result.stderr).lowercased()
        return blob.contains("no server running")
    }

    /// Maps an exec-channel result into stdout for parsers, or a discovery error.
    static func stdoutForDiscovery(_ result: SSHExecResult) throws -> String {
        if isMissingCommand(result) {
            throw MuxDiscoveryError.commandMissing
        }
        if let status = result.exitStatus, status != 0 {
            throw MuxDiscoveryError.execFailed
        }
        return result.stdout
    }

    static func mapExecError(_ error: Error) -> MuxDiscoveryError {
        switch error as? SSHExecError {
        case .rejected:
            return .execRejected
        case .timedOut:
            return .timedOut
        case .notConnected, .failed, .closed, .none:
            return .execFailed
        }
    }

    static func isMissingCommand(_ result: SSHExecResult) -> Bool {
        if result.exitStatus == 127 {
            return true
        }
        let stderr = result.stderr.lowercased()
        if stderr.contains("command not found") {
            return true
        }
        return false
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// Decodes the array at `path` (e.g. `result.tabs`). Bad JSON is `invalidJSON`; a missing array is `unusableOutput`.
    private static func decodeList<Item: Decodable>(_: Item.Type, at path: [String], in json: String) throws -> [Item] {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData(json)) else {
            throw MuxDiscoveryError.invalidJSON
        }
        var node: Any? = root
        for key in path { node = (node as? [String: Any])?[key] }
        guard let array = node as? [Any] else { throw MuxDiscoveryError.unusableOutput }
        do {
            return try decoder.decode([Item].self, from: JSONSerialization.data(withJSONObject: array))
        } catch {
            throw MuxDiscoveryError.invalidJSON
        }
    }

    private static func jsonData(_ json: String) throws -> Data {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw MuxDiscoveryError.invalidJSON
        }
        return data
    }

    private static func herdrAgent(from dto: AgentDTO) throws -> HerdrAgent {
        let paneID = dto.paneId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !paneID.isEmpty else {
            throw MuxDiscoveryError.missingTarget
        }
        return HerdrAgent(
            paneID: paneID,
            agent: dto.agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            status: emptyToNil(dto.agentStatus),
            cwd: emptyToNil(dto.cwd),
            foregroundCWD: emptyToNil(dto.foregroundCwd),
            terminalTitle: emptyToNil(dto.terminalTitle) ?? emptyToNil(dto.terminalTitleStripped),
            focused: dto.focused ?? false,
            workspaceID: emptyToNil(dto.workspaceId),
            tabID: emptyToNil(dto.tabId),
            terminalID: emptyToNil(dto.terminalId)
        )
    }

    private static func herdrSession(from dto: SessionDTO) throws -> HerdrSession {
        let name = dto.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            throw MuxDiscoveryError.missingTarget
        }
        return HerdrSession(
            name: name,
            isRunning: dto.running ?? false,
            isDefault: dto.default ?? false
        )
    }

    private static func tmuxSession(from line: String) -> TmuxSession? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lower = trimmed.lowercased()
        if lower.contains("no server running") { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let rest = trimmed[trimmed.index(after: colon)...]
        guard rest.lowercased().contains("window") else { return nil }
        return TmuxSession(
            name: name,
            windowCount: windowCount(in: rest),
            isAttached: rest.contains("(attached)")
        )
    }

    private static func windowCount(in rest: Substring) -> Int? {
        let parts = rest.split(whereSeparator: { !$0.isNumber })
        guard let first = parts.first, let count = Int(first) else { return nil }
        return count
    }

    private static func emptyToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AgentDTO: Decodable {
    var agent: String?
    var agentStatus: String?
    var cwd: String?
    var focused: Bool?
    var foregroundCwd: String?
    var paneId: String?
    var tabId: String?
    var terminalId: String?
    var terminalTitle: String?
    var terminalTitleStripped: String?
    var workspaceId: String?
}

private struct SessionDTO: Decodable {
    var name: String?
    var running: Bool?
    var `default`: Bool?
}

private struct WorkspaceDTO: Decodable {
    var workspaceId: String?
    var label: String?
    var number: Int?
    var tabCount: Int?
    var focused: Bool?
}

private struct TabDTO: Decodable {
    var tabId: String?
    var workspaceId: String?
    var label: String?
    var number: Int?
    var focused: Bool?
}
