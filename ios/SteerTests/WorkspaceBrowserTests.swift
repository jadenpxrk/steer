import Observation
import Testing
import UIKit
@testable import Steer

@MainActor
struct WorkspaceBrowserTests {
    @Test
    func workspacesStayDistinctAcrossConnectionsAndNamedServers() throws {
        let first = TerminalController(host: Host(name: "Laptop", hostname: "laptop.invalid", username: "test"))
        let second = TerminalController(host: Host(name: "Desktop", hostname: "desktop.invalid", username: "test"))
        var main = try MuxDiscovery.parseHerdrPanes(#"{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","tab_id":"w1:t1","focused":true},{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2"}]}}"#)
        for index in main.indices { main[index].sessionName = "main" }
        var other = main[0]
        other.sessionName = "other"
        first.mux.catalog = MuxCatalog(agents: main + [other], sessions: [], tmux: [])
        second.mux.catalog = first.mux.catalog
        let model = WorkspaceBrowserState([first, second])

        #expect(model.items.count == 4)
        #expect(Set(model.items.map(\.id)).count == 4)
        let workspace = try #require(model.items.first { $0.listing.attach.herdrSessionName == "main" })
        #expect(workspace.listing.tabs.count == 2)
        #expect(workspace.listing.attach == .herdrAgent(main[0]))
        #expect(workspace.controllerID == first.id)
    }

    @Test
    func catalogsAndRenamesUpdateWithoutReconnecting() {
        var host = Host(name: "Office Mac", hostname: "machine.invalid", username: "test")
        let controller = TerminalController(host: host)
        #expect(WorkspaceBrowserState([controller]).items.isEmpty)
        controller.phase = .connecting
        #expect(WorkspaceBrowserState([controller]).isLoading)
        controller.mux.catalog = tmuxCatalog("Steer")
        controller.phase = .connected
        #expect(!WorkspaceBrowserState([controller]).isLoading)
        #expect(WorkspaceBrowserState([controller]).items.map(\.listing.title) == ["Steer"])

        host.name = "Studio Mac"
        controller.updateHost(host)
        let items = WorkspaceBrowserState([controller]).items
        #expect(items.first?.host.displayName == "Studio Mac")
        #expect(items.filter { $0.matches(" STUDIO  steer ") }.count == 1)
        #expect(items.filter { $0.matches("machine.invalid TMUX") }.count == 1)
        #expect(items.filter { $0.matches("Office Mac") }.isEmpty)
        #expect(items.filter { $0.matches("  ") }.count == 1)
        #expect(controller.phase == .connected)
        controller.mux.catalog = tmuxCatalog("New workspace")
        #expect(WorkspaceBrowserState([controller]).items.map(\.listing.title) == ["New workspace"])
    }

    @Test
    func catalogChangesInvalidateObservingViews() {
        let controller = TerminalController(host: Host(name: "Studio", hostname: "studio.invalid", username: "test"))
        nonisolated(unsafe) var changed = false
        withObservationTracking {
            _ = WorkspaceBrowserState([controller])
        } onChange: {
            changed = true
        }
        controller.mux.catalog = tmuxCatalog("Workspace")
        #expect(changed)
    }

    @Test
    func connectionErrorsRemainVisibleAndClearAfterRecovery() {
        let controller = TerminalController(host: Host(name: "Studio", hostname: "studio.invalid", username: "test"))
        controller.mux.error = "Connection unavailable"
        #expect(WorkspaceBrowserState([controller]).issues == ["Studio: Connection unavailable"])
        controller.phase = .connecting
        #expect(WorkspaceBrowserState([controller]).issues.isEmpty)
        controller.mux.error = nil
        controller.mux.catalog = tmuxCatalog("Workspace")
        controller.phase = .connected
        let model = WorkspaceBrowserState([controller])
        #expect(model.issues.isEmpty)
        #expect(model.items.count == 1)
    }

    @Test
    func officialBrandAssetsLoad() {
        for name in ["HerdrLogo", "TmuxLogo", "ZellijLogo"] {
            #expect(UIImage(named: name) != nil)
        }
    }

    private func tmuxCatalog(_ name: String) -> MuxCatalog {
        MuxCatalog(agents: [], sessions: [],
                   tmux: [TmuxSession(name: name, windowCount: 1, isAttached: false)])
    }
}
