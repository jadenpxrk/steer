import Foundation

/// Mosh-style local echo: typed characters are drawn ahead of the server, as an overlay, never into the terminal
/// buffer (the server's screen diffs assume that buffer matches its screen). Like mosh, nothing is shown until an
/// earlier prediction in the same epoch has been confirmed on screen, so password prompts never display input.
struct MoshPredictor {
    struct Cell: Equatable {
        let row: Int
        let col: Int
        let character: Character
        /// Input events that must be echoed before this cell can be checked against the screen.
        let eventCount: Int
    }

    private(set) var pending: [Cell] = []
    private var epochConfirmed = false
    private var epochBroken = false

    var visible: [Cell] { epochConfirmed && !epochBroken ? pending : [] }

    /// `cursor` and `cols` describe the server's screen; `eventCount` is the input-stream length including these bytes.
    mutating func typed(_ bytes: [UInt8], cursor: (col: Int, row: Int), cols: Int, eventCount: Int) {
        for byte in bytes {
            switch byte {
            case 0x20...0x7E:
                let col = cursor.col + pending.filter { $0.row == cursor.row }.count
                guard col < cols else { return resetEpoch() }
                pending.append(Cell(row: cursor.row, col: col, character: Character(UnicodeScalar(byte)), eventCount: eventCount))
            case 0x7F where !pending.isEmpty:
                pending.removeLast()
            default:
                // Enter, control keys, and escape sequences can do anything; start a fresh, unconfirmed epoch.
                resetEpoch()
                return
            }
        }
    }

    /// Checks predictions the server has echoed against its screen and drops them.
    mutating func confirm(echoedEventCount: Int, screen: (Int, Int) -> Character?) {
        let echoed = pending.filter { $0.eventCount <= echoedEventCount }
        for cell in echoed {
            if screen(cell.col, cell.row) == cell.character {
                epochConfirmed = true
            } else {
                epochBroken = true
            }
        }
        pending.removeAll { $0.eventCount <= echoedEventCount }
    }

    mutating func resetEpoch() {
        pending.removeAll()
        epochConfirmed = false
        epochBroken = false
    }
}
