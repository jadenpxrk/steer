import SwiftTerm
import SwiftUI
import UIKit
import CoreText

struct TerminalCanvas: UIViewRepresentable {
    var preferences: TerminalPreferences
    var onReady: (TerminalView) -> Void
    var onSend: (ArraySlice<UInt8>) -> Void
    var onGestureSend: (ArraySlice<UInt8>) -> Void
    var onToggleKeyboard: () -> Void
    var onResize: (Int, Int) -> Void
    var onDirectory: (String?) -> Void
    var onFontSizeChange: (Double) -> Void
    var onMuxCycle: (Int) -> Void
    var onOpenShortcuts: () -> Void
    var onBell: () -> Void
    var onLink: (URL) -> Void = { _ in }
    var rightClickArmed = false
    var onRightClickDone: () -> Void = {}
    var onArmControl: () -> Void = {}
    var onArmRightClick: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> SteerTerminalView {
        let view = SteerTerminalView(frame: .zero)
        view.inputAccessoryView = nil
        view.accessibilityIdentifier = "terminal"
        view.clipsToBounds = true
        view.alwaysBounceHorizontal = false
        view.showsHorizontalScrollIndicator = false
        view.isDirectionalLockEnabled = true
        view.terminalDelegate = context.coordinator
        context.coordinator.installGestures(on: view)
        configure(view, preferences: preferences)
        context.coordinator.preferences = preferences
        DispatchQueue.main.async { onReady(view) }
        return view
    }

    static func dismantleUIView(_: SteerTerminalView, coordinator: Coordinator) {
        coordinator.stopVolumeButtons()
    }

    func updateUIView(_ uiView: SteerTerminalView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateVolumeButtons(on: uiView, preferences: preferences)
        let previous = context.coordinator.preferences
        context.coordinator.preferences = preferences
        guard previous?.matchesRendering(preferences) != true else { return }
        configure(uiView, preferences: preferences, previous: previous)
    }

    private func configure(_ view: TerminalView, preferences: TerminalPreferences, previous: TerminalPreferences? = nil) {
        let fontChanged = previous.map {
            $0.fontSize != preferences.fontSize
                || $0.fontName != preferences.fontName
                || $0.cjkLanguage != preferences.cjkLanguage
                || $0.ligaturesEnabled != preferences.ligaturesEnabled
        } ?? true
        if fontChanged {
            let size = CGFloat(preferences.fontSize)
            let baseFont = preferences.fontName.flatMap { UIFont(name: $0, size: size) }
                ?? .monospacedSystemFont(ofSize: size, weight: .regular)
            let featureSettings: [[UIFontDescriptor.FeatureKey: Int]] = [[
                .type: kLigaturesType,
                .selector: preferences.ligaturesEnabled
                    ? kCommonLigaturesOnSelector
                    : kCommonLigaturesOffSelector,
            ]]
            var attributes: [UIFontDescriptor.AttributeName: Any] = [.featureSettings: featureSettings]
            if !preferences.cjkLanguage.isEmpty,
               let cascade = CTFontCopyDefaultCascadeListForLanguages(baseFont as CTFont, [preferences.cjkLanguage] as CFArray) as? [CTFontDescriptor] {
                attributes[.cascadeList] = cascade.compactMap { descriptor -> UIFontDescriptor? in
                    guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
                    return UIFontDescriptor(name: name, size: size)
                }
            }
            let descriptor = baseFont.fontDescriptor.addingAttributes(attributes)
            view.font = UIFont(descriptor: descriptor, size: size)
        }
        if previous?.optionAsMeta != preferences.optionAsMeta {
            view.optionAsMetaKey = preferences.optionAsMeta
        }
        if previous?.scrollbackLines != preferences.scrollbackLines {
            view.getTerminal().changeScrollback(preferences.scrollbackLines)
        }
        if previous?.theme != preferences.theme || previous?.customPalette != preferences.customPalette {
            let background = preferences.palette.backgroundColor
            view.nativeForegroundColor = preferences.palette.foregroundColor
            view.nativeBackgroundColor = background
            view.backgroundColor = background
            view.layer.backgroundColor = background.cgColor
            view.caretColor = preferences.palette.cursorColor
        }
        if previous?.cursor != preferences.cursor || previous?.cursorBlinks != preferences.cursorBlinks {
            view.getTerminal().setCursorStyle(preferences.cursor.swiftTermStyle(blinks: preferences.cursorBlinks))
        }
    }

}

