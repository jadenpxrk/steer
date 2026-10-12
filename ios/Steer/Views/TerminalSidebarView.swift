import SwiftUI
import UIKit

/// Everything in the attached session: Herdr workspaces with their tabs and agents (status, git), or tmux windows.
/// Slides over the terminal on iPhone; a column beside it on iPad.
struct TerminalSidebarView: View {
    var controller: TerminalController
    /// Set when the sidebar overlays the terminal and should close after a jump.
    var close: (() -> Void)?
    @State private var query = ""
    @State private var git: [String: GitSummary] = [:]
    @State private var collapsed: Set<String> = []
    @State private var prompt: SidebarPrompt?
    @State private var promptText = ""
    @State private var closing: MuxJumpTarget?
    @FocusState private var searchFocused: Bool

    private var navigation: TerminalNavigation { controller.navigation }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            searchField
            content
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .task(id: navigation.jumpTargets) { git = await navigation.workspaceGitSummaries() }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })) {
            TextField(prompt?.placeholder ?? "", text: $promptText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(prompt?.action ?? "OK") { submitPrompt() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            closing.map { if case .herdrWorkspace = $0 { "Close this workspace?" } else { "Close this tab?" } } ?? "",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible,
            presenting: closing
        ) { target in
            Button("Close", role: .destructive) { closeTarget(target) }
        } message: { _ in
            Text("Processes running in it are ended.")
        }
    }

    // MARK: Header and search

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.host.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text("\(controller.host.username)@\(controller.host.hostname)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let workspace = currentWorkspace {
                Menu {
                    Button("New Workspace", systemImage: "rectangle.stack.badge.plus") {
                        run(MuxCommands.herdrWorkspaceCreate(session: workspace.sessionName))
                    }
                    Button("New Tab", systemImage: "plus.square") {
                        run(MuxCommands.herdrTabCreate(workspace: workspace.workspaceID, session: workspace.sessionName))
                    }
                    Button("New Worktree…", systemImage: "arrow.triangle.branch") { ask(.worktree(workspace)) }
                } label: {
                    iconLabel("plus")
                }
                .accessibilityLabel("New")
            }
            Button { Task { await navigation.loadJumpTargets() } } label: { iconLabel("arrow.clockwise") }
                .disabled(navigation.jumpIsLoading)
                .accessibilityLabel("Refresh")
            if let close {
                Button(action: close) { iconLabel("xmark") }
                    .accessibilityLabel("Close Sidebar")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
    }

    private func iconLabel(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search", text: $query)
                .focused($searchFocused)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if controller.attachedMux == nil {
            placeholder("Open a Herdr or tmux session to see its workspaces here.")
        } else if navigation.jumpIsLoading, navigation.jumpTargets.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else if let message = navigation.jumpError, navigation.jumpTargets.isEmpty {
            placeholder(message)
        } else if navigation.jumpTargets.isEmpty {
            placeholder("Nothing to show in this session.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspaces) { workspace in
                        workspaceSection(workspace)
                    }
                    ForEach(windows) { target in
                        row(target, title: target.title, detail: nil, indent: 0, status: nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.immediately)
            if let message = navigation.jumpError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 40)
    }

    @ViewBuilder
    private func workspaceSection(_ workspace: HerdrWorkspace) -> some View {
        let tabs = self.tabs(in: workspace)
        let workspaceMatches = matches(MuxJumpTarget.herdrWorkspace(workspace).title)
        if workspaceMatches || !tabs.isEmpty {
            let isCollapsed = collapsed.contains(workspace.id) && query.isEmpty
            HStack(spacing: 0) {
                Button {
                    if collapsed.contains(workspace.id) { collapsed.remove(workspace.id) } else { collapsed.insert(workspace.id) }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
                row(.herdrWorkspace(workspace), title: MuxJumpTarget.herdrWorkspace(workspace).title,
                    detail: git[workspace.id]?.label, indent: 0, status: nil, bold: true)
            }
            if !isCollapsed {
                ForEach(tabs, id: \.tab.id) { entry in
                    row(.herdrTab(entry.tab), title: entry.title, detail: nil, indent: 24, status: entry.status)
                }
            }
        }
    }

    private func row(
        _ target: MuxJumpTarget, title: String, detail: String?, indent: CGFloat, status: String?, bold: Bool = false
    ) -> some View {
        Button { jump(to: target) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(bold || target.isCurrent ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(target.isCurrent || bold ? Theme.ink : Theme.muted)
                        .lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if status == "blocked" {
                    Circle()
                        .fill(Theme.warn)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Needs you")
                }
            }
            .padding(.leading, 10 + indent)
            .padding(.trailing, 14)
            .frame(minHeight: 40)
            .background(Theme.bg)
            .contentShape(Rectangle())
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverEffectDisabled()
        .disabled(navigation.jumpIsFocusing)
        .contextMenu { actions(for: target) }
    }

    @ViewBuilder
    private func actions(for target: MuxJumpTarget) -> some View {
        switch target {
        case .herdrWorkspace(let workspace):
            Button("New Tab", systemImage: "plus.square") {
                run(MuxCommands.herdrTabCreate(workspace: workspace.workspaceID, session: workspace.sessionName))
            }
            Button("New Worktree…", systemImage: "arrow.triangle.branch") { ask(.worktree(workspace)) }
            Button("Rename…", systemImage: "pencil") { ask(.renameWorkspace(workspace), text: workspace.label ?? "") }
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = workspace.workspaceID }
            Button("Close Workspace", systemImage: "xmark.square", role: .destructive) { closing = target }
        case .herdrTab(let tab):
            Button("Rename Tab…", systemImage: "pencil") { ask(.renameTab(tab), text: tab.label ?? "") }
            if let agent = agent(in: tab) {
                Button("Rename Agent…", systemImage: "person.text.rectangle") { ask(.renameAgent(agent), text: agent.agent) }
            }
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = tab.tabID }
            Button("Close Tab", systemImage: "xmark.square", role: .destructive) { closing = target }
        case .tmuxWindow(let window):
            Button("Copy ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = "\(window.sessionName):\(window.index)" }
        }
    }

    // MARK: Data

    private var workspaces: [HerdrWorkspace] {
        navigation.jumpTargets.compactMap { if case .herdrWorkspace(let workspace) = $0 { workspace } else { nil } }
    }

    private var windows: [MuxJumpTarget] {
        navigation.jumpTargets.filter {
            if case .tmuxWindow = $0 { return matches($0.title) }
            return false
        }
    }

    private var currentWorkspace: HerdrWorkspace? {
        workspaces.first(where: \.focused) ?? workspaces.first
    }

    private struct TabEntry {
        let tab: HerdrTab
        let title: String
        let status: String?
    }

    /// Tabs take their names from Herdr (the tab label, else the agent running in it).
    private func tabs(in workspace: HerdrWorkspace) -> [TabEntry] {
        navigation.jumpTargets.compactMap { target -> TabEntry? in
            guard case .herdrTab(let tab) = target, tab.workspaceID == workspace.workspaceID,
                  tab.sessionName == workspace.sessionName else { return nil }
            let agent = agent(in: tab)
            let title = tab.label ?? agent?.agent ?? MuxJumpTarget.herdrTab(tab).title
            guard matches(title) || matches(MuxJumpTarget.herdrWorkspace(workspace).title) else { return nil }
            return TabEntry(tab: tab, title: title, status: agent?.status)
        }
    }

    private func agent(in tab: HerdrTab) -> HerdrAgent? {
        let agents = controller.agentWatcher.statuses.isEmpty ? controller.mux.catalog?.agents ?? [] : controller.agentWatcher.statuses
        let inTab = agents.filter { $0.tabID == tab.tabID && $0.sessionName == tab.sessionName }
        return inTab.first(where: \.focused) ?? inTab.first
    }

    /// Fragment match, so "log" finds "login-fix".
    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Actions

    private func jump(to target: MuxJumpTarget) {
        searchFocused = false
        Task {
            do {
                try await navigation.focusJumpTarget(target)
                close?()
            } catch {
                // focusJumpTarget reports failures through jumpError, which this view shows.
            }
        }
    }

    private func run(_ command: String) {
        Task { await navigation.runJumpCommand(command) }
    }

    private func closeTarget(_ target: MuxJumpTarget) {
        switch target {
        case .herdrWorkspace(let workspace):
            run(MuxCommands.herdrWorkspaceClose(workspace.workspaceID, session: workspace.sessionName))
        case .herdrTab(let tab):
            run(MuxCommands.herdrTabClose(tab.tabID, session: tab.sessionName))
        case .tmuxWindow:
            break
        }
    }

    private func ask(_ request: SidebarPrompt, text: String = "") {
        promptText = text
        prompt = request
    }

    private func submitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !text.isEmpty else { return }
        switch prompt {
        case .renameWorkspace(let workspace):
            run(MuxCommands.herdrWorkspaceRename(workspace.workspaceID, to: text, session: workspace.sessionName))
        case .renameTab(let tab):
            run(MuxCommands.herdrTabRename(tab.tabID, to: text, session: tab.sessionName))
        case .renameAgent(let agent):
            run(MuxCommands.herdrAgentRename(agent.paneID, to: text, session: agent.sessionName))
        case .worktree(let workspace):
            run(MuxCommands.herdrWorktreeCreate(from: workspace.workspaceID, branch: text, session: workspace.sessionName))
        }
    }
}

private enum SidebarPrompt {
    case renameWorkspace(HerdrWorkspace)
    case renameTab(HerdrTab)
    case renameAgent(HerdrAgent)
    case worktree(HerdrWorkspace)

    var title: String {
        switch self {
        case .renameWorkspace: "Rename Workspace"
        case .renameTab: "Rename Tab"
        case .renameAgent: "Rename Agent"
        case .worktree: "New Worktree"
        }
    }

    var placeholder: String {
        if case .worktree = self { return "Branch name" }
        return "Name"
    }

    var action: String {
        if case .worktree = self { return "Create" }
        return "Rename"
    }
}
