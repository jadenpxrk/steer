import Foundation
import Testing
import UIKit
@testable import Steer

struct AnsiSnapshotTests {
    @Test
    func previewKeepsAllColumnsAndRecentRows() {
        let text = (0..<90).map { "\u{1b}[32mrecent output \($0)" }.joined(separator: "\n")
        let desktop = AnsiGrid.parse(Array(text.utf8), cols: 320, rows: 100)
        let preview = desktop.preview(maxRows: 10)
        #expect(preview.cols == 320)
        #expect(preview.rows == 10)
        #expect(preview.rowStrings().first == "recent output 80")
        #expect(preview.rowStrings().last == "recent output 89")
        #expect(preview[0, 0].fg == desktop[0, 80].fg)
    }

    @Test
    func previewFitsFullWidthIncludingTheLastColumn() throws {
        let text = String(repeating: "x", count: 79) + "\u{1b}[48;2;0;255;0mZ\u{1b}[0m"
        let snapshot = TerminalPreviewSnapshot(bytes: Array(text.utf8))
        for width in [180.0, 398.0] {
            let image = AnsiSnapshotRenderer.image(from: snapshot, viewport: CGSize(width: width, height: 150))
            #expect(abs(image.size.width - width) < 0.01)
            #expect(image.size.height <= 150)
            let cgImage = try #require(image.cgImage)
            var rgba = [UInt8](repeating: 0, count: 4)
            try rgba.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: CGRect(x: 1 - cgImage.width, y: 1 - cgImage.height,
                                                width: cgImage.width, height: cgImage.height))
            }
            #expect(rgba[1] > 200)
            #expect(rgba[0] < 50)
            #expect(rgba[2] < 50)
        }
    }

    @Test
    func keepsTableGeometryOnOneRow() {
        let line = "┌" + String(repeating: "─", count: 20) + "┬" + String(repeating: "─", count: 20) + "┐"
        let bytes = Array(line.utf8)
        let grid = AnsiGrid.parse(bytes, cols: 0, rows: 0)
        #expect(grid.rows == 1)
        #expect(grid.cols == 43)
        #expect(grid[0, 0].glyph == "┌")
        #expect(grid[21, 0].glyph == "┬")
        #expect(grid[42, 0].glyph == "┐")
        #expect(grid[1, 0].glyph == "─")
    }

    @Test
    func parsesTruecolorAndBoxDrawing() {
        let text = "\u{1b}[48;2;20;20;20m\u{1b}[38;2;200;108;108m│\u{1b}[0m"
        let grid = AnsiGrid.parse(Array(text.utf8))
        #expect(grid.cols == 1)
        #expect(grid[0, 0].glyph == "│")
        #expect(grid[0, 0].bg == AnsiRGB(r: 20, g: 20, b: 20))
        #expect(grid[0, 0].fg == AnsiRGB(r: 200, g: 108, b: 108))
    }

    @Test
    func newlinesAdvanceRowsWithoutWrapping() {
        let text = "┌─┐\n│a│\n└─┘"
        let grid = AnsiGrid.parse(Array(text.utf8))
        #expect(grid.cols == 3)
        #expect(grid.rows == 3)
        #expect(grid[0, 0].glyph == "┌")
        #expect(grid[1, 1].glyph == "a")
        #expect(grid[2, 2].glyph == "┘")
    }

    @Test
    func layoutHintDoesNotShrinkAWideDump() {
        let line = String(repeating: "─", count: 123)
        let grid = AnsiGrid.parse(Array(line.utf8), cols: 80, rows: 24)
        #expect(grid.cols == 123)
        #expect(grid.rows == 24)
        #expect(grid[122, 0].glyph == "─")
    }

    @Test
    func honoursCursorPositioning() {
        let grid = AnsiGrid.parse(Array("\u{1b}[3;5HX".utf8), cols: 10, rows: 4)
        #expect(grid[4, 2].glyph == "X")
        #expect(grid[0, 0].glyph == " ")
    }

    @Test
    func eraseBelowClearsLaterRows() {
        let grid = AnsiGrid.parse(Array("first\nsecond\n\u{1b}[2;1H\u{1b}[J".utf8))
        #expect(grid.rowStrings().first == "first")
        let rest = grid.rowStrings().dropFirst().joined()
        #expect(rest.isEmpty)
    }

    @Test
    func wideCharactersTakeTwoColumns() {
        let grid = AnsiGrid.parse(Array("한a".utf8))
        #expect(grid.cols == 3)
        #expect(grid[0, 0].glyph == "한")
        #expect(grid[1, 0].glyph == " ")
        #expect(grid[2, 0].glyph == "a")
    }

    @Test
    func defaultColorsComeFromThePalette() {
        let light = TerminalPalette(name: "Light", background: "#F5F7FA", foreground: "#1F242E", cursor: "#1961D9", light: true)
        let grid = AnsiGrid.parse(Array("a\u{1b}[31mb".utf8), palette: light)
        #expect(grid[0, 0].fg == AnsiRGB(hex: "#1F242E"))
        #expect(grid[0, 0].bg == AnsiRGB(hex: "#F5F7FA"))
        #expect(grid[1, 0].bg == AnsiRGB(hex: "#F5F7FA"))
        #expect(grid[1, 0].fg != grid[0, 0].fg)
    }
}
