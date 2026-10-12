import Foundation

/// Recent terminal output for re-feeding a reattached view.
@MainActor
final class TerminalReplay {
    private(set) var bytes: [UInt8] = []
    private let limit: Int

    init(limit: Int = 2 * 1_024 * 1_024) {
        self.limit = limit
    }

    func append(_ output: ArraySlice<UInt8>) {
        bytes.append(contentsOf: output)
        // Trim in chunks so steady output doesn't shift the buffer on every write.
        if bytes.count > limit + limit / 4 {
            bytes.removeFirst(bytes.count - limit)
        }
    }

    func replace(with output: [UInt8] = []) {
        bytes = output
    }
}
