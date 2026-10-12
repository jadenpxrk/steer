import GameController
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalSessionView: View {
    @EnvironmentObject private var settings: TerminalSettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var controller: TerminalController
    var onNewSession: () -> Void = {}
    var sessionTitles: [String] = []
    var onSwitchSession: (Int) -> Void = { _ in }
    var onCloseSession: () -> Void = {}
    @State private var showingSidebar = false
    /// iPad: the sidebar is a column that stays open unless closed.
    @AppStorage("terminal-sidebar-pinned") private var sidebarPinned = true
    private var sidebarVisible: Bool { horizontalSizeClass == .regular ? sidebarPinned : showingSidebar }
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var pendingLink: URL?
    @State private var showingShortcutPanel = false
    @State private var showingRemoteTools = false
    @State private var showingConversations = false
    /// Per visit, never saved, so every visit opens with the back button.
    @State private var zen = false
    @State private var showingChatBubble = false
    @State private var showingArrowPad = false
    @State private var terminalView: TerminalView?
    @State private var arrowKeyFrame: CGRect = .zero
    @State private var chatDraft = ""
    @State private var shortcutPanelSection = TerminalShortcutPanelSection.favorites
    @State private var hardwareKeyboard = GCKeyboard.coalesced != nil

    var body: some View {
        @Bindable var navigation = controller.navigation
        VStack(spacing: 0) {
            if zen {
                Color.clear.frame(height: 28) // room for the Zen handle so it never covers output
            } else {
                sessionStatusBar
                if controller.workspaceTabs.count > 1 {
                    workspaceTabBar
                }
            }
            ZStack {
                terminalCanvas
                if !controller.isTerminalReady {
                    Theme.bg
                }
                if controller.phase == .connecting
                    || (!controller.isTerminalReady && (controller.muxIsAttaching || controller.muxAttachError == nil)) {
                    ProgressView()
                        .controlSize(.regular)
                        .accessibilityLabel("Connecting")
                }
                KeyboardGate(
                    isOpen: $controller.isKeyboardOpen,
                    onSend: { controller.sendFromTerminal($0) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Docked below the terminal, which shrinks to make room, so the agent's last lines stay visible.
            if showingChatBubble {
                TerminalComposer(controller: controller, draft: $chatDraft)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !zen, !(hardwareKeyboard && settings.preferences.hideToolbarWithHardwareKeyboard) {
                TerminalAccessoryBar(
                    preferences: settings.preferences,
                    isControlArmed: controller.isControlArmed,
                    isRightClickArmed: controller.isRightClickArmed,
                    isKeyboardOpen: controller.isKeyboardOpen,
                    isChatOpen: showingChatBubble,
                    isArrowsOpen: showingArrowPad,
                    toggleControl: controller.toggleControl,
                    toggleRightClick: { controller.isRightClickArmed.toggle() },
                    toggleKeyboard: {
                        withAnimation(.snappy(duration: 0.24)) {
                            showingChatBubble = false
                            showingArrowPad = false
                        }
                        controller.toggleKeyboard()
                    },
                    toggleChat: {
                        controller.hideKeyboard()
                        withAnimation(.snappy(duration: 0.24)) {
                            showingArrowPad = false
                            showingChatBubble.toggle()
                        }
                    },
                    toggleArrows: {
                        showingChatBubble = false
                        withAnimation(.snappy(duration: 0.24)) {
                            showingArrowPad.toggle()
                        }
                    },
                    send: { _ = controller.send($0) },
                    paste: paste,
                    showHistory: {
                        shortcutPanelSection = .history
                        showingShortcutPanel = true
                    },
                    showShortcuts: {
                        shortcutPanelSection = .favorites
                        showingShortcutPanel = true
                    },
                    showSessions: { dismiss() },
                    showJump: toggleSidebar,
                    canShowSessions: controller.phase == .connected,
                    canShowJump: controller.phase == .connected
                )
            }
        }
        .safeAreaInset(edge: .leading, spacing: 0) {
            if horizontalSizeClass == .regular, sidebarPinned {
                HStack(spacing: 0) {
                    TerminalSidebarView(controller: controller).frame(width: 300)
                    Divider()
                }
            }
        }
        .overlay {
            if zen { ZenOverlay(phase: controller.phase, actions: zenActions) }
        }
        .overlay(alignment: .leading) {
            if horizontalSizeClass != .regular, showingSidebar {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture { toggleSidebar() }
                            .accessibilityHidden(true)
                        TerminalSidebarView(controller: controller, close: toggleSidebar)
                            .frame(width: min(340, geometry.size.width * 0.86))
                            .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                            .transition(.move(edge: .leading))
                    }
                }
            }
        }
        .coordinateSpace(name: "sessionChrome")
        .overlay {
            GeometryReader { geometry in
                if arrowKeyFrame != .zero {
                    let centerX = min(max(arrowKeyFrame.midX, 88), geometry.size.width - 88)
                    let centerY = max(88, arrowKeyFrame.minY - 92)
                    ArrowDialView(
                        send: { _ = controller.send($0) },
                        topLeft: settings.preferences.action(for: .dpadTopLeft),
                        topRight: settings.preferences.action(for: .dpadTopRight),
                        perform: { $0.perform(shortcuts: settings.preferences.customShortcuts, actionHandlers) }
                    )
                        .scaleEffect(showingArrowPad || reduceMotion ? 1 : 0.01)
                        .position(
                            x: showingArrowPad || reduceMotion ? centerX : arrowKeyFrame.midX,
                            y: showingArrowPad || reduceMotion ? centerY : arrowKeyFrame.midY
                        )
                        .opacity(showingArrowPad ? 1 : 0)
                        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: showingArrowPad)
                        .allowsHitTesting(showingArrowPad)
                        .accessibilityHidden(!showingArrowPad)
                }
            }
        }
        .onPreferenceChange(ArrowKeyFrameKey.self) { arrowKeyFrame = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in hardwareKeyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidDisconnect)) { _ in
            hardwareKeyboard = GCKeyboard.coalesced != nil
        }
        .steerChrome()
        .navigationTitle(controller.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(zen ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Terminal Actions", systemImage: "ellipsis.circle") {
                    Button("Zen Mode", systemImage: "rectangle.dashed") { zen = true }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Button("Sidebar", systemImage: "sidebar.left", action: toggleSidebar)
                        .keyboardShortcut("j", modifiers: [.command, .shift])
                        .disabled(controller.phase != .connected)
                    Button("Message", systemImage: "bubble.left.and.text.bubble.right") {
                        withAnimation(.snappy(duration: 0.24)) { showingChatBubble = true }
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(controller.phase != .connected)
                    if controller.host.companionEnabled {
                        Button("Claude Conversations", systemImage: "bubble.left.and.bubble.right") {
                            showingConversations = true
                        }
                        .disabled(controller.phase != .connected)
                    }
                    Button("Remote Tools", systemImage: "wrench.and.screwdriver") {
                        showingRemoteTools = true
                    }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(controller.phase != .connected)
                    Button("Shortcuts", systemImage: "command") {
                        shortcutPanelSection = .favorites
                        showingShortcutPanel = true
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    Button("Sessions", systemImage: "rectangle.stack") { dismiss() }
                        .keyboardShortcut("o", modifiers: .command)
                    Button("New Session", systemImage: "plus.rectangle.on.rectangle", action: onNewSession)
                        .keyboardShortcut("n", modifiers: .command)
                    Menu("Switch Session") {
                        ForEach(Array(sessionTitles.prefix(9).enumerated()), id: \.offset) { index, title in
                            Button("\(index + 1). \(title)") { onSwitchSession(index) }
                                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        }
                    }
                    Button("Close Session", systemImage: "xmark.rectangle", role: .destructive, action: onCloseSession)
                        .keyboardShortcut("w", modifiers: .command)
                }
            }
        }
        // An open sidebar shows the error itself.
        .errorAlert("Tabs unavailable", message: sidebarVisible ? .constant(nil) : $navigation.jumpError)
        .confirmationDialog(
            pendingLink?.absoluteString ?? "",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            titleVisibility: .visible,
            presenting: pendingLink
        ) { url in
            Button("Open") { UIApplication.shared.open(url) }
            Button("Copy Link") { UIPasteboard.general.url = url }
        }
        .sheet(isPresented: $showingShortcutPanel) {
            TerminalShortcutPanelView(
                initialSection: shortcutPanelSection,
                sendBytes: { _ = controller.send($0) },
                sendText: sendShortcut,
                showSessions: {
                    showingShortcutPanel = false
                    dismiss()
                },
                showJump: {
                    showingShortcutPanel = false
                    toggleSidebar()
                },
                canShowSessions: controller.phase == .connected,
                canShowJump: controller.phase == .connected
            )
        }
        .sheet(isPresented: $showingRemoteTools) {
            RemoteToolsView(controller: controller)
        }
        .sheet(isPresented: $showingConversations) {
            NavigationStack {
                AgentSessionsView(controller: controller)
                    .toolbar { Button("Done") { showingConversations = false } }
            }
        }
        .task(id: controller.attachedMux?.id) {
            guard controller.attachedMux != nil else { return }
            await controller.navigation.loadJumpTargets()
        }
        .onAppear {
            controller.setTerminalActive(scenePhase == .active)
            if let terminalView { controller.attach(terminalView, replay: false) }
            UIApplication.shared.isIdleTimerDisabled = settings.preferences.keepScreenOn
        }
        .onChange(of: scenePhase) { _, phase in
            controller.setTerminalActive(phase == .active)
        }
        .onChange(of: settings.preferences.keepScreenOn) { _, keepScreenOn in
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onDisappear {
            controller.detach()
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await controller.loadMuxPreviews() }
        }
    }

    @ViewBuilder
    private var sessionStatusBar: some View {
        if controller.phase != .connected {
            // The centered spinner shows connecting.
            if controller.phase != .connecting {
                ConnectionStatusBar(
                    phase: controller.phase,
                    detail: controller.errorMessage,
                    reconnect: controller.reconnect
                )
            }
        } else if let since = controller.silentSince {
            ConnectionStatusBar(
                phase: .failed,
                detail: "Last heard from \(controller.host.displayName) at \(since.formatted(date: .omitted, time: .standard)). Still trying.",
                reconnect: controller.reconnect,
                title: "No contact"
            )
        } else if let message = controller.muxAttachError, !controller.isTerminalReady || controller.failedMux != nil,
                  !controller.muxIsAttaching {
            ConnectionStatusBar(
                phase: .failed,
                detail: message,
                reconnect: { Task { await controller.retryTerminalAttach() } },
                retryTitle: "Retry"
            )
        }
    }

    private var workspaceTabBar: some View {
        let tabs = controller.workspaceTabs
        return SteerTabStrip(
            tabs: tabs.map { tab in
                let agent = controller.mux.catalog?.agents.first {
                    $0.tabID == tab.tabID && $0.workspaceID == tab.workspaceID && $0.sessionName == tab.sessionName
                }
                return SteerTabItem(
                    id: tab.id,
                    title: tab.displayTitle(agent: agent),
                    isSelected: tab.id == controller.selectedTabID
                )
            },
            select: { id in
                guard let tab = tabs.first(where: { $0.id == id }) else { return }
                await controller.navigation.switchToTab(tab)
            }
        )
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }

    private var terminalCanvas: some View {
        TerminalCanvas(
            preferences: settings.preferences,
            onReady: { terminalView = $0; controller.attach($0) },
            onSend: { controller.sendFromTerminal($0) },
            onGestureSend: { _ = controller.send($0) },
            onToggleKeyboard: controller.toggleKeyboard,
            onResize: { controller.resize(cols: $0, rows: $1) },
            onDirectory: controller.recordDirectory,
            onFontSizeChange: { settings.preferences.fontSize = $0 },
            onMuxCycle: { offset in
                Task { await controller.navigation.cycleJumpTarget(offset: offset) }
            },
            onOpenShortcuts: {
                shortcutPanelSection = .favorites
                showingShortcutPanel = true
            },
            onBell: controller.handleBell,
            onLink: { pendingLink = $0 },
            rightClickArmed: controller.isRightClickArmed,
            onRightClickDone: { controller.isRightClickArmed = false },
            onArmControl: controller.toggleControl,
            onArmRightClick: { controller.isRightClickArmed.toggle() }
        )
        .opacity(controller.isTerminalReady ? 1 : 0)
        .allowsHitTesting(controller.isTerminalReady)
        .clipped()
    }



    private var zenActions: [ZenAction] {
        let connected = controller.phase == .connected
        return [
            ZenAction(id: "keyboard", title: "Keyboard", systemImage: "keyboard", action: controller.toggleKeyboard),
            ZenAction(id: "ctrl", title: "Control", systemImage: "control", action: controller.toggleControl),
            ZenAction(id: "esc", title: "Escape", systemImage: "escape") { _ = controller.send([27][...]) },
            ZenAction(id: "tab", title: "Tab", systemImage: "arrow.right.to.line") { _ = controller.send([9][...]) },
            ZenAction(id: "paste", title: "Paste", systemImage: "doc.on.clipboard", action: paste),
            ZenAction(id: "jump", title: "Sidebar", systemImage: "sidebar.left",
                      enabled: connected, action: toggleSidebar),
            ZenAction(id: "chat", title: "Message", systemImage: "bubble.left.and.text.bubble.right",
                      enabled: connected) { showingChatBubble = true },
            ZenAction(id: "exit", title: "Leave Zen Mode", systemImage: "rectangle.expand.vertical") { zen = false },
            ZenAction(id: "back", title: "Sessions", systemImage: "chevron.backward") { dismiss() },
        ]
    }

    private func toggleSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            if horizontalSizeClass == .regular { sidebarPinned.toggle() } else { showingSidebar.toggle() }
        }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        _ = controller.send(Array(text.utf8)[...])
    }

    private func sendShortcut(_ shortcut: CustomTerminalShortcut) {
        guard shortcut.send(via: controller.send) else { return }
        if shortcut.keySequence != true { settings.rememberCommand(shortcut.text) }
    }

    private var actionHandlers: TerminalActionHandlers {
        TerminalActionHandlers(
            send: controller.send,
            openShortcuts: {
                shortcutPanelSection = .favorites
                showingShortcutPanel = true
            },
            muxCycle: { offset in Task { await controller.navigation.cycleJumpTarget(offset: offset) } },
            toggleKeyboard: controller.toggleKeyboard,
            armControl: controller.toggleControl,
            armRightClick: { controller.isRightClickArmed.toggle() }
        )
    }
}

