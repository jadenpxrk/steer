import CoreText
import SwiftTerm
import UIKit

struct AnsiRGB: Equatable, Sendable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// `#RRGGBB`, as stored in `TerminalPalette`.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(r: UInt8((value >> 16) & 255), g: UInt8((value >> 8) & 255), b: UInt8(value & 255))
    }

    var uiColor: UIColor {
        UIColor(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: 1
        )
    }
}

struct AnsiCell: Equatable, Sendable {
    var scalar: Unicode.Scalar
    var fg: AnsiRGB
    var bg: AnsiRGB
    var bold: Bool
    var dim: Bool
    var inverse: Bool

    var glyph: Character { Character(scalar) }

    var paintFg: AnsiRGB {
        let color = inverse ? bg : fg
        if dim {
            return AnsiRGB(r: color.r / 2, g: color.g / 2, b: color.b / 2)
        }
        return color
    }

    var paintBg: AnsiRGB { inverse ? fg : bg }
}

struct AnsiGrid: Equatable, Sendable {
    var cols: Int
    var rows: Int
    var cells: [AnsiCell]

    subscript(col: Int, row: Int) -> AnsiCell {
        get { cells[row * cols + col] }
        set { cells[row * cols + col] = newValue }
    }

    func preview(maxRows: Int) -> AnsiGrid {
        let lastContentRow = (0..<rows).last { row in
            (0..<cols).contains { self[$0, row].scalar != " " }
        } ?? 0
        let firstRow = max(0, lastContentRow + 1 - max(maxRows, 1))
        let height = lastContentRow - firstRow + 1
        let cropped = Array(cells[(firstRow * cols)..<((lastContentRow + 1) * cols)])
        return AnsiGrid(cols: cols, rows: height, cells: cropped)
    }

    /// Parses a pane dump with SwiftTerm. Hints are minimums: dumps never wrap, so the
    /// grid widens to the longest line instead of reflowing it.
    static func parse(_ bytes: [UInt8], cols hintCols: Int = 0, rows hintRows: Int = 0, palette: TerminalPalette = .midnight) -> AnsiGrid {
        let foreground = AnsiRGB(hex: palette.foreground)
        let background = AnsiRGB(hex: palette.background)
        let blank = AnsiCell(scalar: " ", fg: foreground, bg: background, bold: false, dim: false, inverse: false)
        let lineCount = bytes.reduce(1) { $1 == 0x0a ? $0 + 1 : $0 }
        let canvasCols = max(hintCols, 1_024)
        let height = max(hintRows, min(lineCount, 2_000), 1)
        let terminal = Terminal(
            delegate: HeadlessTerminal.shared,
            options: TerminalOptions(cols: canvasCols, rows: height, convertEol: true, scrollback: 0)
        )
        terminal.feed(byteArray: bytes)

        var usedCols = 0
        for row in 0..<height {
            guard let line = terminal.getLine(row: row) else { continue }
            if let last = (0..<canvasCols).last(where: { !isBlank(terminal.getCharacter(for: line[$0])) }) {
                usedCols = max(usedCols, last + Int(max(line[last].width, 1)))
            }
        }
        let width = max(hintCols, usedCols, 1)
        var cells: [AnsiCell] = []
        cells.reserveCapacity(width * height)
        for row in 0..<height {
            let line = terminal.getLine(row: row)
            for col in 0..<width {
                cells.append(line.map { cell(from: $0[col], in: terminal, foreground: foreground, background: background) } ?? blank)
            }
        }
        return AnsiGrid(cols: width, rows: height, cells: cells)
    }

