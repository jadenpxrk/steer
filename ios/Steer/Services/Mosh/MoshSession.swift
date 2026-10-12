import Foundation
import Network

/// A Mosh client: encrypted UDP datagrams carrying state-synchronization instructions.
/// The local state is the user's input stream; the remote state is the server's screen, which is applied
/// straight to the terminal, so only diffs based on the screen currently shown are accepted.
@MainActor
final class MoshSession: DetachedTerminal {
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let ocb: AESOCB
    private let onBytes: @MainActor (ArraySlice<UInt8>) -> Void
    private let queue = DispatchQueue(label: "app.steer.mosh")
    private var connection: NWConnection?
    private var ticker: Task<Void, Never>?
    private let started = ContinuousClock.now

    // Outgoing user stream and the states the server has been sent.
    private var input = MoshInputHistory()
    private var sentStates: [(num: UInt64, count: Int)] = [(0, 0)]
    private var ackedNum: UInt64 = 0
    private var sequence: UInt64 = 0
    private var fragmentID: UInt64 = 0
    private var nextRetransmit: ContinuousClock.Instant?
    private var nextHeartbeat = ContinuousClock.now
    private var pendingInputSince: ContinuousClock.Instant?
    private var pendingAckSince: ContinuousClock.Instant?

    // Incoming screen state.
    private var screenNum: UInt64 = 0
    private var assembly = MoshProtocol.Assembly()
    private var savedTimestamp: (value: UInt16, at: ContinuousClock.Instant)?
    private var smoothedRTT: Double?
    private var rttVariance: Double = 0
    private(set) var lastHeard: ContinuousClock.Instant?
    /// Input-stream length of each recently sent state, to translate the server's echo acks.
    private var stateCounts: [UInt64: Int] = [0: 0]
    /// Called with how many input events the server has echoed to its screen.
    var onEchoAck: @MainActor (Int) -> Void = { _ in }

    var eventCount: Int { input.count }
    /// Smoothed round-trip time in milliseconds, once measured.
    var roundTrip: Double? { smoothedRTT }