private struct ArrowKeyFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct KeyboardGate: UIViewRepresentable {
    @Binding var isOpen: Bool
    var onSend: (ArraySlice<UInt8>) -> Void

    func makeUIView(context: Context) -> KeyboardGateView {
        let view = KeyboardGateView()
        view.onSend = onSend
        view.onOpenChange = { open in
            if isOpen != open {
                isOpen = open
            }
        }
        return view
    }

    func updateUIView(_ uiView: KeyboardGateView, context: Context) {
        uiView.onSend = onSend
        uiView.onOpenChange = { open in
            if isOpen != open {
                isOpen = open
            }
        }
        uiView.setOpen(isOpen)
    }
}

final class KeyboardGateView: UIView, UIKeyInput {
    var onSend: ((ArraySlice<UInt8>) -> Void)?
    var onOpenChange: ((Bool) -> Void)?
    private var wantsOpen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    var hasText: Bool { false }
    var keyboardType: UIKeyboardType { .asciiCapable }
    var keyboardAppearance: UIKeyboardAppearance = .default
    var autocorrectionType: UITextAutocorrectionType { .no }
    var autocapitalizationType: UITextAutocapitalizationType { .none }
    var spellCheckingType: UITextSpellCheckingType { .no }
    var smartDashesType: UITextSmartDashesType { .no }
    var smartQuotesType: UITextSmartQuotesType { .no }
    var returnKeyType: UIReturnKeyType { .default }
    var textContentType: UITextContentType? { nil }