    private static func cell(from data: CharData, in terminal: Terminal, foreground: AnsiRGB, background: AnsiRGB) -> AnsiCell {
        let style = data.attribute.style
        // Width 0 marks the right half of a wide character; its glyph is drawn by the left half.
        let character = terminal.getCharacter(for: data)
        let scalar = data.width == 0 || isBlank(character) ? " " : character.unicodeScalars.first ?? " "
        return AnsiCell(
            scalar: scalar,
            fg: rgb(data.attribute.fg, default: foreground),
            bg: rgb(data.attribute.bg, default: background),
            bold: style.contains(.bold),
            dim: style.contains(.dim),
            inverse: style.contains(.inverse)
        )
    }

    private static func isBlank(_ character: Character) -> Bool {
        character == " " || character == "\0"
    }

    private static func rgb(_ color: Attribute.Color, default fallback: AnsiRGB) -> AnsiRGB {
        switch color {
        case .ansi256(let code): indexed(Int(code))
        case .trueColor(let red, let green, let blue): AnsiRGB(r: red, g: green, b: blue)
        case .defaultColor, .defaultInvertedColor: fallback
        }
    }

    private static func ansi16(_ index: Int, bright: Bool) -> AnsiRGB {
        let base: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (205, 49, 49), (19, 161, 14), (193, 156, 0),
            (0, 55, 218), (136, 23, 152), (58, 150, 221), (204, 204, 204),
        ]
        let lite: [(UInt8, UInt8, UInt8)] = [
            (118, 118, 118), (241, 76, 76), (22, 198, 12), (249, 241, 165),
            (59, 120, 255), (180, 0, 158), (97, 214, 214), (242, 242, 242),
        ]
        let rgb = (bright ? lite : base)[min(max(index, 0), 7)]
        return AnsiRGB(r: rgb.0, g: rgb.1, b: rgb.2)
    }

    private static func indexed(_ n: Int) -> AnsiRGB {
        let i = min(max(n, 0), 255)
        if i < 8 { return ansi16(i, bright: false) }
        if i < 16 { return ansi16(i - 8, bright: true) }
        if i < 232 {
            let v = i - 16
            func level(_ x: Int) -> UInt8 { x == 0 ? 0 : UInt8(55 + x * 40) }
            return AnsiRGB(r: level(v / 36), g: level((v / 6) % 6), b: level(v % 6))
        }
        let g = UInt8(clamping: 8 + (i - 232) * 10)
        return AnsiRGB(r: g, g: g, b: g)
    }
}

enum AnsiSnapshotRenderer {
    static func image(from snapshot: TerminalPreviewSnapshot, viewport: CGSize, palette: TerminalPalette = .midnight) -> UIImage {
        let grid = AnsiGrid.parse(snapshot.bytes, palette: palette)
        let font = font(at: 12)
        let cell = cellSize(for: font)
        let scale = min(max(viewport.width, 1) / (CGFloat(grid.cols) * cell.width), 1)
        return image(from: grid.preview(
            maxRows: Int(max(viewport.height, 1) / (cell.height * scale))
        ), scale: scale)
    }

    private static func font(at size: CGFloat) -> UIFont {
        TerminalFontRegistry.registerBundledFonts()
        return UIFont(name: "JetBrainsMono-Regular", size: size)
            ?? UIFont(name: "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func cellSize(for font: UIFont) -> CGSize {
        CGSize(width: max(ceil("W".size(withAttributes: [.font: font]).width), 1),
               height: max(ceil(font.lineHeight), ceil(font.ascender - font.descender + font.leading), 1))
    }

    static func image(from grid: AnsiGrid, fontSize: CGFloat = 12, scale: CGFloat = 1) -> UIImage {
        let font = font(at: fontSize)
        let cell = cellSize(for: font)
        let cellW = cell.width
        let cellH = cell.height
        let size = CGSize(width: cellW * CGFloat(grid.cols) * scale, height: cellH * CGFloat(grid.rows) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.scaleBy(x: scale, y: scale)
            func rect(_ col: Int, _ row: Int) -> CGRect {
                CGRect(x: CGFloat(col) * cellW, y: CGFloat(row) * cellH, width: cellW, height: cellH)
            }
            // Backgrounds first so wide glyphs can overflow into the next cell.
            for row in 0..<grid.rows {
                for col in 0..<grid.cols {
                    grid[col, row].paintBg.uiColor.setFill()
                    ctx.fill(rect(col, row))
                }
            }
            for row in 0..<grid.rows {
                for col in 0..<grid.cols {
                    let cell = grid[col, row]
                    let box = rect(col, row)
                    if cell.scalar == " " || drawBox(cell.scalar, in: box, color: cell.paintFg.uiColor, context: cg) {
                        continue
                    }
                    let face = cell.bold
                        ? UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor, size: fontSize)
                        : font
                    (String(cell.glyph) as NSString).draw(
                        at: CGPoint(x: box.minX, y: box.minY + (cellH - face.lineHeight) / 2),
                        withAttributes: [.font: face, .foregroundColor: cell.paintFg.uiColor]
                    )
                }
            }
        }
    }

