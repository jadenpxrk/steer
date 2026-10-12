import Foundation
import Testing
@testable import Steer

struct HerdrTerminalSessionTests {
    @Test func controlUsesPhoneDimensionsAndQuotedPaneAndSession() {
        let command = MuxCommands.herdrControl(target: "pane';echo wrong", cols: 43, rows: 28, session: "work's")
        #expect(command.contains("terminal session control 'pane'\\'';echo wrong' --takeover --cols 43 --rows 28"))
        #expect(command.contains("herdr --session 'work'\\''s'"))
    }

    @Test func nativeInputPreservesArbitraryBytesInOneJSONRecord() throws {
        let bytes = Array(UInt8.min...UInt8.max) + Array("héllo\n\n\u{1b}[200~paste\u{1b}[201~".utf8)
        let encoded = HerdrTerminalCommand.input(bytes[...])
        let object = try #require(JSONSerialization.jsonObject(with: Data(encoded)) as? [String: String])
        #expect(object["type"] == "terminal.input")
        #expect(Data(base64Encoded: try #require(object["bytes"])) == Data(bytes))
        #expect(encoded.filter { $0 == 10 }.count == 1)
    }

    @Test func resizeAndScrollUseNativeViewportCommands() throws {
        let resize = try #require(JSONSerialization.jsonObject(with: Data(HerdrTerminalCommand.resize(cols: 43, rows: 12))) as? [String: Any])
        #expect(resize["type"] as? String == "terminal.resize")
        #expect(resize["cols"] as? Int == 43)
        #expect(resize["rows"] as? Int == 12)
        let scroll = try #require(JSONSerialization.jsonObject(with: Data(HerdrTerminalCommand.scroll(lines: -4, column: 2, row: 3))) as? [String: Any])
        #expect(scroll["type"] as? String == "terminal.scroll")
        #expect(scroll["direction"] as? String == "down")
        #expect(scroll["source"] as? String == "wheel")
        #expect(scroll["lines"] as? Int == 4)
        #expect(scroll["column"] as? Int == 2)
        #expect(scroll["row"] as? Int == 3)
        #expect(HerdrTerminalCommand.scroll(lines: 0, column: 0, row: 0).isEmpty)
        #expect(String(decoding: HerdrTerminalCommand.release, as: UTF8.self) == "{\"type\":\"terminal.release\"}\n")
    }

    @Test @MainActor func aBurstPreservesNativeDeltasAndClosingCancelsPendingPaint() async {
        let live = HerdrLiveSession(paneID: "fixture", generation: 1, cols: 43, rows: 28)
        let frames = (1...120).map { seq in
            HerdrTerminalFrame(seq: seq, width: 43, height: 28, full: seq == 1,
                               bytes: Array("\u{1b}[2;2H\(seq)".utf8))
        }
        for frame in frames { #expect(live.enqueue(frame)) }
        var paints: [[HerdrTerminalFrame]] = []
        live.renderPendingFrames { paints.append($0) }
        await live.renderTask?.value
        #expect(paints == [frames])
        #expect(live.enqueue(.init(seq: 121, width: 43, height: 28, full: false, bytes: [65])))
        live.renderPendingFrames { paints.append($0) }
        live.close()
        await live.renderTask?.value
        #expect(paints.count == 1)
        #expect(!live.acceptsInput)
        #expect(!live.enqueue(frames[0]))
    }

    @Test @MainActor func leavingDuringAttachCancelsReadiness() async throws {
        let live = HerdrLiveSession(paneID: "fixture", generation: 1, cols: 43, rows: 28)
        let waiting = Task { try await live.waitUntilReady(timeout: .seconds(2)) }
        await Task.yield()
        live.close()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(live.isDead)
    }

    @Test @MainActor func readinessDeadlineCannotKillAConnectedSession() async throws {
        let live = HerdrLiveSession(paneID: "fixture", generation: 1, cols: 43, rows: 28)
        defer { live.close() }
        let waiting = Task { try await live.waitUntilReady(timeout: .milliseconds(40)) }
        await Task.yield()
        live.markReady()
        try await waiting.value
        try await Task.sleep(for: .milliseconds(60))
        #expect(!live.isDead)
    }

    @Test func parserRejectsInvalidBase64WithoutAdvancingSequence() {
        var parser = HerdrStreamParser()
        let invalid = "{\"type\":\"terminal.frame\",\"seq\":1,\"width\":40,\"height\":12,\"full\":true,\"bytes\":\"%%%\"}\n"
        let events = parser.push(Array(invalid.utf8)[...])
        #expect(!events.contains { if case .frame = $0 { return true }; return false })
        let valid = parser.push(Array(frameJSON(seq: 1, width: 40, height: 12, text: "valid").utf8)[...])
        #expect(valid.contains { if case .frame = $0 { return true }; return false })
    }

    @Test func parserRejectsOlderFullFrameWithinSameStream() {
        var parser = HerdrStreamParser()
        _ = parser.push(Array(frameJSON(seq: 5, width: 40, height: 12, text: "new").utf8)[...])
        let stale = parser.push(Array(frameJSON(seq: 4, width: 40, height: 12, text: "old").utf8)[...])
        #expect(!stale.contains { if case .frame = $0 { return true }; return false })
    }

    @Test func parserEmitsFramesRejectsStaleSeqAndSurvivesTruncation() {
        var parser = HerdrStreamParser()
        let first = frameJSON(seq: 1, width: 80, height: 24, text: "abc")
        let second = frameJSON(seq: 2, width: 80, height: 24, text: "def")
        let split = first.index(first.startIndex, offsetBy: 20)
        #expect(parser.push(Array(first[..<split].utf8)[...]).isEmpty)
        let rest = Array(first[split...].utf8) + Array(second.utf8)
        let events = parser.push(rest[...])
        guard events.count == 2,
              case .frame(let a) = events[0],
              case .frame(let b) = events[1] else {
            Issue.record("expected two frames")
            return
        }
        #expect(a.seq == 1)
        #expect(String(decoding: a.bytes, as: UTF8.self) == "abc")
        #expect(b.seq == 2)
        let stale = parser.push(Array(frameJSON(seq: 2, width: 80, height: 24, text: "dup").utf8)[...])
        #expect(stale == [.ignored])
        let closed = parser.push(Array("{\"type\":\"terminal.closed\",\"reason\":\"gone\"}\n".utf8)[...])
        #expect(closed == [.closed("gone")])
        let malformed = parser.push(Array("{not json\n".utf8)[...])
        #expect(malformed == [.ignored])
        let missing = parser.push(Array("herdr: unknown command terminal\n".utf8)[...])
        guard case .closed(let reason) = missing.first else {
            Issue.record("expected capability close")
            return
        }
        #expect(reason == HerdrSessionError.observeUnavailable.errorDescription)
    }

    @Test func parserRejectsOversizedDimensions() {
        var parser = HerdrStreamParser()
        let huge = "{\"type\":\"terminal.frame\",\"seq\":1,\"width\":99999,\"height\":99999,\"full\":true,\"bytes\":\"\"}\n"
        let events = parser.push(Array(huge.utf8)[...])
        #expect(!events.contains { if case .frame = $0 { return true }; return false })
    }

}

private func frameJSON(seq: Int, width: Int, height: Int, text: String) -> String {
    let bytes = Data(text.utf8).base64EncodedString()
    return """
    {"type":"terminal.frame","seq":\(seq),"encoding":"ansi","width":\(width),"height":\(height),"full":true,"bytes":"\(bytes)"}\n
    """
}
