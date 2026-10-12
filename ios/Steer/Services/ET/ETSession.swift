import Foundation
import Network

/// An Eternal Terminal client (protocol version 6). The session lives in etserver on the host; the phone's TCP
/// connection can drop and return, and each side replays whatever packets the other missed.
@MainActor
final class ETSession: DetachedTerminal {
    static let defaultPort = 2022
    private static let replayLimit = 64 << 20

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let id: String
    /// The tag set on this session's etterminal (see `ETConnect.endCommand`).
    let tag: String
    private var writer: ETCipher
    private var reader: ETCipher
    private let onBytes: @MainActor (ArraySlice<UInt8>) -> Void
    /// Called once when the server no longer knows this session, e.g. after the shell exits.
    var onEnd: @MainActor () -> Void = {}

    private var socket: ETSocket?
    private var recovering = false
    private var stopped = false
    private var ticker: Task<Void, Never>?
    // Sent packets, kept so they can be replayed to the server after a reconnect.
    private var sentPackets: [[UInt8]] = []
    private var sentBytes = 0
    private var writtenCount: Int64 = 0
    private var readCount: Int64 = 0
    private var keepaliveDue = ContinuousClock.now
    private var awaitingKeepalive = false
    private var grid = (cols: 80, rows: 24)
    private(set) var lastHeard: ContinuousClock.Instant?
    private(set) var connectionCount = 0

    init?(host: String, port: Int = defaultPort, id: String, passkey: String, tag: String = "",
          onBytes: @escaping @MainActor (ArraySlice<UInt8>) -> Void) {
        guard let box = SecretBox(key: Array(passkey.utf8)),
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.id = id
        self.tag = tag
        writer = ETCipher(box: box, direction: 0)
        reader = ETCipher(box: box, direction: 1)
        self.onBytes = onBytes
    }

