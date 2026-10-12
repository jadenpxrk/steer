import Foundation

enum HerdrSessionError: LocalizedError, Equatable {
    case observeUnavailable
    case observeClosed(String?)
    case streamTruncated
    case paneRequired
    case disconnected

    var errorDescription: String? {
        switch self {
        case .observeUnavailable:
            return "This Herdr version does not support interactive terminal streams."
        case .observeClosed(let reason):
            return reason.flatMap { $0.isEmpty ? nil : $0 } ?? "The terminal stream closed."
        case .streamTruncated:
            return "The terminal stream was truncated. Reconnect to refresh it."
        case .paneRequired:
            return "Choose a workspace tab to open its terminal."
        case .disconnected:
            return "The pane disconnected. Input was not sent to the login shell."
        }
    }
}

struct HerdrTerminalFrame: Equatable, Sendable {
    var seq: Int
    var width: Int
    var height: Int
    var full: Bool
    var bytes: [UInt8]
}

enum HerdrStreamEvent: Equatable, Sendable {
    case frame(HerdrTerminalFrame)
    case closed(String?)
    case ignored
}

struct HerdrStreamParser: Sendable {
    private var buffer = Data()
    private var lastSeq: Int?
    private let maxBuffer = 4 * 1_024 * 1_024

    mutating func push(_ bytes: ArraySlice<UInt8>) -> [HerdrStreamEvent] {
        if buffer.count + bytes.count > maxBuffer {
            buffer.removeAll(keepingCapacity: false)
            return [.closed(HerdrSessionError.streamTruncated.errorDescription)]
        }
        buffer.append(contentsOf: bytes)
        var events: [HerdrStreamEvent] = []
        while let range = buffer.firstRange(of: Data([0x0a])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if let event = decodeLine(line) {
                events.append(event)
            }
        }
        return events
    }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        lastSeq = nil
    }

    private mutating func decodeLine(_ line: Data) -> HerdrStreamEvent? {
        let trimmed = line.trimmingASCIINewlines()
        guard !trimmed.isEmpty else { return nil }
        guard let envelope = try? JSONDecoder().decode(HerdrStreamEnvelope.self, from: trimmed) else {
            if looksLikeCapabilityError(trimmed) {
                return .closed(HerdrSessionError.observeUnavailable.errorDescription)
            }
            return .ignored
        }
        switch envelope.type {
        case "terminal.closed":
            return .closed(envelope.reason)
        case "terminal.frame":
            guard let frame = HerdrTerminalFrame.parse(envelope) else { return .ignored }
            if let lastSeq, frame.seq <= lastSeq { return .ignored }
            if !frame.full {
                guard let lastSeq else { return .ignored }
                guard frame.seq - lastSeq == 1 else {
                    return .closed(HerdrSessionError.streamTruncated.errorDescription)
                }
            }
            lastSeq = frame.seq
            return .frame(frame)
        default:
            return .ignored
        }
    }

    private func looksLikeCapabilityError(_ line: Data) -> Bool {
        let text = String(decoding: line, as: UTF8.self).lowercased()
        return text.contains("unknown")
            || text.contains("unrecognized")
            || text.contains("not found")
            || text.contains("no such command")
    }
}

enum HerdrTerminalCommand {
    static func input(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        Array("{\"type\":\"terminal.input\",\"bytes\":\"\(Data(bytes).base64EncodedString())\"}\n".utf8)
    }

    static func resize(cols: Int, rows: Int) -> [UInt8] {
        Array("{\"type\":\"terminal.resize\",\"cols\":\(max(1, min(cols, 1024))),\"rows\":\(max(1, min(rows, 256)))}\n".utf8)
    }

    static func scroll(lines: Int, column: Int, row: Int) -> [UInt8] {
        let direction = lines > 0 ? "up" : "down"
        let count = abs(max(-65535, min(lines, 65535)))
        guard count > 0 else { return [] }
        return Array("{\"type\":\"terminal.scroll\",\"direction\":\"\(direction)\",\"lines\":\(count),\"source\":\"wheel\",\"column\":\(max(0, column)),\"row\":\(max(0, row))}\n".utf8)
    }

    static let release = Array("{\"type\":\"terminal.release\"}\n".utf8)
}

@MainActor
final class HerdrLiveSession {
    let paneID: String
    let generation: Int
    var parser = HerdrStreamParser()
    var control: SSHExecStream?
    private(set) var cols: Int
    private(set) var rows: Int
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var readyTimeout: Task<Void, Never>?
    private var settled = false
    private(set) var failure: Error?
    private(set) var isDead = false
    private var pendingFrames: [HerdrTerminalFrame] = []
    private var pendingBytes = 0
    private(set) var renderTask: Task<Void, Never>?