struct TerminalSnapshotView: UIViewRepresentable {
    var snapshot: TerminalPreviewSnapshot

    func makeUIView(context: Context) -> SnapshotImageView {
        let view = SnapshotImageView()
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.apply(snapshot)
        return view
    }

    func updateUIView(_ uiView: SnapshotImageView, context: Context) {
        uiView.apply(snapshot)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SnapshotImageView, context: Context) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 168)
    }
}

final class SnapshotImageView: UIView {
    private let imageView = UIImageView()
    private var applied: TerminalPreviewSnapshot?
    private var renderedSize: CGSize = .zero
    private var renderTask: Task<Void, Never>?

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        backgroundColor = UIColor { $0[SteerPaletteTrait.self].backgroundColor }
        registerForTraitChanges([SteerPaletteTrait.self]) { (view: SnapshotImageView, _: UITraitCollection) in
            view.renderedSize = .zero
            view.setNeedsLayout()
        }
        imageView.clipsToBounds = true
        imageView.contentMode = .topLeft
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ snapshot: TerminalPreviewSnapshot) {
        guard applied != snapshot else { return }
        applied = snapshot
        renderedSize = .zero
        setNeedsLayout()
    }

    private func renderIfNeeded() {
        let size = imageView.bounds.size
        guard size.width > 0, size.height > 0, size != renderedSize, let snapshot = applied else { return }
        renderedSize = size
        renderTask?.cancel()
        guard !snapshot.bytes.isEmpty else { imageView.image = nil; return }
        let palette = traitCollection[SteerPaletteTrait.self]
        renderTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let image = AnsiSnapshotRenderer.image(from: snapshot, viewport: size, palette: palette)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.applied == snapshot, self.renderedSize == size else { return }
                self.imageView.image = image
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds.insetBy(dx: 8, dy: 8)
        renderIfNeeded()
    }
}

extension TerminalView {
    func feedHerdrFrames(_ frames: [HerdrTerminalFrame]) {
        let screen = getTerminal()
        var bytes: [UInt8] = []
        for frame in frames where frame.width == screen.cols && frame.height == screen.rows {
            if frame.full {
                bytes = Array("\u{1b}[0m\u{1b}[3J\u{1b}[H\u{1b}[2J".utf8)
            }
            bytes.append(contentsOf: frame.bytes)
        }
        if !bytes.isEmpty { feed(byteArray: bytes[...]) }
    }
}

