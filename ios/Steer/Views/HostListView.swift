import SwiftUI

struct HostListView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(TerminalWorkspaceStore.self) private var terminalWorkspaceStore
    @EnvironmentObject private var settings: TerminalSettingsStore
    @State private var didRestore = false
    @State private var refreshedHostIDs: Set<UUID> = []
    @State private var showingAddHost = false
    @State private var showingInbox = false
    @State private var editing: Host?
    @State private var browsingHost: Host?
    @State private var path: [HostRoute] = []
    @State private var searchText = ""
    @State private var linkRequest: LinkRequest?
    @State private var pendingDeletion: Set<UUID> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            hostSidebar
                .navigationDestination(for: HostRoute.self) { route in
                    switch route {
                    case .session(let sessionID):
                        if let controller = terminalWorkspaceStore.existingController(for: sessionID) {
                            terminalDestination(for: controller)
                        } else {
                            ContentUnavailableView(
                                "Terminal unavailable",
                                systemImage: "xmark.circle",
                                description: Text("Return to Connections and open this connection again.")
                            )
                        }
                    case .settings:
                        TerminalSettingsView()
                    }
                }
        }
        .steerChrome()
        .task(id: hostStore.hosts) {
            reconcileExternalHostDeletions()
            if !didRestore {
                didRestore = true
                terminalWorkspaceStore.restore(hosts: hostStore.hosts)
                if settings.preferences.reopenLastTerminal,
                   let controller = terminalWorkspaceStore.lastOpenedSession {
                    openSession(controller)
                }
            }
            for host in hostStore.hosts {
                for controller in terminalWorkspaceStore.sessions(for: host.id) {
                    controller.updateHost(host)
                    if controller.phase == .connected {
                        Task { await controller.resolveDeviceName { try await controller.execRemote($0) } }
                    }
                }
            }
            let unrefreshed = hostStore.hosts.filter { !refreshedHostIDs.contains($0.id) }
            guard !unrefreshed.isEmpty else { return }
            await refreshMux(hosts: unrefreshed)
            if !Task.isCancelled {
                refreshedHostIDs.formUnion(unrefreshed.map(\.id))
            }
        }
        .onOpenURL { url in
            guard let link = SteerDeepLink(url: url),
                  let host = hostStore.hosts.first(where: link.matches) else { return }
            linkRequest = LinkRequest(host: host, target: link.target)
        }
        // Any app or web page, or a link tapped in a remote terminal, can open a steer:// link, so it signs in and
        // attaches only once confirmed.
        .confirmationDialog(
            "Open link?",
            isPresented: Binding(get: { linkRequest != nil }, set: { if !$0 { linkRequest = nil } }),
            presenting: linkRequest
        ) { request in
            Button("Connect") {
                if let target = request.target {
                    openMux(request.host, row: target)
                } else {
                    openSession(terminalWorkspaceStore.controller(for: request.host))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $showingAddHost) {
            HostEditorView()
        }
        .confirmationDialog("Delete jump host?", isPresented: Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                deleteHosts(pendingDeletion)
                pendingDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            let dependents = hostStore.hosts.filter { host in
                !pendingDeletion.contains(host.id) && host.jump.map { pendingDeletion.contains($0.id) } == true
            }
            Text("\(dependents.map(\.displayName).joined(separator: ", ")) will connect directly after this jump host is deleted.")
        }
        .sheet(isPresented: $showingInbox) {
            InboxView { host, agent in
                showingInbox = false
                openMux(host, row: .herdrAgent(agent))
            }
        }
        .sheet(item: $editing) { host in
            HostEditorView(host: host)
        }
        .sheet(item: $browsingHost) { host in
            if let probe = sessionController(for: host) {
                ConnectionDrawerView(
                    host: host,
                    probe: probe,
                    openListing: { target in
                        browsingHost = nil
                        openMux(host, row: target)
                    },
                    openRecent: { controller in
                        browsingHost = nil
                        openSession(controller)
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var hostSidebar: some View {
        VStack(spacing: 0) {
            homeTopBar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search workspaces or connections", text: $searchText)
                    .focused($searchFocused)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("workspace-search")
                    // Results filter as you type, so the only thing left is putting the keyboard away, from where the thumb is.
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") { searchFocused = false }
                        }
                    }
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.muted)
                            .frame(width: 32, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)


            ScrollView {
                VStack(spacing: 20) {
                    WorkspaceBrowserView(
                        controllers: hostStore.hosts.compactMap { sessionController(for: $0) },
                        query: searchText,
                        open: { openMux($0, row: $1) }
                    )
                    connectionsCard
                        .padding(.horizontal, 16)
                }
                .padding(.bottom, 84)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await refreshMux(hosts: hostStore.hosts, force: true)
                if !Task.isCancelled { refreshedHostIDs = Set(hostStore.hosts.map(\.id)) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { searchFocused = false })
        }
        .overlay(alignment: .bottomTrailing) { addConnectionButton }
        .background(Theme.bg)
        .navigationTitle("Steer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .steerChrome()
        .onAppear { Task { await refreshMuxPreviews() } }
    }

    private var homeTopBar: some View {
        HStack {
            Image("SteerMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
                .accessibilityLabel("Steer")
            Spacer(minLength: 0)
            Button("Inbox", systemImage: "tray") {
                showingInbox = true
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            Button("Settings", systemImage: "gearshape") {
                openSettings()
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.bg)
    }

    private var connectionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connections")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            if hostStore.hosts.isEmpty {
                Text("Add a connection to find your workspaces.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(hostStore.hosts) { host in connectionRow(host) }
                }
                // Rows carry their own inset so the long-press preview doesn't cut off the status dot.
                .padding(.horizontal, -10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("connections-card")
    }

    private var addConnectionButton: some View {
        Button {
            searchFocused = false
            showingAddHost = true
        } label: {
            Image(systemName: "plus")
                .font(.title2.weight(.medium))
                .foregroundStyle(Theme.bg)
                .frame(width: 52, height: 52)
                .background(Theme.ink, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Connection")
        .accessibilityIdentifier("add-connection")
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private func connectionRow(_ host: Host) -> some View {
        Button {
            terminalWorkspaceStore.controller(for: host).ensureConnected()
            browsingHost = host
        } label: {
            HStack(spacing: 8) {
                if let controller = sessionController(for: host) {
                    ConnectionStatusDot(controller: controller)
                }
                Text(host.displayName)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .background(Theme.surface)
            .contentShape(Rectangle())
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("New Session", systemImage: "plus.rectangle.on.rectangle") {
                openNewSession(host)
            }
            Button("Edit", systemImage: "pencil") { editing = host }
            if !terminalWorkspaceStore.sessions(for: host.id).isEmpty {
                Button("Close Sessions", systemImage: "xmark.circle", role: .destructive) {
                    closeSessions(for: host.id)
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                if let i = hostStore.hosts.firstIndex(of: host) {
                    removeHosts(at: IndexSet(integer: i))
                }
            }
        }
    }

    @ViewBuilder
    private func terminalDestination(for controller: TerminalController) -> some View {
        let sessions = terminalWorkspaceStore.recentSessionIDs.compactMap { terminalWorkspaceStore.existingController(for: $0) }
        TerminalSessionView(controller: controller, onNewSession: {
            openNewSession(controller.host, fromExisting: true)
        }, sessionTitles: sessions.map(\.sessionTitle), onSwitchSession: { index in
            guard sessions.indices.contains(index) else { return }
            openSession(sessions[index])
        }, onCloseSession: { closeSession(controller.id) })
        .id(controller.id)
    }

    private func sessionController(for host: Host) -> TerminalController? {
        terminalWorkspaceStore.sessions(for: host.id).first
    }

    private func openSettings() {
        Task { @MainActor in
            if !path.contains(.settings) {
                path.append(.settings)
            }
        }
    }

    private func refreshMuxPreviews() async {
        for host in hostStore.hosts {
            guard let probe = sessionController(for: host), probe.phase == .connected else { continue }
            await probe.loadMuxPreviews()
        }
    }

    private func refreshMux(hosts: [Host], force: Bool = false) async {
        var refreshes: [Task<Void, Never>] = []
        for host in hosts {
            let probe = terminalWorkspaceStore.controller(for: host)
            probe.onDeviceNameResolved = { [hostStore] original, name in
                guard var saved = hostStore.hosts.first(where: { $0 == original }) else { return }
                saved.name = name
                hostStore.save(saved)
            }
            let refreshConnectedHost = probe.phase == .connected && (force || probe.mux.catalog == nil)
            probe.ensureConnected()
            if refreshConnectedHost {
                refreshes.append(Task { await probe.loadMux() })
            }
        }
        for refresh in refreshes { await refresh.value }
    }

    private func openMux(_ host: Host, row: MuxRow) {
        let catalog = sessionController(for: host)?.mux.catalog
        let controller = terminalWorkspaceStore.session(for: host, mux: row)
        if controller.mux.catalog == nil { controller.mux.catalog = catalog }
        controller.pendingMux = row
        openSession(controller)
        controller.ensureConnected()
    }

    private func removeHosts(at offsets: IndexSet) {
        let ids = Set(offsets.map { hostStore.hosts[$0].id })
        if ids.contains(where: { id in hostStore.dependents(of: id).contains { !ids.contains($0.id) } }) {
            pendingDeletion = ids
        } else {
            deleteHosts(ids)
        }
    }

    private func deleteHosts(_ ids: Set<UUID>) {
        let offsets = IndexSet(hostStore.hosts.indices.filter { ids.contains(hostStore.hosts[$0].id) })
        for id in ids { forgetHostSessions(id) }
        hostStore.remove(at: offsets)
    }

    private func reconcileExternalHostDeletions() {
        let live = Set(hostStore.hosts.map(\.id))
        let stale = Set(terminalWorkspaceStore.controllers.values.map(\.host.id)).subtracting(live)
        for hostID in stale {
            forgetHostSessions(hostID)
        }
        if browsingHost.map({ !live.contains($0.id) }) == true {
            browsingHost = nil
        }
        if editing.map({ !live.contains($0.id) }) == true {
            editing = nil
        }
    }

    private func forgetHostSessions(_ hostID: UUID) {
        path.removeAll { route in
            guard case .session(let sessionID) = route else { return false }
            return terminalWorkspaceStore.existingController(for: sessionID)?.host.id == hostID
        }
        terminalWorkspaceStore.closeSessions(for: hostID)
    }

    private func openNewSession(_ host: Host, fromExisting: Bool = false) {
        openSession(terminalWorkspaceStore.openNewSession(for: host), append: fromExisting)
    }

    private func openSession(_ controller: TerminalController, append: Bool = false) {
        terminalWorkspaceStore.markOpened(controller)
        Task { @MainActor in
            if append {
                path.append(.session(controller.id))
            } else {
                path = [.session(controller.id)]
            }
        }
    }

    private func closeSession(_ sessionID: UUID) {
        path.removeAll { $0 == .session(sessionID) }
        terminalWorkspaceStore.close(sessionID: sessionID)
    }

    private func closeSessions(for hostID: UUID) {
        path.removeAll { route in
            guard case .session(let sessionID) = route else { return false }
            return terminalWorkspaceStore.existingController(for: sessionID)?.host.id == hostID
        }
        terminalWorkspaceStore.closeSessions(for: hostID)
    }
}

private enum HostRoute: Hashable {
    case session(UUID)
    case settings
}

private struct ConnectionStatusDot: View {
    var controller: TerminalController

    var body: some View {
        SteerStatusDot(color: controller.phase.cardColor, pulse: controller.phase == .connected)
            .accessibilityLabel(controller.phase.cardLabel)
    }
}

private enum ConnectionDrawerSection: String, CaseIterable, Identifiable {
    case herdr
    case tmux
    case zellij
    case recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .herdr: "Herdr"
        case .tmux: "tmux"
        case .zellij: "Zellij"
        case .recent: "Recent"
        }
    }
}

private struct ConnectionDrawerView: View {
    @Environment(TerminalWorkspaceStore.self) private var terminalWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let host: Host
    var probe: TerminalController
    let openListing: (MuxRow) -> Void
    let openRecent: (TerminalController) -> Void
    @State private var section: ConnectionDrawerSection = .herdr
    @State private var showingEditor = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.displayName)
                        .font(.headline)
                    Text("\(host.username)@\(host.hostname)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Edit") { showingEditor = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Button("Close") { dismiss() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if visibleSections.count > 1 {
                SteerTabStrip(
                    tabs: visibleSections.map {
                        SteerTabItem(id: $0.id, title: $0.title, isSelected: section == $0)
                    },
                    select: { id in
                        if let next = ConnectionDrawerSection(rawValue: id) {
                            section = next
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Group {
                if probe.phase == .connecting || (probe.mux.isLoading && probe.mux.catalog == nil) {
                    ProgressView()
                        .tint(Theme.accent)
                        .accessibilityLabel("Looking for sessions")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(rows) { row in
                                Button(action: row.action) {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(row.title)
                                                .font(.headline)
                                                .foregroundStyle(Theme.ink)
                                            if let subtitle = row.subtitle {
                                                Text(subtitle)
                                                    .font(.subheadline)
                                                    .foregroundStyle(Theme.muted)
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(Theme.faint)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.bg)
        .steerChrome()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showingEditor) { HostEditorView(host: host) }
        .onAppear { syncSection() }
        .onChange(of: visibleSections) { _, _ in syncSection() }
        .task {
            probe.ensureConnected()
            if probe.phase == .connected, probe.mux.catalog == nil {
                await probe.loadMux()
            }
        }
    }

    private var recents: [TerminalController] {
        terminalWorkspaceStore.sessions(for: host.id).filter {
            $0.attachedMux != nil || $0.pendingMux != nil
        }
    }

    private var visibleSections: [ConnectionDrawerSection] {
        var sections: [ConnectionDrawerSection] = []
        if !(probe.mux.catalog?.herdrListings ?? []).isEmpty { sections.append(.herdr) }
        if !(probe.mux.catalog?.tmuxListings ?? []).isEmpty { sections.append(.tmux) }
        if !(probe.mux.catalog?.zellijListings ?? []).isEmpty { sections.append(.zellij) }
        if !recents.isEmpty { sections.append(.recent) }
        return sections
    }

    private var listings: [MuxListing] {
        switch section {
        case .herdr: probe.mux.catalog?.herdrListings ?? []
        case .tmux: probe.mux.catalog?.tmuxListings ?? []
        case .zellij: probe.mux.catalog?.zellijListings ?? []
        case .recent: []
        }
    }

    private var rows: [DrawerRow] {
        if section == .recent {
            return recents.map { controller in
                DrawerRow(
                    id: controller.id.uuidString,
                    title: controller.sessionTitle,
                    subtitle: controller.phase.cardLabel,
                    action: { openRecent(controller) }
                )
            }
        }
        return listings.flatMap { listing -> [DrawerRow] in
            let membership = [listing.attach.herdrSessionName, listing.title].compactMap { $0 }.joined(separator: " · ")
            if !listing.tabs.isEmpty {
                return listing.tabs.map { tab in
                    DrawerRow(
                        id: tab.attach.id,
                        title: tab.title,
                        subtitle: membership,
                        action: { openListing(tab.attach) }
                    )
                }
            }
            return [DrawerRow(
                id: listing.id,
                title: listing.title,
                subtitle: listing.attach.subtitle,
                action: { openListing(listing.attach) }
            )]
        }
    }

    private var emptyMessage: String {
        if probe.mux.error != nil { return probe.mux.error ?? "Couldn't list sessions." }
        if let names = probe.mux.catalog?.unavailableSessions, !names.isEmpty {
            return "Couldn't load \(names.joined(separator: ", ")). Pull to refresh on the home screen."
        }
        if visibleSections.isEmpty { return "No sessions on this machine." }
        return "Nothing in \(section.title)."
    }

    private func syncSection() {
        if !visibleSections.contains(section) {
            section = visibleSections.first ?? .herdr
        }
    }
}

private struct DrawerRow: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

extension TerminalController.Phase {
    var cardLabel: String {
        switch self {
        case .idle: "Closed"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Reconnect"
        }
    }

    var cardColor: Color {
        switch self {
        case .idle: Theme.faint
        case .connecting: Theme.warn
        case .connected: Theme.ok
        case .failed: Theme.danger
        }
    }
}

private struct LinkRequest {
    let host: Host
    let target: MuxRow?

    var message: String {
        guard let target else { return "Connect to \(host.displayName)?" }
        let takeover = target.isHerdr ? " This takes the pane over from any other client." : ""
        return "Connect to \(host.displayName) and open \(target.title)?" + takeover
    }
}
