import Foundation

@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [Host] {
        didSet { persist() }
    }

    private let defaults: UserDefaults
    private let storageKey = "hosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hosts = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([Host].self, from: $0) } ?? []
    }

    func save(_ host: Host) {
        var host = host
        if !dependents(of: host.id).isEmpty { host.jump = nil }
        var next = hosts
        if let index = next.firstIndex(where: { $0.id == host.id }) {
            next[index] = host
        } else {
            next.append(host)
        }
        for index in next.indices where next[index].jump?.id == host.id {
            next[index].jump = JumpHost(host)
        }
        hosts = next
    }

    func dependents(of hostID: UUID) -> [Host] {
        hosts.filter { $0.jump?.id == hostID }
    }

    func remove(at offsets: IndexSet) {
        for id in offsets.map({ hosts[$0].id }) {
            KeychainStore.removeCredentials(for: id)
            SSHHostKeyStore.shared.remove(hostID: id)
        }
        let removed = Set(offsets.map { hosts[$0].id })
        var next = hosts
        next.remove(atOffsets: offsets)
        for index in next.indices where next[index].jump.map({ removed.contains($0.id) }) == true {
            next[index].jump = nil
        }
        hosts = next
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