    /// `key` is the 22-character base64 key from `MOSH CONNECT`.
    init?(host: String, port: Int, key: String, onBytes: @escaping @MainActor (ArraySlice<UInt8>) -> Void) {
        guard let keyBytes = Data(base64Encoded: key + "=="), keyBytes.count == 16,
              let ocb = AESOCB(key: Array(keyBytes)),
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return nil }
        self.host = NWEndpoint.Host(host)
        self.port = port
        self.ocb = ocb
        self.onBytes = onBytes
    }

    func start(cols: Int, rows: Int) {
        input.append(.resize(cols: cols, rows: rows))
        pendingInputSince = .now
        nextHeartbeat = .now + .seconds(3)
        openSocket()
        scheduleTick()
    }

    /// Tells the server the client is leaving so mosh-server exits, then stops. Mosh signals this with state number 2^64 − 1.
    func shutdown() {
        let instruction = MoshProtocol.Instruction(
            oldNum: ackedNum, newNum: .max, ackNum: screenNum, throwawayNum: ackedNum, diff: []
        )
        fragmentID += 1
        let fragments = MoshProtocol.fragments(instruction, id: fragmentID)
        ticker?.cancel()
        ticker = nil
        // Cancelling at once would drop the queued datagrams and leave mosh-server running on the host.
        // Three copies in all, the last one closing the socket once it is sent.
        for _ in 0..<2 {
            for fragment in fragments { sendPacket(fragment.bytes) }
        }
        let connection = connection
        self.connection = nil
        let close: @Sendable () -> Void = { connection?.cancel() }
        sendPacket(fragments[fragments.count - 1].bytes, then: close, on: connection)
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        connection?.cancel()
        connection = nil
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        input.append(.keys(Array(bytes)))
        if pendingInputSince == nil { pendingInputSince = .now }
        scheduleTick()
    }

    func resize(cols: Int, rows: Int) {
        input.append(.resize(cols: cols, rows: rows))
        if pendingInputSince == nil { pendingInputSince = .now }
        scheduleTick()
    }

    /// Replaces the UDP socket, e.g. after a network change or returning from the background. The session survives:
    /// the server follows the client to its new address once an authenticated packet arrives.
    func reopenSocket() {
        connection?.cancel()
        openSocket()
        nextHeartbeat = .now
        scheduleTick()
    }

    private func openSocket() {
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.reopenSocket() } }
        }
        self.connection = connection
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data {
                let bytes = [UInt8](data)
                Task { @MainActor in self?.handleDatagram(bytes) }
            }
            guard error == nil else { return }
            Task { @MainActor in
                guard let self, self.connection === connection else { return }
                self.receive(on: connection)
            }
        }
    }

    // MARK: Sending

    private var now16: UInt16 { UInt16(truncatingIfNeeded: Self.milliseconds(ContinuousClock.now - started)) }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private var retransmitTimeout: Duration {
        guard let smoothedRTT else { return .milliseconds(1000) }
        return .milliseconds(Int(min(max(smoothedRTT + 4 * rttVariance, 50), 1000)))
    }

    private func tick() {
        let now = ContinuousClock.now
        let inputReady = pendingInputSince.map { now - $0 >= .milliseconds(8) } ?? false
        let retransmit = nextRetransmit.map { now >= $0 } ?? false
        let ackDue = pendingAckSince.map { now - $0 >= .milliseconds(100) } ?? false
        guard inputReady || retransmit || ackDue || now >= nextHeartbeat else { return }
        sendState(diff: MoshProtocol.encodeUserMessage(input.events[...]))
    }

    private func scheduleTick() {
        ticker?.cancel()
        guard connection != nil else { ticker = nil; return }
        let deadline = [
            pendingInputSince.map { $0 + .milliseconds(8) },
            nextRetransmit,
            nextHeartbeat,
            pendingAckSince.map { $0 + .milliseconds(100) },
        ].compactMap { $0 }.min()!
        ticker = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.tick()
            self.scheduleTick()
        }
    }

    private func sendState(diff: [UInt8]) {
        let last = sentStates[sentStates.count - 1]
        let newNum: UInt64
        if diff.isEmpty || last.count != eventCount {
            newNum = last.num + 1
            sentStates.append((newNum, eventCount))
            stateCounts[newNum] = eventCount
            stateCounts = stateCounts.filter { $0.key + 256 > newNum }
        } else {
            newNum = last.num
        }
        let instruction = MoshProtocol.Instruction(
            oldNum: ackedNum, newNum: newNum, ackNum: screenNum, throwawayNum: ackedNum, diff: diff
        )
        fragmentID += 1
        for fragment in MoshProtocol.fragments(instruction, id: fragmentID) {
            sendPacket(fragment.bytes)
        }
        pendingInputSince = nil
        pendingAckSince = nil
        nextHeartbeat = .now + .seconds(3)
        nextRetransmit = diff.isEmpty ? nil : .now + retransmitTimeout
    }

    private func sendPacket(_ payload: [UInt8], then: (@Sendable () -> Void)? = nil, on target: NWConnection? = nil) {
        var reply: UInt16 = 0xFFFF
        if let saved = savedTimestamp, ContinuousClock.now - saved.at < .seconds(1) {
            // Advance the echoed timestamp by how long it was held, as mosh does.
            reply = saved.value &+ UInt16(truncatingIfNeeded: Self.milliseconds(ContinuousClock.now - saved.at))
            savedTimestamp = nil
        }
        var plaintext = [UInt8]()
        plaintext.appendBigEndian(now16)
        plaintext.appendBigEndian(reply)
        plaintext += payload
        // Nonce: 4 zero bytes, then the direction bit (0 = to server) and a 63-bit sequence number.
        var nonceValue = [UInt8]()
        nonceValue.appendBigEndian(sequence & ~(UInt64(1) << 63))
        sequence += 1
        let datagram = nonceValue + ocb.seal(plaintext, nonce: [0, 0, 0, 0] + nonceValue)
        let completion: NWConnection.SendCompletion
        if let then {
            completion = .contentProcessed { _ in then() }
        } else {
            completion = .idempotent
        }
        (target ?? connection)?.send(content: Data(datagram), completion: completion)
    }

    // MARK: Receiving

    private func handleDatagram(_ datagram: [UInt8]) {
        defer { scheduleTick() }
        guard datagram.count >= 24 else { return }
        let nonceValue = Array(datagram[0..<8])
        // Only packets addressed to the client (direction bit set) are accepted.
        guard nonceValue[0] & 0x80 != 0,
              let plaintext = ocb.open(Array(datagram[8...]), nonce: [0, 0, 0, 0] + nonceValue),
              plaintext.count >= 4 else { return }
        lastHeard = .now
        let timestamp = UInt16(plaintext[0]) << 8 | UInt16(plaintext[1])
        let timestampReply = UInt16(plaintext[2]) << 8 | UInt16(plaintext[3])
        savedTimestamp = (timestamp, .now)
        if timestampReply != 0xFFFF { recordRTT(Double(now16 &- timestampReply)) }

        guard let fragment = MoshProtocol.Fragment(Array(plaintext[4...])),
              let instruction = assembly.add(fragment),
              instruction.protocolVersion == MoshProtocol.version else { return }
        acknowledge(through: instruction.ackNum)
        guard instruction.oldNum == screenNum else {
            if pendingAckSince == nil { pendingAckSince = .now }
            return
        }
        guard instruction.newNum != screenNum else { return }
        if !instruction.diff.isEmpty {
            guard let hostEvents = MoshProtocol.decodeHostMessage(instruction.diff) else { return }
            for event in hostEvents {
                switch event {
                case .bytes(let bytes): onBytes(bytes[...])
                case .echoAck(let num): if let count = stateCounts[num] { onEchoAck(count) }
                case .resize: break
                }
            }
        }
        screenNum = instruction.newNum
        if pendingAckSince == nil { pendingAckSince = .now }
    }

    private func acknowledge(through num: UInt64) {
        guard let index = sentStates.firstIndex(where: { $0.num == num }) else { return }
        ackedNum = num
        input.acknowledge(through: sentStates[index].count)
        sentStates.removeFirst(index)
        if input.events.isEmpty { nextRetransmit = nil }
    }

    private func recordRTT(_ sample: Double) {
        guard sample < 5000 else { return }
        if let smoothedRTT {
            rttVariance = 0.75 * rttVariance + 0.25 * abs(smoothedRTT - sample)
            self.smoothedRTT = 0.875 * smoothedRTT + 0.125 * sample
        } else {
            smoothedRTT = sample
            rttVariance = sample / 2
        }
    }
}