final class SteerTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }

    /// The visible screen as one string, so VoiceOver and UI tests can read the whole terminal at once.
    override var accessibilityValue: String? {
        get { accessibilityPageContent() }
        set {}
    }

    private var wheelRemainder: CGFloat = 0
    fileprivate var wheelBatch: [UInt8]?
    var onRemoteScroll: ((Int, Int, Int) -> Void)?

    var reportsMouseWheel: Bool {
        onRemoteScroll != nil || (allowMouseReporting && getTerminal().mouseMode != .off)
    }

    /// Cell size in points.
    private var cellPoints: CGSize? {
        let scale = window?.contentScaleFactor ?? 1 // the factor cellSizeInPixels multiplied in
        guard let cell = cellSizeInPixels(source: getTerminal()), cell.width > 0, cell.height > 0 else { return nil }
        return CGSize(width: CGFloat(cell.width) / scale, height: CGFloat(cell.height) / scale)
    }

    /// The OSC 8 or plain-text link under `point` (view coordinates, which include the scroll offset).
    func link(at point: CGPoint) -> String? {
        let terminal = getTerminal()
        guard let cell = cellPoints else { return nil }
        let col = Int(point.x / cell.width)
        let row = Int(point.y / cell.height)
        guard (0..<terminal.cols).contains(col), row >= 0 else { return nil }
        return terminal.link(at: .buffer(Position(col: col, row: row)), mode: .explicitAndImplicit)
    }

    private lazy var predictionView: UIView = {
        let view = UIView()
        view.isUserInteractionEnabled = false
        addSubview(view)
        return view
    }()

    /// Draws Mosh predictions (screen-relative cells) underlined over the terminal, replacing earlier ones.
    func showPredictions(_ cells: [MoshPredictor.Cell]) {
        predictionView.subviews.forEach { $0.removeFromSuperview() }
        guard let cell = cellPoints, !cells.isEmpty else { return }
        let top = CGFloat(getTerminal().buffer.yDisp) * cell.height
        predictionView.frame = CGRect(x: 0, y: top, width: bounds.width, height: CGFloat(getTerminal().rows) * cell.height)
        for prediction in cells {
            let label = UILabel(frame: CGRect(
                x: CGFloat(prediction.col) * cell.width, y: CGFloat(prediction.row) * cell.height,
                width: cell.width, height: cell.height
            ))
            label.attributedText = NSAttributedString(string: String(prediction.character), attributes: [
                .font: font, .foregroundColor: nativeForegroundColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
            label.backgroundColor = nativeBackgroundColor
            predictionView.addSubview(label)
        }
    }

    /// Sends a right-button press and release at `point` when the running app enabled mouse reporting.
    @discardableResult
    func sendRightClick(at point: CGPoint) -> Bool {
        let terminal = getTerminal()
        guard terminal.mouseMode != .off, let cell = cellPoints else { return false }
        let col = min(max(Int(point.x / cell.width), 0), terminal.cols - 1)
        let row = min(max(Int((point.y - contentOffset.y) / cell.height), 0), terminal.rows - 1)
        for release in [false, true] {
            let flags = terminal.encodeButton(button: 2, release: release, shift: false, meta: false, control: false)
            terminal.sendEvent(buttonFlags: flags, x: col, y: row)
        }
        return true
    }

    override func mouseModeChanged(source _: Terminal) {
        // The coordinator handles touch drags as wheel events. Calling super
        // would install SwiftTerm's competing mouse-button drag recognizer.
        resetWheelScroll()
    }

    func resetWheelScroll() {
        wheelRemainder = 0
    }

    func scrollWheel(deltaY: CGFloat, at point: CGPoint) {
        guard reportsMouseWheel, deltaY.isFinite else {
            resetWheelScroll()
            return
        }
        let terminal = getTerminal()
        let scale = max(traitCollection.displayScale, 1)
        guard let cell = cellSizeInPixels(source: terminal), cell.width > 0, cell.height > 0 else { return }
        let cellWidth = CGFloat(cell.width) / scale
        let cellHeight = CGFloat(cell.height) / scale
        wheelRemainder += deltaY
        let lines = Int(wheelRemainder / cellHeight)
        wheelRemainder -= CGFloat(lines) * cellHeight
        guard lines != 0 else { return }
        let x = max(0, min(point.x - bounds.minX, CGFloat(terminal.cols) * cellWidth - 1))
        let y = max(0, min(point.y - bounds.minY, CGFloat(terminal.rows) * cellHeight - 1))
        let flags = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: false, meta: false, control: false)
        let col = Int(x / cellWidth)
        let row = Int(y / cellHeight)
        if let onRemoteScroll {
            onRemoteScroll(lines, col, row)
            return
        }
        let pixelX = Int(x * scale)
        let pixelY = Int(y * scale)
        wheelBatch = []
        for _ in 0..<abs(lines) {
            terminal.sendEvent(buttonFlags: flags, x: col, y: row, pixelX: pixelX, pixelY: pixelY)
        }
        let batch = wheelBatch ?? []
        wheelBatch = nil
        if !batch.isEmpty {
            terminalDelegate?.send(source: self, data: batch[...])
        }
    }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            super.contentSize = CGSize(width: bounds.width, height: newValue.height)
        }
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            super.contentOffset = CGPoint(x: 0, y: newValue.y)
        }
    }

    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        super.setContentOffset(CGPoint(x: 0, y: contentOffset.y), animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = false
        if contentSize.width != bounds.width {
            contentSize = CGSize(width: bounds.width, height: contentSize.height)
        }
        if contentOffset.x != 0 {
            super.setContentOffset(CGPoint(x: 0, y: contentOffset.y), animated: false)
        }
    }
}