    func insertText(_ text: String) {
        if text == "\n" {
            onSend?([0x0d][...])
            return
        }
        guard !text.isEmpty else { return }
        onSend?(Array(text.utf8)[...])
    }

    func deleteBackward() {
        onSend?([0x7f][...])
    }

    func setOpen(_ open: Bool) {
        wantsOpen = open
        if open {
            if !isFirstResponder {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.wantsOpen, self.window != nil else { return }
                    if self.becomeFirstResponder() {
                        self.reloadInputViews()
                    }
                }
            }
        } else if isFirstResponder {
            _ = resignFirstResponder()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onOpenChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onOpenChange?(false) }
        return ok
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool { false }
}

private struct ConnectionStatusBar: View {
    let phase: TerminalController.Phase
    var detail: String?
    let reconnect: () -> Void
    var retryTitle: String = "Reconnect"
    var title: String?

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? label)
                    .font(.caption)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if phase == .failed || phase == .idle {
                Button(retryTitle, systemImage: "arrow.clockwise", action: reconnect)
                    .font(.caption)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var label: String {
        switch phase {
        case .idle: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Failed"
        }
    }
}

/// A plain bottom-bar item; armed items get a filled background.
private struct ToolbarItemStyle: ButtonStyle {
    var armed = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(armed ? Theme.bg : Theme.ink)
            .padding(.horizontal, 8)
            .frame(minWidth: 40, minHeight: 40)
            .background(Capsule().fill(armed ? Theme.accent : .clear))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct TerminalAccessoryBar: View {
    let preferences: TerminalPreferences
    let isControlArmed: Bool
    let isRightClickArmed: Bool
    let isKeyboardOpen: Bool
    let isChatOpen: Bool
    let isArrowsOpen: Bool
    let toggleControl: () -> Void
    let toggleRightClick: () -> Void
    let toggleKeyboard: () -> Void
    let toggleChat: () -> Void
    let toggleArrows: () -> Void
    var send: (ArraySlice<UInt8>) -> Void
    let paste: () -> Void
    let showHistory: () -> Void
    let showShortcuts: () -> Void
    let showSessions: () -> Void
    let showJump: () -> Void
    let canShowSessions: Bool
    let canShowJump: Bool

    var body: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(leadingActions) { action in
                        toolbarButton(action)
                    }
                    Button(action: toggleArrows) {
                        Label("Arrows", systemImage: "dpad")
                    }
                    .buttonStyle(ToolbarItemStyle(armed: isArrowsOpen))
                    .background {
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ArrowKeyFrameKey.self,
                                value: geo.frame(in: .named("sessionChrome"))
                            )
                        }
                    }
                    ForEach(trailingActions) { action in
                        toolbarButton(action)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            Button(action: toggleChat) {
                Label("Chat", systemImage: "bubble.left")
            }
            .buttonStyle(ToolbarItemStyle(armed: isChatOpen))
            Button(action: toggleKeyboard) {
                Label(
                    isKeyboardOpen ? "Hide Keyboard" : "Show Keyboard",
                    systemImage: isKeyboardOpen ? "keyboard.chevron.compact.down" : "keyboard"
                )
            }
            .buttonStyle(ToolbarItemStyle(armed: isKeyboardOpen))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background {
            if preferences.glassToolbar {
                Capsule().fill(.ultraThinMaterial)
            } else {
                Capsule().fill(Theme.surface)
            }
        }
        .overlay { Capsule().stroke(Theme.hairline, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Text keys come before the arrow pad; icon actions follow it.
    private var leadingActions: [TerminalToolbarAction] {
        toolbarActionsWithoutArrows.filter { $0.systemImage == nil }
    }

    private var trailingActions: [TerminalToolbarAction] {
        toolbarActionsWithoutArrows.filter { $0.systemImage != nil }
    }

    private var toolbarActionsWithoutArrows: [TerminalToolbarAction] {
        preferences.toolbarActions.filter { !Self.arrowActions.contains($0) }
    }

    private static let arrowActions: Set<TerminalToolbarAction> = [.left, .up, .down, .right]

    @ViewBuilder
    private func toolbarButton(_ action: TerminalToolbarAction) -> some View {
        Button(action: { perform(action) }) {
            toolbarLabel(action)
        }
        .buttonStyle(
            ToolbarItemStyle(armed: (action == .control && isControlArmed) || (action == .rightClick && isRightClickArmed))
        )
        .disabled((action == .sessions && !canShowSessions) || (action == .jump && !canShowJump))
    }

    @ViewBuilder
    private func toolbarLabel(_ action: TerminalToolbarAction) -> some View {
        if let systemImage = action.systemImage {
            Label(action.title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        } else {
            Text(action.compactTitle)
        }
    }

    private func perform(_ action: TerminalToolbarAction) {
        switch action {
        case .control: toggleControl()
        case .escape: send(Array("\u{1b}".utf8)[...])
        case .tab: send([0x09][...])
        case .enter: send([0x0d][...])
        case .left: send(Array("\u{1b}[D".utf8)[...])
        case .up: send(Array("\u{1b}[A".utf8)[...])
        case .down: send(Array("\u{1b}[B".utf8)[...])
        case .right: send(Array("\u{1b}[C".utf8)[...])
        case .paste: paste()
        case .history: showHistory()
        case .shortcuts: showShortcuts()
        case .sessions: showSessions()
        case .jump: showJump()
        case .rightClick: toggleRightClick()
        }
    }

}