/// Retains only unacknowledged input; state and echo-ack counts stay absolute after trimming.
struct MoshInputHistory {
    private(set) var events: [MoshProtocol.UserEvent] = []
    private(set) var base = 0
    var count: Int { base + events.count }

    mutating func append(_ event: MoshProtocol.UserEvent) {
        events.append(event)
    }

    mutating func acknowledge(through count: Int) {
        guard count > base, count <= self.count else { return }
        events.removeFirst(count - base)
        base = count
    }
}

/// Parses `mosh-server new` output: `MOSH CONNECT <port> <key>`.
enum MoshConnect {
    static func parse(_ output: String) -> (port: Int, key: String)? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count == 4, parts[0] == "MOSH", parts[1] == "CONNECT", let port = Int(parts[2]),
                  parts[3].count == 22 else { continue }
            return (port, String(parts[3]))
        }
        return nil
    }

    /// Starts mosh-server detached, binding to the address SSH reached (`-s`), with a UTF-8 locale.
    static func serverCommand(running command: String?, ports: String = "", path: String = "", clientFlag: Bool = false) -> String {
        let server = path.isEmpty ? "mosh-server" : ShellQuote.posixSingle(path)
        let portOption = portRange(ports).map { " -p \($0)" } ?? ""
        let program = command.map { " -- sh -c " + ShellQuote.posixSingle($0) } ?? ""
        let flag = clientFlag ? " -l \(SteerClientFlag.name)=1" : ""
        return MuxCommands.withUserPath(server + " new -s -c 256" + portOption + " -l LANG=en_US.UTF-8" + flag + program)
    }

    /// Accepts `60000`, `60000:60010`, or `60000-60010`; returns mosh-server's `PORT[:PORT2]` form.
    static func portRange(_ text: String) -> String? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == ":" || $0 == "-" })
        let ports = parts.compactMap { Int($0) }.filter { (1...65_535).contains($0) }
        guard !parts.isEmpty, parts.count <= 2, ports.count == parts.count, ports.first! <= ports.last! else { return nil }
        return ports.map(String.init).joined(separator: ":")
    }

    /// Runs mosh-server over SSH and returns its port and key.
    @MainActor
    static func start(over ssh: SSHSession, running command: String?, host: Host? = nil) async throws -> (port: Int, key: String) {
        try await DetachedLaunch(parse: parse, failure: { MoshError.serverUnavailable($0) })
            .run(ssh, command: serverCommand(
                running: command, ports: host?.moshPorts ?? "", path: host?.moshServerPath ?? "",
                clientFlag: host != nil && SteerClientFlag.enabled
            ))
    }
}

enum MoshError: LocalizedError {
    case serverUnavailable(String)
    case noReply

    var errorDescription: String? {
        switch self {
        case .noReply:
            return "mosh-server started but no UDP reply arrived. Check the host firewall and the Mosh port range."
        case .serverUnavailable(let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Couldn't start mosh-server on the host. Install mosh there (e.g. brew install mosh)."
                + (detail.isEmpty ? "" : "\n\n" + String(detail.prefix(300)))
        }
    }
}