final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, UIGestureRecognizerDelegate {
    var parent: TerminalCanvas
    var preferences: TerminalPreferences?
    private var pinchStartFontSize = 14.0
    private weak var wheelPan: UIPanGestureRecognizer?
    private weak var linkTap: UITapGestureRecognizer?
    private weak var rightClickTap: UITapGestureRecognizer?
    private let volumeButtons = VolumeButtonMonitor()
    private var pendingWheelDelta: CGFloat = 0
    private var pendingWheelPoint: CGPoint = .zero
    private var wheelFlushScheduled = false

    init(parent: TerminalCanvas) {
        self.parent = parent
        super.init()
    }

    func installGestures(on view: UIView) {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)

        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 2
            swipe.delegate = self
            view.addGestureRecognizer(swipe)
        }

        let shortcutTap = UITapGestureRecognizer(target: self, action: #selector(handleShortcutTap))
        shortcutTap.numberOfTouchesRequired = 2
        shortcutTap.delegate = self
        view.addGestureRecognizer(shortcutTap)

        if let terminal = view as? SteerTerminalView {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleWheelPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            terminal.addGestureRecognizer(pan)
            terminal.panGestureRecognizer.require(toFail: pan)
            wheelPan = pan

            // SwiftTerm only opens links while the view is first responder, which Steer's terminal never is.
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
            tap.delegate = self
            terminal.addGestureRecognizer(tap)
            linkTap = tap

            let rightClick = UITapGestureRecognizer(target: self, action: #selector(handleRightClickTap(_:)))
            rightClick.delegate = self
            terminal.addGestureRecognizer(rightClick)
            rightClickTap = rightClick
        }
    }

    func updateVolumeButtons(on view: UIView, preferences: TerminalPreferences) {
        let bound = preferences.action(for: .volumeUp) != .none || preferences.action(for: .volumeDown) != .none
        if bound, !volumeButtons.isRunning {
            volumeButtons.onPress = { [weak self] up in
                guard let self else { return }
                perform(self.preferences?.action(for: up ? .volumeUp : .volumeDown) ?? .none)
            }
            volumeButtons.start(in: view)
        } else if !bound {
            volumeButtons.stop()
        }
    }

    func stopVolumeButtons() {
        volumeButtons.stop()
    }

    @objc private func handleRightClickTap(_ recognizer: UITapGestureRecognizer) {
        guard let terminal = recognizer.view as? SteerTerminalView else { return }
        terminal.sendRightClick(at: recognizer.location(in: terminal))
        parent.onRightClickDone()
    }

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        guard let terminal = recognizer.view as? SteerTerminalView,
              let link = terminal.link(at: recognizer.location(in: terminal)) else { return }
        requestOpenLink(source: terminal, link: link, params: [:])
    }

    @objc private func handleWheelPan(_ recognizer: UIPanGestureRecognizer) {
        guard let terminal = recognizer.view as? SteerTerminalView else { return }
        switch recognizer.state {
        case .began:
            terminal.resetWheelScroll()
            pendingWheelDelta = 0
            fallthrough
        case .changed:
            let delta = recognizer.translation(in: terminal).y
            let point = recognizer.location(in: terminal)
            if pendingWheelDelta != 0, (pendingWheelDelta > 0) != (delta > 0) {
                flushWheel(on: terminal)
            }
            pendingWheelDelta += delta
            pendingWheelPoint = point
            recognizer.setTranslation(.zero, in: terminal)
            scheduleWheelFlush(on: terminal)
        case .ended:
            flushWheel(on: terminal)
            terminal.resetWheelScroll()
        case .cancelled, .failed:
            pendingWheelDelta = 0
            wheelFlushScheduled = false
            terminal.resetWheelScroll()
        default:
            break
        }
    }

    private func scheduleWheelFlush(on terminal: SteerTerminalView) {
        guard !wheelFlushScheduled else { return }
        wheelFlushScheduled = true
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, let terminal else { return }
            self.wheelFlushScheduled = false
            self.flushWheel(on: terminal)
        }
    }

    private func flushWheel(on terminal: SteerTerminalView) {
        let delta = pendingWheelDelta
        pendingWheelDelta = 0
        guard delta != 0 else { return }
        terminal.scrollWheel(deltaY: delta, at: pendingWheelPoint)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard preferences?.pinchToResizeFont == true else { return }
        if recognizer.state == .began {
            pinchStartFontSize = preferences?.fontSize ?? 14
        }
        if recognizer.state == .changed || recognizer.state == .ended {
            parent.onFontSizeChange(min(28, max(10, pinchStartFontSize * Double(recognizer.scale))))
        }
    }

    @objc private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let gesture: TerminalGesture = switch recognizer.direction {
        case .left: .left
        case .right: .right
        case .up: .up
        default: .down
        }
        perform(preferences?.action(for: gesture) ?? .none)
    }

    @objc private func handleShortcutTap() {
        perform(preferences?.action(for: .tap) ?? .none)
    }

    private func perform(_ action: TerminalGestureAction) {
        let parent = parent
        action.perform(shortcuts: preferences?.customShortcuts ?? [], TerminalActionHandlers(
            send: { parent.onGestureSend($0); return true },
            openShortcuts: parent.onOpenShortcuts,
            muxCycle: parent.onMuxCycle,
            toggleKeyboard: parent.onToggleKeyboard,
            armControl: parent.onArmControl,
            armRightClick: parent.onArmRightClick
        ))
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === rightClickTap { return parent.rightClickArmed }
        if recognizer === linkTap {
            guard !parent.rightClickArmed, let terminal = recognizer.view as? SteerTerminalView else { return false }
            return terminal.link(at: recognizer.location(in: terminal)) != nil
        }
        if recognizer === wheelPan, let pan = recognizer as? UIPanGestureRecognizer {
            guard let terminal = pan.view as? SteerTerminalView, terminal.reportsMouseWheel else { return false }
            let velocity = pan.velocity(in: terminal)
            return abs(velocity.y) > abs(velocity.x)
        }
        if recognizer is UIPinchGestureRecognizer { return preferences?.pinchToResizeFont == true }
        if let swipe = recognizer as? UISwipeGestureRecognizer {
            let gesture: TerminalGesture = switch swipe.direction {
            case .left: .left
            case .right: .right
            case .up: .up
            default: .down
            }
            return (preferences?.action(for: gesture) ?? .none) != .none
        }
        return (preferences?.action(for: .tap) ?? .none) != .none
    }

    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        recognizer !== wheelPan && other !== wheelPan
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let view = source as? SteerTerminalView, view.wheelBatch != nil {
            view.wheelBatch?.append(contentsOf: data)
            return
        }
        parent.onSend(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        parent.onResize(newCols, newRows)
    }

    func setTerminalTitle(source _: TerminalView, title _: String) {}
    func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
        parent.onDirectory(directory)
    }
    func scrolled(source _: TerminalView, position _: Double) {}
    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        guard let url = TerminalLink.url(from: link) else { return }
        parent.onLink(url)
    }
    func bell(source _: TerminalView) { parent.onBell() }
    func clipboardCopy(source _: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }
    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

private extension TerminalCursor {
    func swiftTermStyle(blinks: Bool) -> CursorStyle {
        switch (self, blinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }
}