    init(paneID: String, generation: Int, cols: Int, rows: Int) {
        self.paneID = paneID
        self.generation = generation
        self.cols = cols
        self.rows = rows
    }

    var acceptsInput: Bool { !isDead && settled && control?.isActive == true }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard acceptsInput else { return }
        for start in stride(from: bytes.startIndex, to: bytes.endIndex, by: 32768) {
            control?.send(HerdrTerminalCommand.input(bytes[start..<min(start + 32768, bytes.endIndex)])[...])
        }
    }

    func resize(cols: Int, rows: Int) {
        guard !isDead, cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        control?.send(HerdrTerminalCommand.resize(cols: cols, rows: rows)[...])
    }

    func scroll(lines: Int, column: Int, row: Int) {
        guard acceptsInput else { return }
        control?.send(HerdrTerminalCommand.scroll(lines: lines, column: column, row: row)[...])
    }

    func enqueue(_ frame: HerdrTerminalFrame) -> Bool {
        guard !isDead else { return false }
        guard pendingFrames.count < 128, pendingBytes + frame.bytes.count <= 4 * 1024 * 1024 else {
            fail(HerdrSessionError.streamTruncated)
            return false
        }
        pendingFrames.append(frame)
        pendingBytes += frame.bytes.count
        markReady()
        return true
    }

    func renderPendingFrames(onFrames: @escaping ([HerdrTerminalFrame]) -> Void) {
        guard !isDead, renderTask == nil else { return }
        renderTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { renderTask = nil }
            while !isDead, !Task.isCancelled, !pendingFrames.isEmpty {
                let frames = pendingFrames
                pendingFrames.removeAll(keepingCapacity: true)
                pendingBytes = 0
                onFrames(frames)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    func markReady() {
        settle(error: nil)
    }

    func fail(_ error: Error) {
        guard !isDead else { return }
        settle(error: error)
        close()
    }

    func waitUntilReady(timeout: Duration) async throws {
        try Task.checkCancellation()
        if let failure { throw failure }
        if settled { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyContinuation = continuation
                readyTimeout = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self.fail(HerdrSessionError.observeUnavailable)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func close() {
        guard !isDead else { return }
        isDead = true
        pendingFrames.removeAll()
        pendingBytes = 0
        renderTask?.cancel()
        readyTimeout?.cancel()
        readyTimeout = nil
        control?.close(sending: HerdrTerminalCommand.release[...])
        control = nil
        if !settled { settle(error: CancellationError()) }
    }

    private func settle(error: Error?) {
        guard !settled else {
            if error != nil { failure = error }
            return
        }
        settled = true
        failure = error
        readyTimeout?.cancel()
        readyTimeout = nil
        if let error {
            readyContinuation?.resume(throwing: error)
        } else {
            readyContinuation?.resume()
        }
        readyContinuation = nil
    }
}

private struct HerdrStreamEnvelope: Decodable {
    var type: String
    var seq: Int?
    var width: Int?
    var height: Int?
    var full: Bool?
    var bytes: String?
    var reason: String?
}

private extension HerdrTerminalFrame {
    static func parse(_ envelope: HerdrStreamEnvelope) -> HerdrTerminalFrame? {
        guard let seq = envelope.seq, seq >= 0,
              let width = envelope.width,
              let height = envelope.height,
              let full = envelope.full,
              let encoded = envelope.bytes else { return nil }
        guard (1...1024).contains(width),
              (1...256).contains(height),
              width <= (1024 * 256) / max(height, 1) else { return nil }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return HerdrTerminalFrame(seq: seq, width: width, height: height, full: full, bytes: Array(data))
    }
}

private extension Data {
    func trimmingASCIINewlines() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, self[start] == 0x0d || self[start] == 0x0a || self[start] == 0x20 {
            start += 1
        }
        while end > start, self[end - 1] == 0x0d || self[end - 1] == 0x0a || self[end - 1] == 0x20 {
            end -= 1
        }
        return subdata(in: start..<end)
    }
}

extension AnsiGrid {
    func rowStrings() -> [String] {
        guard cols > 0, rows > 0 else { return [] }
        return (0..<rows).map { row in
            var last = -1
            var glyphs: [Character] = []
            glyphs.reserveCapacity(cols)
            for col in 0..<cols {
                let glyph = self[col, row].glyph
                glyphs.append(glyph)
                if glyph != " " { last = glyphs.count - 1 }
            }
            if last < 0 { return "" }
            return String(glyphs.prefix(last + 1))
        }
    }
}
