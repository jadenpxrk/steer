import Foundation
import Testing
@testable import Steer

struct SteerLinksTests {
    @Test func terminalLinksKeepSchemesAndUpgradeBareDomains() {
        #expect(TerminalLink.url(from: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(TerminalLink.url(from: "example.com/docs")?.absoluteString == "https://example.com/docs")
        #expect(TerminalLink.url(from: "  localhost:3000  ") == nil)
        #expect(TerminalLink.url(from: "http://localhost:3000")?.port == 3000)
        #expect(TerminalLink.url(from: "not a link") == nil)
        #expect(TerminalLink.url(from: "file.") == nil)
    }

    @Test func deepLinksNameAHostAndOptionalTarget() throws {
        let tmux = try #require(SteerDeepLink(url: URL(string: "steer://open?host=Studio&tmux=dev%20box")!))
        #expect(tmux.host == "Studio")
        #expect(tmux.target == .tmux(TmuxSession(name: "dev box", windowCount: nil, isAttached: false)))

        let pane = try #require(SteerDeepLink(url: URL(string: "steer://open?host=mac.local&pane=w1:p2&herdr-session=main")!))
        guard case .herdrAgent(let agent) = pane.target else { Issue.record("expected herdr target"); return }
        #expect(agent.paneID == "w1:p2")
        #expect(agent.sessionName == "main")

        #expect(SteerDeepLink(url: URL(string: "steer://open?host=Studio")!)?.target == nil)
        #expect(SteerDeepLink(url: URL(string: "steer://open?tmux=dev")!) == nil)
        #expect(SteerDeepLink(url: URL(string: "https://open?host=Studio")!) == nil)
    }

    @Test func deepLinksMatchNameOrHostnameIgnoringCase() throws {
        let link = try #require(SteerDeepLink(url: URL(string: "steer://open?host=STUDIO.local")!))
        #expect(link.matches(Host(name: "Studio", hostname: "studio.local", username: "me")))
        #expect(!link.matches(Host(name: "Other", hostname: "other.local", username: "me")))
    }
}
