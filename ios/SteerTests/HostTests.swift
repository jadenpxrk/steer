import Foundation
import Testing
@testable import Steer

struct HostTests {
    @Test(arguments: ["", "  ", "This Mac", " this mac\n"])
    func unnamedConnectionsUseTheirAddressUntilResolved(name: String) {
        let host = Host(name: name, hostname: "studio.local", username: "me")
        #expect(host.needsDeviceName)
        #expect(host.displayName == "studio.local")
    }

    @Test @MainActor
    func resolvesAndPersistsDeviceNameWithoutReconnecting() async throws {
        let suite = "HostTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostStore(defaults: defaults)
        let original = Host(name: "This Mac", hostname: "studio.local", username: "me")
        store.save(original)
        let controller = TerminalController(host: original)
        controller.phase = .connected
        controller.onDeviceNameResolved = { source, name in
            #expect(source == original)
            var saved = source
            saved.name = name
            store.save(saved)
        }

        await controller.resolveDeviceName { _ in
            SSHExecResult(stdout: "  Sam’s Mac Studio\n", stderr: "", exitStatus: 0)
        }

        #expect(controller.host.displayName == "Sam’s Mac Studio")
        #expect(controller.host.id == original.id)
        #expect(controller.phase == .connected)
        #expect(HostStore(defaults: defaults).hosts == [controller.host])
        await controller.resolveDeviceName { _ in
            Issue.record("A saved device name should not be fetched again")
            throw SSHExecError.failed
        }
    }

    @Test @MainActor
    func customNamesDoNotTriggerDeviceLookup() async {
        let controller = TerminalController(host: Host(name: "Build server", hostname: "build.local", username: "me"))
        controller.onDeviceNameResolved = { _, _ in Issue.record("Custom name overwritten") }
        await controller.resolveDeviceName { _ in
            Issue.record("Custom names do not require a remote lookup")
            throw SSHExecError.failed
        }
        #expect(controller.host.displayName == "Build server")
    }

    @Test @MainActor
    func lateDeviceNameDoesNotOverwriteAnEditOrDisconnectedSession() async {
        for disconnect in [false, true] {
            let controller = TerminalController(host: Host(name: "This Mac", hostname: "studio.local", username: "me"))
            controller.onDeviceNameResolved = { _, _ in Issue.record("Stale device name was saved") }
            await controller.resolveDeviceName { _ in
                if disconnect {
                    controller.disconnect()
                } else {
                    var edited = controller.host
                    edited.name = "My server"
                    controller.updateHost(edited)
                }
                return SSHExecResult(stdout: "Mac Studio\n", stderr: "", exitStatus: 0)
            }
            #expect(controller.host.name == (disconnect ? "This Mac" : "My server"))
        }
    }

    @Test @MainActor
    func failedOrMalformedLookupKeepsTheConnectionUsable() async {
        let controller = TerminalController(host: Host(name: "This Mac", hostname: "studio.local", username: "me"))
        controller.phase = .connected
        controller.onDeviceNameResolved = { _, _ in Issue.record("Invalid device name was saved") }
        await controller.resolveDeviceName { _ in throw SSHExecError.timedOut }
        await controller.resolveDeviceName { _ in
            SSHExecResult(stdout: "Permission denied", stderr: "", exitStatus: 1)
        }
        for output in ["\n", "banner\nMac Studio", "\u{1B}[0mMac Studio", String(repeating: "x", count: 256), "This Mac"] {
            await controller.resolveDeviceName { _ in
                SSHExecResult(stdout: output, stderr: "", exitStatus: 0)
            }
        }
        #expect(controller.host.name == "This Mac")
        #expect(controller.phase == .connected)
        #expect(controller.errorMessage == nil)
    }

    @Test
    func deduplicatesConnectionAddressesInOrder() {
        let host = Host(
            name: "Mac",
            hostname: "mac.tailnet.ts.net",
            username: "me",
            fallbackHostnames: [" 192.168.1.5 ", "MAC.TAILNET.TS.NET", "", "mac.local"]
        )

        #expect(host.connectionHostnames == ["mac.tailnet.ts.net", "192.168.1.5", "mac.local"])
    }

    @Test
    func decodesHostsSavedBeforeFallbackAddresses() throws {
        let data = #"{"name":"Mac","hostname":"mac.local","username":"me"}"#.data(using: .utf8)!
        let host = try JSONDecoder().decode(Host.self, from: data)

        #expect(host.port == 22)
        #expect(host.fallbackHostnames.isEmpty)
        #expect(!host.protectCredentials)
        #expect(host.connectionHostnames == ["mac.local"])
    }

    @Test @MainActor
    func jumpHostCopiesFollowEditsAndRemoval() {
        let suite = "HostTests.jump.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostStore(defaults: defaults)
        var bastion = Host(name: "Bastion", hostname: "bastion.example", username: "ops")
        store.save(bastion)
        store.save(Host(name: "Inner", hostname: "10.0.0.5", username: "me", jump: JumpHost(bastion)))

        bastion.hostname = "bastion2.example"
        store.save(bastion)
        #expect(store.hosts[1].jump?.hostname == "bastion2.example")
        #expect(HostStore(defaults: defaults).hosts[1].jump?.hostname == "bastion2.example")

        store.remove(at: IndexSet(integer: 0))
        #expect(store.hosts.count == 1)
        #expect(store.hosts[0].jump == nil)
    }

    @Test @MainActor func jumpDependenciesPreventASecondLevel() {
        let suite = "HostTests.chain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostStore(defaults: defaults)
        var bastion = Host(name: "Bastion", hostname: "bastion.example", username: "ops")
        let outer = Host(name: "Outer", hostname: "outer.example", username: "ops")
        let inner = Host(name: "Inner", hostname: "10.0.0.5", username: "me", jump: JumpHost(bastion))
        store.save(bastion)
        store.save(outer)
        store.save(inner)
        #expect(store.dependents(of: bastion.id) == [inner])
        #expect(store.dependents(of: outer.id).isEmpty)
        bastion.jump = JumpHost(outer)
        store.save(bastion)
        #expect(store.hosts.first { $0.id == bastion.id }?.jump == nil)
        store.remove(at: IndexSet(integer: 0))
        #expect(store.hosts.first { $0.id == inner.id }?.jump == nil)
        #expect(store.dependents(of: bastion.id).isEmpty)
    }
}
