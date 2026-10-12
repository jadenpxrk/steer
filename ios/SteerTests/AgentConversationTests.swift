import Foundation
import Testing
@testable import Steer

struct AgentConversationTests {
    @Test func companionRemainsOptInForExistingHosts() throws {
        let host = try JSONDecoder().decode(Host.self, from: Data(#"{"name":"Mac","hostname":"mac.local","username":"me"}"#.utf8))
        #expect(!host.companionEnabled)
        var enabled = host
        enabled.companionEnabled = true
        #expect(try JSONDecoder().decode(Host.self, from: JSONEncoder().encode(enabled)).companionEnabled)
    }

    @Test func validatesCompanionConfiguration() {
        let token = String(repeating: "a", count: 64)
        #expect(CompanionConfiguration(port: 43197, token: token).isValid)
        #expect(!CompanionConfiguration(port: 0, token: token).isValid)
        #expect(!CompanionConfiguration(port: 65536, token: token).isValid)
        #expect(!CompanionConfiguration(port: 43197, token: "not-a-token").isValid)
        #expect(!CompanionConfiguration(port: 43197, token: String(repeating: "g", count: 64)).isValid)
    }

    @Test func decodesConversationContractAndApprovalExpiry() throws {
        let data = Data(#"""
        {"session":{"id":"claude:s1","provider":"claude","title":"Claude","cwd":"/project","status":"waiting","updatedAt":1700000000000,"archived":false,
        "approvals":[{"id":"a1","tool":"Read","input":"{}","expiresAt":1700000300000,"questions":null}]},
        "messages":[{"id":"m1","role":"assistant","text":"Hello","tool":null}],
        "usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"contextUsed":10,"contextWindow":null,"rateLimits":[]},"truncated":false}
        """#.utf8)
        let value = try JSONDecoder().decode(AgentConversation.self, from: data)
        #expect(value.session.statusLabel == "Needs permission")
        #expect(value.messages.first?.text == "Hello")
        #expect(value.session.approvals.first?.expires == Date(timeIntervalSince1970: 1700000300))
        #expect(value.usage.contextWindow == nil)
    }
}