    private static func drawBox(
        _ scalar: Unicode.Scalar,
        in cell: CGRect,
        color: UIColor,
        context: CGContext
    ) -> Bool {
        let value = scalar.value
        if value == 0x2588 {
            context.setFillColor(color.cgColor)
            context.fill(cell)
            return true
        }
        if value == 0x2584 {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: cell.minX, y: cell.midY, width: cell.width, height: cell.height / 2))
            return true
        }
        if value == 0x2580 {
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: cell.height / 2))
            return true
        }
        let light: Set<UInt32> = [
            0x2500, 0x2502, 0x250C, 0x2510, 0x2514, 0x2518,
            0x251C, 0x2524, 0x252C, 0x2534, 0x253C,
            0x256D, 0x256E, 0x256F, 0x2570,
        ]
        let heavy: Set<UInt32> = [0x2501, 0x2503]
        guard light.contains(value) || heavy.contains(value) else { return false }
        let cx = cell.midX
        let cy = cell.midY
        let thickness = max(1.1, min(cell.width, cell.height) * (heavy.contains(value) ? 0.22 : 0.13))
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(thickness)
        context.setLineCap(.butt)
        func h(_ x0: CGFloat, _ x1: CGFloat) {
            context.move(to: CGPoint(x: x0, y: cy))
            context.addLine(to: CGPoint(x: x1, y: cy))
            context.strokePath()
        }
        func v(_ y0: CGFloat, _ y1: CGFloat) {
            context.move(to: CGPoint(x: cx, y: y0))
            context.addLine(to: CGPoint(x: cx, y: y1))
            context.strokePath()
        }
        switch value {
        case 0x2500, 0x2501: h(cell.minX, cell.maxX)
        case 0x2502, 0x2503: v(cell.minY, cell.maxY)
        case 0x250C, 0x256D:
            h(cx, cell.maxX)
            v(cy, cell.maxY)
        case 0x2510, 0x256E:
            h(cell.minX, cx)
            v(cy, cell.maxY)
        case 0x2514, 0x2570:
            h(cx, cell.maxX)
            v(cell.minY, cy)
        case 0x2518, 0x256F:
            h(cell.minX, cx)
            v(cell.minY, cy)
        case 0x251C:
            h(cx, cell.maxX)
            v(cell.minY, cell.maxY)
        case 0x2524:
            h(cell.minX, cx)
            v(cell.minY, cell.maxY)
        case 0x252C:
            h(cell.minX, cell.maxX)
            v(cy, cell.maxY)
        case 0x2534:
            h(cell.minX, cell.maxX)
            v(cell.minY, cy)
        case 0x253C:
            h(cell.minX, cell.maxX)
            v(cell.minY, cell.maxY)
        default:
            context.restoreGState()
            return false
        }
        context.restoreGState()
        return true
    }
}

private final class HeadlessTerminal: TerminalDelegate, @unchecked Sendable {
    static let shared = HeadlessTerminal()
    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}
}
