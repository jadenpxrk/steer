import Foundation
import Observation

/// Discovered Herdr/tmux/Zellij sessions for one connection and their preview snapshots.
@MainActor
@Observable
final class MuxCatalogLoader {
    var catalog: MuxCatalog?
    var previews: [String: TerminalPreviewSnapshot] = [:]
    private(set) var previewLoadingIDs: Set<String> = []
    var error: String?
    var isLoading = false

    /// Bumped by `reset`; results from an older connection are dropped.
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var loadID = 0
    @ObservationIgnored private var previewsLoading = false

    /// Keeps the last catalog on screen while reconnecting; a full disconnect clears it.
    func reset(keepingCatalog: Bool) {
        epoch += 1
        loadID += 1
        previews = [:]
        previewLoadingIDs = []
        previewsLoading = false
        error = nil
        if !keepingCatalog {
            catalog = nil
            isLoading = false
        }
    }

    func fail(_ message: String) {
        error = message
        catalog = nil
        isLoading = false
    }

    func load(exec: @escaping @MainActor (String) async throws -> SSHExecResult) async {
        guard !isLoading else { return }
        let epoch = epoch
        loadID += 1
        let loadID = loadID
        let isCurrent = { self.epoch == epoch && self.loadID == loadID }
        isLoading = true
        error = nil
        do {
            let catalog = try await MuxDiscovery.discover(exec: exec)
            guard isCurrent() else { return }
            self.catalog = catalog
            isLoading = false
            // Discovery can finish after the home screen's first preview request.
            // Start previews here without delaying terminal attachment.
            Task {
                guard isCurrent() else { return }
                await loadPreviews(exec: exec)
            }
        } catch is CancellationError {
            if isCurrent() { isLoading = false }
        } catch {
            guard isCurrent() else { return }
            fail(TerminalController.pickerMessage(for: error))
        }
    }

    func loadPreviews(exec: @escaping @MainActor (String) async throws -> SSHExecResult) async {
        guard !previewsLoading, let catalog else { return }
        previewsLoading = true
        let epoch = epoch
        let targets = catalog.previewTargets
        let validIDs = Set(targets.map(\.id))
        previews = previews.filter { validIDs.contains($0.key) }
        let requests = targets.compactMap { row -> (id: String, command: String)? in
            row.previewCommand.map { (row.id, $0) }
        }
        previewLoadingIDs = Set(requests.map(\.id))
        defer {
            if self.epoch == epoch {
                previewsLoading = false
                previewLoadingIDs = []
            }
        }
        // Three at a time leaves SSH channels free for the interactive terminal and discovery.
        for start in stride(from: 0, to: requests.count, by: 3) {
            guard self.epoch == epoch, !Task.isCancelled else { return }
            let refreshes = requests[start..<min(start + 3, requests.count)].map { request in
                Task { @MainActor in
                    defer {
                        if self.epoch == epoch { previewLoadingIDs.remove(request.id) }
                    }
                    guard let result = try? await exec(request.command), result.exitStatus == 0,
                          self.epoch == epoch else { return }
                    let bytes = result.stdoutData.isEmpty ? Array(result.stdout.utf8) : Array(result.stdoutData)
                    guard !bytes.isEmpty else { return }
                    previews[request.id] = TerminalPreviewSnapshot(bytes: bytes)
                }
            }
            for refresh in refreshes { await refresh.value }
        }
        if self.epoch == epoch, self.catalog?.previewTargets.map(\.id) != targets.map(\.id) {
            previewsLoading = false
            await loadPreviews(exec: exec)
        }
    }
}
