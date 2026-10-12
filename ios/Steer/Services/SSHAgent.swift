import Foundation
import NIOCore
import NIOSSH

/// Answers OpenSSH agent requests (draft-miller-ssh-agent) that arrive on forwarded
/// "auth-agent@openssh.com" channels, offering the host's own saved key.
struct SSHAgent: Sendable {
    let key: NIOSSHPrivateKey?
    let comment: String

    private enum Message: UInt8 {
        case failure = 5
        case requestIdentities = 11
        case identitiesAnswer = 12
        case signRequest = 13
        case signResponse = 14
    }

    private static let rsaSHA256Flag: UInt32 = 2
    private static let rsaSHA512Flag: UInt32 = 4

    private var publicLine: String? { key.map { String(openSSHPublicKey: $0.publicKey) } }

    private var publicBlob: [UInt8]? {
        publicLine.flatMap { $0.split(separator: " ").dropFirst().first }.flatMap { Data(base64Encoded: String($0)) }.map(Array.init)
    }

    /// Replies to one agent message: its type byte and payload, without the length prefix.
    func reply(to message: [UInt8]) -> [UInt8] {
        var request = ByteBuffer(bytes: message)
        var response = ByteBuffer()
        switch request.readInteger(as: UInt8.self).flatMap(Message.init(rawValue:)) {
        case .requestIdentities:
            response.writeInteger(Message.identitiesAnswer.rawValue)
            if let publicBlob {
                response.writeInteger(UInt32(1))
                response.writeAgentString(publicBlob)
                response.writeAgentString(Array(comment.utf8))
            } else {
                response.writeInteger(UInt32(0))
            }
        case .signRequest:
            guard let key, let publicBlob, let publicLine,
                  let blob = request.readAgentString(), blob == publicBlob,
                  let data = request.readAgentString(),
                  let flags = request.readInteger(as: UInt32.self) else { return Self.failure }
            let isRSA = publicLine.hasPrefix("ssh-rsa ")
            // SHA-1 `ssh-rsa` signatures are not produced.
            if isRSA, flags & (Self.rsaSHA256Flag | Self.rsaSHA512Flag) == 0 { return Self.failure }
            let preferSHA256 = flags & Self.rsaSHA512Flag == 0 && flags & Self.rsaSHA256Flag != 0
            guard var signature = try? key.agentSignature(for: data, rsaSHA256: preferSHA256) else { return Self.failure }
            response.writeInteger(Message.signResponse.rawValue)
            response.writeInteger(UInt32(signature.readableBytes))
            response.writeBuffer(&signature)
        default:
            return Self.failure
        }
        return Array(response.readableBytesView)
    }

    private static let failure = [Message.failure.rawValue]
}

/// Frames agent messages (`uint32 length` + body) on a forwarded agent channel.
final class SSHAgentChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let agent: SSHAgent
    private var pending = ByteBuffer()

    init(agent: SSHAgent) {
        self.agent = agent
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(var bytes) = unwrapInboundIn(data).data else { return }
        pending.writeBuffer(&bytes)
        while let length = pending.getInteger(at: pending.readerIndex, as: UInt32.self),
              pending.readableBytes >= 4 + Int(length) {
            guard length <= 256 * 1024 else {
                context.close(promise: nil)
                return
            }
            pending.moveReaderIndex(forwardBy: 4)
            let reply = agent.reply(to: pending.readBytes(length: Int(length)) ?? [])
            var out = context.channel.allocator.buffer(capacity: reply.count + 4)
            out.writeInteger(UInt32(reply.count))
            out.writeBytes(reply)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(out))), promise: nil)
        }
        pending.discardReadBytes()
    }
}

/// Asks the server to forward the agent on a session channel before any shell, exec, or PTY request.
final class SSHAgentRequestHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = SSHChannelData
    private var sent = false

    func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive { request(context) }
    }

    func channelActive(context: ChannelHandlerContext) {
        request(context)
        context.fireChannelActive()
    }

    private func request(_ context: ChannelHandlerContext) {
        guard !sent else { return }
        sent = true
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.AgentForwardingRequest(wantReply: false), promise: nil)
    }
}

private extension ByteBuffer {
    mutating func writeAgentString(_ bytes: [UInt8]) {
        writeInteger(UInt32(bytes.count))
        writeBytes(bytes)
    }

    mutating func readAgentString() -> [UInt8]? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self), readableBytes >= 4 + Int(length) else { return nil }
        moveReaderIndex(forwardBy: 4)
        return readBytes(length: Int(length))
    }
}
