import Foundation

struct Host: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var hostname: String
    var username: String
    var port = 22
    var startupCommand = ""
    var fallbackHostnames: [String] = []
    var protectCredentials = false
    var companionEnabled = false
    /// Bastion to connect through (ProxyJump). A copy of a saved host; HostStore keeps it current.
    var jump: JumpHost?
    /// Lets processes on this host use its saved key through a forwarded SSH agent (ssh -A).
    var forwardAgent = false
    var transport = HostTransport.ssh
    /// mosh-server's UDP port or range (`60000` or `60000:60010`); empty lets mosh-server choose.
    var moshPorts = ""
    /// Custom mosh-server path; empty finds it on the user's PATH.
    var moshServerPath = ""
    /// The TCP port etserver listens on; nil means ET's default, 2022.
    var etPort: Int?

    /// Mosh and ET connect to the host itself, so through a jump host the terminal stays on SSH.
    var terminalTransport: HostTransport { jump == nil ? transport : .ssh }

    var displayName: String {
        needsDeviceName ? hostname : name
    }

    var needsDeviceName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.caseInsensitiveCompare("This Mac") == .orderedSame
    }

    var connectionHostnames: [String] {
        ([hostname] + fallbackHostnames).reduce(into: []) { result, candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
                return
            }
            result.append(trimmed)
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        username: String,
        port: Int = 22,
        startupCommand: String = "",
        fallbackHostnames: [String] = [],
        protectCredentials: Bool = false,
        companionEnabled: Bool = false,
        jump: JumpHost? = nil,
        forwardAgent: Bool = false,
        transport: HostTransport = .ssh
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.username = username
        self.port = port
        self.startupCommand = startupCommand
        self.fallbackHostnames = fallbackHostnames
        self.protectCredentials = protectCredentials
        self.companionEnabled = companionEnabled
        self.jump = jump
        self.forwardAgent = forwardAgent
        self.transport = transport
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        hostname = try values.decode(String.self, forKey: .hostname)
        username = try values.decode(String.self, forKey: .username)
        port = try values.decodeIfPresent(Int.self, forKey: .port) ?? 22
        startupCommand = try values.decodeIfPresent(String.self, forKey: .startupCommand) ?? ""
        fallbackHostnames = try values.decodeIfPresent([String].self, forKey: .fallbackHostnames) ?? []
        protectCredentials = try values.decodeIfPresent(Bool.self, forKey: .protectCredentials) ?? false
        companionEnabled = try values.decodeIfPresent(Bool.self, forKey: .companionEnabled) ?? false
        jump = try values.decodeIfPresent(JumpHost.self, forKey: .jump)
        forwardAgent = try values.decodeIfPresent(Bool.self, forKey: .forwardAgent) ?? false
        transport = (try? values.decodeIfPresent(HostTransport.self, forKey: .transport)) ?? .ssh
        moshPorts = try values.decodeIfPresent(String.self, forKey: .moshPorts) ?? ""
        moshServerPath = try values.decodeIfPresent(String.self, forKey: .moshServerPath) ?? ""
        etPort = try values.decodeIfPresent(Int.self, forKey: .etPort)
    }
}

enum HostTransport: String, Codable, CaseIterable {
    case auto, ssh, mosh, et

    var title: String {
        switch self {
        case .auto: "Auto"
        case .ssh: "SSH"
        case .mosh: "Mosh"
        case .et: "ET"
        }
    }
}

/// The connection details of a saved host used as a jump host. Its credentials and pinned key stay under its own id.
struct JumpHost: Codable, Hashable {
    var id: UUID
    var name: String
    var hostname: String
    var username: String
    var port: Int
    var fallbackHostnames: [String]
    var protectCredentials: Bool

    init(_ host: Host) {
        id = host.id
        name = host.name
        hostname = host.hostname
        username = host.username
        port = host.port
        fallbackHostnames = host.fallbackHostnames
        protectCredentials = host.protectCredentials
    }

    var host: Host {
        Host(id: id, name: name, hostname: hostname, username: username, port: port,
             fallbackHostnames: fallbackHostnames, protectCredentials: protectCredentials)
    }
}