    func start(cols: Int, rows: Int, environment: [String: String] = [:]) async throws {
        let socket = try await connect(expecting: ETProtocol.newClient)
        guard !stopped else { socket.close(); throw CancellationError() }
        self.socket = socket
        var started = false
        defer { if !started { stop() } }
        var payload = Protobuf.Writer()
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            var entry = Protobuf.Writer()
            entry.bytes(1, Array(name.utf8))
            entry.bytes(2, Array(value.utf8))
            payload.bytes(3, entry.bytes)
        }
        write(.initialPayload, payload.bytes)
        let response = try await readPacket(from: socket)
        guard response.header == ETProtocol.Header.initialResponse.rawValue else { throw ETError.rejected("Unexpected reply.") }
        if let error = ETProtocol.string(1, in: response.payload) { throw ETError.rejected(error) }
        handle(response)
        resize(cols: cols, rows: rows)
        listen(on: socket)
        ticker = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
        started = true
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        var message = Protobuf.Writer()
        message.bytes(1, Array(bytes))
        write(.terminalBuffer, message.bytes)
        keepaliveDue = .now + .seconds(5)
    }

    func resize(cols: Int, rows: Int) {
        grid = (cols, rows)
        var message = Protobuf.Writer()
        message.bytes(1, Array(id.utf8))
        message.varint(2, UInt64(rows))
        message.varint(3, UInt64(cols))
        write(.terminalInfo, message.bytes)
    }

    /// Foreground and path notifications can arrive while TCP is still healthy. A quiet session hears from the
    /// server only through the 5 s keepalive, so two missed periods mark it stale.
    func recoverConnection() {
        if let socket, socket.isReady, let lastHeard, ContinuousClock.now - lastHeard < .seconds(12) { return }
        reopenSocket()
    }

    /// Replaces a dead or stale TCP connection.
    func reopenSocket() {
        guard !stopped, !recovering else { return }
        socket?.close()
        socket = nil
        reconnect()
    }

    /// Drops the connection without a TERMINAL_CLOSE packet, because etserver 7.0 aborts on it. The remote shell
    /// ends when it exits or etserver restarts.
    func shutdown() {
        stop()
    }

    func stop() {
        stopped = true
        ticker?.cancel()
        ticker = nil
        socket?.close()
        socket = nil
    }

    // MARK: Packets

    private func write(_ header: ETProtocol.Header, _ payload: [UInt8]) {
        let packet = [1, header.rawValue] + writer.seal(payload)
        sentPackets.append(packet)
        sentBytes += packet.count
        writtenCount += 1
        while sentBytes > Self.replayLimit {
            sentBytes -= sentPackets.removeFirst().count
        }
        if let socket, !recovering { transmit(packet, on: socket) }
    }

    private func transmit(_ packet: [UInt8], on socket: ETSocket) {
        var framed = [UInt8]()
        framed.appendBigEndian(UInt32(packet.count))
        socket.write(framed + packet) { [weak self] failed in
            guard failed, let self, self.socket === socket else { return }
            self.reopenSocket()
        }
    }

    private func readPacket(from socket: ETSocket) async throws -> (header: UInt8, payload: [UInt8]) {
        let length = try await socket.read(4).reduce(0) { $0 << 8 | Int($1) }
        guard (2...(128 << 20)).contains(length) else { throw ETError.rejected("Invalid packet.") }
        let packet = try await socket.read(length)
        guard self.socket === socket else { throw CancellationError() }
        return try decrypt(packet)
    }

    private func decrypt(_ packet: [UInt8]) throws -> (header: UInt8, payload: [UInt8]) {
        guard packet.count >= 2, packet[0] == 1, let payload = reader.open(Array(packet[2...])) else {
            throw ETError.rejected("Couldn't decrypt a packet from etserver.")
        }
        readCount += 1
        return (packet[1], payload)
    }

    private func handle(_ packet: (header: UInt8, payload: [UInt8])) {
        lastHeard = .now
        switch ETProtocol.Header(rawValue: packet.header) {
        case .terminalBuffer:
            keepaliveDue = .now + .seconds(5)
            if let bytes = ETProtocol.bytes(1, in: packet.payload) { onBytes(bytes[...]) }
        case .keepAlive:
            awaitingKeepalive = false
        default:
            break
        }
    }

    private func listen(on socket: ETSocket) {
        Task { [weak self] in
            do {
                while true {
                    guard let self else { return }
                    let packet = try await self.readPacket(from: socket)
                    guard self.socket === socket else { return }
                    self.handle(packet)
                }
            } catch {
                guard let self, self.socket === socket else { return }
                self.reopenSocket()
            }
        }
    }

    /// ET's client sends a keepalive after 5 quiet seconds and reconnects if the previous one went unanswered.
    private func tick() {
        guard socket != nil, !recovering, ContinuousClock.now >= keepaliveDue else { return }
        keepaliveDue = .now + .seconds(5)
        if awaitingKeepalive {
            reopenSocket()
        } else {
            awaitingKeepalive = true
            write(.keepAlive, [])
        }
    }

    // MARK: Connecting

    private func connect(expecting status: UInt64) async throws -> ETSocket {
        let socket = ETSocket(host: host, port: port)
        do {
            try await socket.open()
            connectionCount += 1
            var request = Protobuf.Writer()
            request.bytes(1, Array(id.utf8))
            request.varint(2, UInt64(ETProtocol.version))
            socket.write(ETProtocol.handshake(request.bytes))
            let response = try await readHandshake(from: socket)
            let received = ETProtocol.varint(1, in: response)
            if received == ETProtocol.invalidKey { throw ETError.sessionEnded }
            guard received == status else {
                throw ETError.rejected(ETProtocol.string(2, in: response) ?? "etserver refused the connection.")
            }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    private func readHandshake(from socket: ETSocket) async throws -> [UInt8] {
        let length = try await socket.read(8).reversed().reduce(0) { $0 << 8 | Int($1) }
        guard (0...(128 << 20)).contains(length) else { throw ETError.rejected("Invalid handshake.") }
        return length == 0 ? [] : try await socket.read(length)
    }

    private func reconnect() {
        recovering = true
        Task { [weak self] in
            while let self, !self.stopped {
                do {
                    let socket = try await self.connect(expecting: ETProtocol.returningClient)
                    try await self.recover(on: socket)
                    return
                } catch ETError.sessionEnded {
                    self.stop()
                    self.onEnd()
                    return
                } catch {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Each side sends how many packets it has read; the other replays the rest.
    private func recover(on socket: ETSocket) async throws {
        defer { if self.socket !== socket { socket.close() } }
        var header = Protobuf.Writer()
        header.varint(1, UInt64(readCount))
        socket.write(ETProtocol.handshake(header.bytes))
        let remote = ETProtocol.varint(1, in: try await readHandshake(from: socket)) ?? 0
        let missing = writtenCount - Int64(remote)
        guard missing >= 0, missing <= sentPackets.count else {
            socket.close()
            throw ETError.sessionEnded
        }
        let replayedThrough = writtenCount
        var catchup = Protobuf.Writer()
        for packet in sentPackets.suffix(Int(missing)) { catchup.bytes(1, packet) }
        socket.write(ETProtocol.handshake(catchup.bytes))
        var received: [[UInt8]] = []
        Protobuf.fields(try await readHandshake(from: socket)) { field, value in
            if field == 1, case .bytes(let packet) = value { received.append(packet) }
        }
        guard !stopped else { socket.close(); return }
        for packet in received { handle(try decrypt(packet)) }
        self.socket = socket
        lastHeard = .now
        recovering = false
        awaitingKeepalive = false
        keepaliveDue = .now + .seconds(5)
        // Packets written while the catch-up was in flight.
        for packet in sentPackets.suffix(Int(writtenCount - replayedThrough)) { transmit(packet, on: socket) }
        listen(on: socket)
    }
}

enum ETProtocol {
    static let version = 6
    static let newClient: UInt64 = 1, returningClient: UInt64 = 2, invalidKey: UInt64 = 3

    enum Header: UInt8 {
        case keepAlive = 0, terminalBuffer = 1, terminalInfo = 2
        case initialResponse = 252, initialPayload = 253
    }

    /// Handshake messages carry a 64-bit length in the host's byte order, which is little-endian on every ET platform.
    static func handshake(_ message: [UInt8]) -> [UInt8] {
        withUnsafeBytes(of: Int64(message.count).littleEndian, Array.init) + message
    }

    static func bytes(_ field: Int, in message: [UInt8]) -> [UInt8]? {
        var found: [UInt8]?
        Protobuf.fields(message) { number, value in
            if number == field, case .bytes(let bytes) = value { found = bytes }
        }
        return found
    }

    static func string(_ field: Int, in message: [UInt8]) -> String? {
        bytes(field, in: message).map { String(decoding: $0, as: UTF8.self) }
    }

    static func varint(_ field: Int, in message: [UInt8]) -> UInt64? {
        var found: UInt64?
        Protobuf.fields(message) { number, value in
            if number == field, case .varint(let value) = value { found = value }
        }
        return found
    }
}

/// One direction's cipher. Every packet increments a 24-byte little-endian nonce whose last byte marks the direction.
struct ETCipher {
    private let box: SecretBox
    private var nonce: [UInt8]

    init(box: SecretBox, direction: UInt8) {
        self.box = box
        nonce = [UInt8](repeating: 0, count: 23) + [direction]
    }

    mutating func seal(_ plaintext: [UInt8]) -> [UInt8] {
        advance()
        return box.seal(plaintext, nonce: nonce)
    }

    mutating func open(_ sealed: [UInt8]) -> [UInt8]? {
        let previous = nonce
        advance()
        guard let plaintext = box.open(sealed, nonce: nonce) else {
            nonce = previous
            return nil
        }
        return plaintext
    }

    private mutating func advance() {
        for index in nonce.indices {
            nonce[index] &+= 1
            if nonce[index] != 0 { break }
        }
    }
}

/// Parses `etterminal` output: `IDPASSKEY:<16-character id>/<32-character passkey>`.
enum ETConnect {
    /// Set on every etterminal Steer starts, so its session can be ended later (see `endCommand`).
    static let tagVariable = "STEER_ET_SESSION"

    static func parse(_ output: String) -> (id: String, passkey: String)? {
        guard let marker = output.range(of: "IDPASSKEY:") else { return nil }
        let value = output[marker.upperBound...].prefix(49)
        let parts = value.split(separator: "/")
        guard value.count == 49, parts.count == 2, parts[0].count == 16, parts[1].count == 32 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// An id starting with XXX asks etterminal to generate the id and passkey, so the key never appears in a command line.
    static func terminalCommand(tag: String) -> String {
        MuxCommands.withUserPath(
            "echo 'XXX\(random(13))/\(random(32))_xterm-256color' | \(tagVariable)=\(tag) etterminal --verbose=0"
        )
    }

    /// Stops the session's etterminal, which owns its terminal, so the shell and anything attached in it get the usual
    /// hangup. This runs over SSH because etserver 7.0 aborts on TERMINAL_CLOSE. The tag is looked
    /// up on etterminal itself because macOS hides the environment of system programs such as the shell.
    static func endCommand(tag: String) -> String {
        // The empty quotes keep this command's own text from matching.
        [
            "k=\(tagVariable)\"\"=\(tag)",
            #"if [ -r /proc/self/environ ]; then pids=$(grep -l "$k" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3)"#,
            #"else pids=$(ps -E -ww -o pid=,command= -U "$(id -u)" | grep -F "$k" | awk '{print $1}'); fi"#,
            #"for pid in $pids; do ps -o command= -p "$pid" 2>/dev/null | grep -q etterminal && kill "$pid"; done; true"#,
        ].joined(separator: "\n")
    }

    @MainActor
    static func start(over ssh: SSHSession) async throws -> (id: String, passkey: String, tag: String) {
        let tag = random(16)
        let connect = try await DetachedLaunch(parse: parse, failure: { ETError.serverUnavailable($0) })
            .run(ssh, command: terminalCommand(tag: tag))
        return (connect.id, connect.passkey, tag)
    }

    private static func random(_ count: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<count).map { _ in letters.randomElement()! })
    }
}

enum ETError: LocalizedError {
    case serverUnavailable(String)
    case rejected(String)
    case sessionEnded

    var errorDescription: String? {
        switch self {
        case .serverUnavailable(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Couldn't start etterminal on the host. Install Eternal Terminal there and run etserver (e.g. brew install et)."
                + (detail.isEmpty ? "" : "\n\n" + String(detail.prefix(300)))
        case .rejected(let message):
            return "etserver: \(message)"
        case .sessionEnded:
            return "The Eternal Terminal session ended."
        }
    }
}

/// A TCP connection with async exact-length reads.
private final class ETSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.steer.et")
    /// Touched only on `queue`.
    private var opened: CheckedContinuation<Void, Error>?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        connection = NWConnection(host: host, port: port, using: .tcp)
    }

    var isReady: Bool {
        if case .ready = connection.state { return true }
        return false
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                opened = continuation
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.finishOpening(.success(()))
                    case .failed(let error), .waiting(let error): self.finishOpening(.failure(error))
                    case .cancelled: self.finishOpening(.failure(ETError.rejected("Connection cancelled.")))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self else { return }
                    self.finishOpening(.failure(ETError.rejected("Couldn't reach etserver at \(self.connection.endpoint).")))
                }
            }
        }
    }

    private func finishOpening(_ result: Result<Void, Error>) {
        guard let opened else { return }
        self.opened = nil
        opened.resume(with: result)
    }

    func read(_ count: Int) async throws -> [UInt8] {
        var buffer = [UInt8]()
        while buffer.count < count {
            buffer += try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, complete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: [UInt8](data))
                    } else {
                        continuation.resume(throwing: error ?? ETError.rejected(complete ? "Connection closed." : "No data."))
                    }
                }
            }
        }
        return buffer
    }

    func write(_ bytes: [UInt8], failed: (@MainActor (Bool) -> Void)? = nil) {
        connection.send(content: Data(bytes), completion: .contentProcessed { error in
            guard let failed else { return }
            Task { @MainActor in failed(error != nil) }
        })
    }

    func close() {
        connection.cancel()
    }
}
