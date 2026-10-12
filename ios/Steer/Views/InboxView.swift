import SwiftUI

struct InboxView: View {
    @EnvironmentObject private var hostStore: HostStore
    @Environment(TerminalWorkspaceStore.self) private var terminalWorkspaceStore
    @Environment(\.dismiss) private var dismiss
    let open: (Host, HerdrAgent) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(hostStore.hosts) { host in
                    if let probe = terminalWorkspaceStore.sessions(for: host.id).first {
                        HostInboxSection(host: host, probe: probe, open: open)
                    } else {
                        Section(host.displayName) {
                            Text("Not connected").foregroundStyle(.secondary)
                            if host.companionEnabled {
                                Button("Connect to agent companion") {
                                    terminalWorkspaceStore.controller(for: host).ensureConnected()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct HostInboxSection: View {
    let host: Host
    var probe: TerminalController
    let open: (Host, HerdrAgent) -> Void
    @State private var usage: [UsageDay] = []

    private var waiting: [HerdrAgent] {
        probe.agentWatcher.statuses
            .filter { $0.status == "blocked" || $0.status == "done" }
            .sorted { $0.status == "blocked" && $1.status != "blocked" }
    }

    var body: some View {
        Section(host.displayName) {
            if host.companionEnabled {
                NavigationLink("Agent conversations and approvals") {
                    AgentSessionsView(controller: probe)
                }
            }
            ForEach(waiting) { agent in
                Button {
                    open(host, agent)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.terminalTitle ?? agent.agent)
                            .lineLimit(1)
                        Text("\(agent.agent) · \(agent.status == "blocked" ? "needs permission" : "finished")")
                            .font(.caption)
                            .foregroundStyle(agent.status == "blocked" ? Color.orange : Color.secondary)
                    }
                }
                .tint(.primary)
            }
            if waiting.isEmpty {
                Text(probe.phase == .connected ? "No agent waiting" : "Not connected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            if !usage.isEmpty {
                UsageRow(title: "Claude today", totals: AgentUsage.totals(usage, since: AgentUsage.utcDate(daysAgo: 0)))
                UsageRow(title: "Claude 7 days", totals: AgentUsage.totals(usage, since: AgentUsage.utcDate(daysAgo: 6)))
            }
        }
        .task(id: probe.phase) {
            usage = (try? await probe.loadUsage()) ?? []
        }
    }
}

private struct UsageRow: View {
    let title: String
    let totals: UsageDay

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            HStack(spacing: 12) {
                stat("out", totals.output)
                stat("in", totals.input)
                stat("cached", totals.cacheRead + totals.cacheWrite)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        HStack(spacing: 3) {
            Text(value, format: .number.notation(.compactName))
            Text(label)
        }
    }
}
