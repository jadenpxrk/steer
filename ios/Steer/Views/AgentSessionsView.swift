import SwiftUI

struct AgentSessionsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var companion: AgentCompanion
    @State private var showArchived = false
    @State private var selection: String?
    @State private var actionError: String?
    @State private var openedInitialSession = false
    @State private var showingNewConversation = false
    private let initialSessionID: String?

    init(controller: TerminalController, initialSessionID: String? = nil) {
        _companion = StateObject(wrappedValue: AgentCompanion(controller: controller))
        self.initialSessionID = initialSessionID
    }

    private var projects: [String] {
        Array(Set(visibleSessions.map(\.cwd))).sorted()
    }

    private var visibleSessions: [CompanionSession] {
        companion.sessions.filter { $0.archived == showArchived }
    }

    var body: some View {
        List {
            if let error = companion.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        companion.controller.ensureConnected()
                        Task { await companion.reset(); await companion.refresh() }
                    }
                }
            }
            Section {
                Toggle("Show archived", isOn: $showArchived)
                    .tint(.green)
            }
            ForEach(projects, id: \.self) { project in
                Section(project.isEmpty ? "Unknown project" : project) {
                    ForEach(visibleSessions.filter { $0.cwd == project }) { session in
                        Button { selection = session.id } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title).foregroundStyle(.primary)
                                Text("\(session.provider.capitalized) · \(session.statusLabel)")
                                    .foregroundStyle(session.status == "waiting" ? Color.orange : Color.secondary)
                                Text(session.id.split(separator: ":").last.map(String.init) ?? session.id)
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(session.archived ? "Unarchive" : "Archive") {
                                Task {
                                    do { try await companion.archive(session) }
                                    catch { actionError = error.localizedDescription }
                                }
                            }
                            .disabled(session.status == "waiting")
                        }
                    }
                }
            }
            if visibleSessions.isEmpty && companion.error == nil {
                HStack {
                    Spacer(minLength: 0)
                    if companion.isLoading {
                        ProgressView("Loading conversations…")
                    } else {
                        ContentUnavailableView(
                            "No conversations",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Start a Claude conversation here, install the Steer hooks, or run Codex on this host.")
                        )
                    }
                    Spacer(minLength: 0)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .navigationTitle("Agent conversations")
        .toolbar {
            Button("New Claude conversation", systemImage: "square.and.pencil") { showingNewConversation = true }
        }
        .sheet(isPresented: $showingNewConversation) {
            NewAgentConversationView(companion: companion) { id in
                showingNewConversation = false
                selection = id
            }
        }
        .navigationDestination(item: $selection) { id in
            AgentConversationView(companion: companion, sessionID: id)
        }
        .refreshable { await companion.refresh() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { await companion.reset(); return }
            companion.controller.ensureConnected()
            while !Task.isCancelled {
                await companion.refresh()
                if !openedInitialSession, let initialSessionID {
                    openedInitialSession = true
                    selection = initialSessionID
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .errorAlert("Could not complete action", message: $actionError)
    }
}

private struct AgentConversationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var companion: AgentCompanion
    let sessionID: String
    @State private var conversation: AgentConversation?
    @State private var errorMessage: String?
    @State private var deciding = false
    @State private var approvalToAllow: CompanionApproval?
    @State private var draft = ""
    @State private var promptID = UUID()
    @State private var lastSubmittedText: String?
    @State private var sending = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.orange)
                }
                if let conversation {
                    Text(conversation.session.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(conversation.session.statusLabel).font(.headline)
                    if let error = conversation.session.error { Text(error).foregroundStyle(.orange) }
                    if let transcriptError = conversation.transcriptError {
                        Text(transcriptError).foregroundStyle(.secondary)
                    }
                    if conversation.truncated {
                        Text("Showing recent messages; long messages may be shortened. Claude token totals cover the loaded transcript only.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    usage(conversation.usage)
                    ForEach(conversation.session.approvals) { approval in
                        VStack(alignment: .leading, spacing: 10) {
                            if let questions = approval.questions {
                                AgentQuestionForm(questions: questions) { answers in
                                    deciding = true
                                    defer { deciding = false }
                                    do {
                                        try await companion.answer(approval, sessionID: sessionID, answers: answers)
                                        await load()
                                    } catch { errorMessage = error.localizedDescription }
                                }
                                .disabled(deciding || approval.expires <= Date())
                            } else {
                                Label("Permission: \(approval.tool)", systemImage: "hand.raised.fill").font(.headline)
                                Text(approval.input).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                HStack {
                                    Button("Deny", role: .destructive) { Task { await decide(approval, allow: false) } }
                                    Button("Allow once") { approvalToAllow = approval }
                                        .buttonStyle(.borderedProminent)
                                }
                                .disabled(deciding || approval.expires <= Date())
                            }
                            Text("Expires \(approval.expires, style: .relative)").font(.caption)
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
                    ForEach(conversation.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.tool ?? message.role.capitalized).font(.caption.bold()).foregroundStyle(.secondary)
                            if message.role == "tool" || message.role == "result" {
                                DisclosureGroup("Details") {
                                    Text(message.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Text(message.text).textSelection(.enabled)
                            }
                        }
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(message.role == "user" ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if conversation.session.managed != true {
                        Text("Send new prompts from the terminal attached to this session. Approvals above target this conversation directly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if errorMessage == nil {
                    ProgressView("Loading conversation…")
                        .frame(maxWidth: .infinity, minHeight: 360, alignment: .center)
                }
            }
            .padding()
        }
        .navigationTitle(conversation?.session.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let conversation, conversation.session.managed == true {
                HStack(alignment: .bottom) {
                    TextField("Message Claude", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(1...6)
                    if conversation.session.canStop == true {
                        Button("Stop", systemImage: "stop.circle") {
                            Task {
                                do { try await companion.stopTurn(sessionID: sessionID); await load() }
                                catch { errorMessage = error.localizedDescription }
                            }
                        }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    } else {
                        Button("Send", systemImage: "arrow.up.circle.fill") { Task { await send() } }
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .disabled(sending || conversation.session.canSend != true || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding().background(Theme.bgElevated)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        .confirmationDialog("Allow this tool request once?", isPresented: Binding(get: { approvalToAllow != nil }, set: { if !$0 { approvalToAllow = nil } }), titleVisibility: .visible) {
            if let approval = approvalToAllow {
                Button("Allow \(approval.tool) once") { Task { await decide(approval, allow: true) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only this request in this session will be approved. No permanent permission is added.")
        }
    }

    private func usage(_ value: AgentConversation.Usage) -> some View {
        DisclosureGroup("Usage") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Input \(value.input.formatted()) · Output \(value.output.formatted())")
                Text("Cache read \(value.cacheRead.formatted()) · Cache write \(value.cacheWrite.formatted())")
                if let used = value.contextUsed {
                    if let limit = value.contextWindow, limit > 0 {
                        ProgressView("Last context: \(used.formatted()) / \(limit.formatted())", value: Double(min(used, limit)), total: Double(limit))
                    } else {
                        Text("Last reported input context: \(used.formatted()) tokens")
                    }
                }
                ForEach(value.rateLimits, id: \.name) { window in
                    Text("\(window.windowMinutes.map { "\($0)-minute window" } ?? window.name): \(window.usedPercent.formatted())% used")
                    if let reset = window.resetsAt {
                        Text("Resets \(Date(timeIntervalSince1970: reset), style: .relative)")
                    }
                }
                Text("Usage is the last snapshot reported in the agent log, not a live account query.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        do {
            conversation = try await companion.conversation(sessionID: sessionID)
            if !deciding { errorMessage = nil }
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            await companion.reset()
        }
    }

    private func decide(_ approval: CompanionApproval, allow: Bool) async {
        deciding = true
        defer { deciding = false }
        do {
            try await companion.decide(approval, sessionID: sessionID, allow: allow)
            errorMessage = nil
            await load()
        } catch {
            await load()
            errorMessage = error.localizedDescription
        }
    }

    private func send() async {
        let text = draft
        if lastSubmittedText != text { promptID = UUID(); lastSubmittedText = text }
        let id = promptID
        sending = true
        defer { sending = false }
        do {
            try await companion.sendPrompt(text, sessionID: sessionID, requestID: id)
            lastSubmittedText = nil
            if draft == text { draft = "" }
            await load()
        } catch {
            await load()
            errorMessage = error.localizedDescription
        }
    }
}

private struct NewAgentConversationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var companion: AgentCompanion
    let created: (String) -> Void
    @State private var directory = ""
    @State private var prompt = ""
    @State private var requestID = UUID()
    @State private var lastRequest: [String]?
    @State private var starting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Project on host") {
                    TextField("Absolute folder path", text: $directory)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Message") {
                    TextField("What should Claude do?", text: $prompt, axis: .vertical).lineLimit(3...10)
                }
                Section {
                    Text("Starts Claude on this host using its existing sign-in and permissions. Steer hooks are required for approval and question controls. Closing this screen does not stop the agent.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.orange) }
                }
            }
            .disabled(starting)
            .navigationTitle("New Claude conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(starting) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(starting ? "Starting…" : "Start") {
                        if lastRequest != [directory, prompt] {
                            requestID = UUID()
                            lastRequest = [directory, prompt]
                        }
                        starting = true
                        Task {
                            defer { starting = false }
                            do {
                                let id = try await companion.createConversation(cwd: directory, text: prompt, requestID: requestID)
                                created(id)
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(starting || !directory.hasPrefix("/") || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { directory = companion.controller.currentDirectory ?? companion.sessions.first?.cwd ?? "" }
            .interactiveDismissDisabled(starting)
        }
    }
}

private struct AgentQuestionForm: View {
    let questions: [CompanionApproval.Question]
    let submit: ([String: String]) async -> Void
    @State private var answers: [String: String] = [:]
    @State private var selected: [String: Set<String>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(questions, id: \.question) { question in
                Text(question.question).font(.headline)
                ForEach(question.options, id: \.self) { option in
                    Button {
                        var values = selected[question.question] ?? []
                        if !question.multiSelect { values = [option] }
                        else if !values.insert(option).inserted { values.remove(option) }
                        selected[question.question] = values
                        answers[question.question] = question.options.filter { values.contains($0) }.joined(separator: ", ")
                    } label: {
                        Label(option, systemImage: selected[question.question]?.contains(option) == true ? "checkmark.circle.fill" : "circle")
                    }
                }
                TextField("Your answer", text: Binding(get: { answers[question.question] ?? "" }, set: {
                    answers[question.question] = $0
                    selected[question.question] = []
                }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
            }
            Button("Send answers") { Task { await submit(answers) } }
                .buttonStyle(.borderedProminent)
                .disabled(questions.contains { (answers[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }
}
