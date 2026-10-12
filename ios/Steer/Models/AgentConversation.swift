import Foundation

struct CompanionSession: Decodable, Identifiable, Sendable {
    let id: String
    let provider: String
    let title: String
    let cwd: String
    let status: String
    let archived: Bool
    let approvals: [CompanionApproval]
    let managed: Bool?
    let canSend: Bool?
    let canStop: Bool?
    let error: String?

    var statusLabel: String {
        switch status {
        case "waiting": "Needs permission"
        case "working": "Working"
        case "done": "Finished"
        case "idle": "Ready"
        case "ended": "Ended"
        case "history": "History"
        default: "Status unavailable"
        }
    }
}

struct CompanionApproval: Decodable, Identifiable, Sendable {
    let id: String
    let tool: String
    let input: String
    let expiresAt: Double
    let questions: [Question]?

    var expires: Date { Date(timeIntervalSince1970: expiresAt / 1000) }

    struct Question: Decodable, Sendable {
        let question: String
        let options: [String]
        let multiSelect: Bool
    }
}

struct AgentConversation: Decodable, Sendable {
    let session: CompanionSession
    let messages: [Message]
    let usage: Usage
    let truncated: Bool
    let transcriptError: String?

    struct Message: Decodable, Identifiable, Sendable {
        let id: String
        let role: String
        let text: String
        let tool: String?
    }

    struct Usage: Decodable, Sendable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let contextUsed: Int?
        let contextWindow: Int?
        let rateLimits: [RateLimit]
    }

    struct RateLimit: Decodable, Sendable {
        let name: String
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Double?
    }
}

struct CompanionConfiguration: Decodable, Sendable {
    let port: Int
    let token: String

    var isValid: Bool {
        (1...65535).contains(port) && token.count == 64 && token.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
