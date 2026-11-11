import AppKit
import CoreGraphics
import CoreText

/// The printable handwriting template: two A4 pages of boxes, one character per box, with a blue
/// baseline and a dashed x-height line to write on. Black squares in the corners let a photo of a
/// filled page be straightened (the top-left one is larger, so rotation is known), and small
/// squares under the title say which page it is.
///
/// Everything is in PDF points (A4 = 595 × 842, origin top-left here; flipped when drawing).
enum HandwritingTemplate {
    static let pageSize = CGSize(width: 595, height: 842)

    // Corner markers: centres and sizes.
    static let markerInset: CGFloat = 26
    static let markerSize: CGFloat = 16
    static let firstMarkerSize: CGFloat = 24
    static var markerCentres: [CGPoint] {  // TL, TR, BR, BL
        let a = markerInset + markerSize / 2
        return [CGPoint(x: a, y: a), CGPoint(x: pageSize.width - a, y: a),
                CGPoint(x: pageSize.width - a, y: pageSize.height - a), CGPoint(x: a, y: pageSize.height - a)]
    }

    // Page number squares, centred under the title.
    static let pageMarkSize: CGFloat = 8
    static func pageMarkCentres() -> [CGPoint] {
        (0..<2).map { CGPoint(x: pageSize.width / 2 - 8 + CGFloat($0) * 16, y: 92) }
    }

    // The grid of boxes.
    static let columns = 10
    static let rows = 12
    static let gridOrigin = CGPoint(x: 47.5, y: 112)
    static let cellSize = CGSize(width: 50, height: 56)
    /// From the top of a box: the x-height line and the baseline. The x-height (13 pt) is what a
    /// glyph's size is normalised from.
    static let xLine: CGFloat = 21
    static let baseline: CGFloat = 34
    static var xHeight: CGFloat { baseline - xLine }
    /// The printed character, top right; ignored when reading.
    static let labelBox = CGSize(width: 11, height: 10)

    struct Cell: Hashable {
        var page: Int  // 0-based
        var index: Int
        var character: Character
        var rect: CGRect {
            let col = index % columns, row = index / columns
            return CGRect(x: gridOrigin.x + CGFloat(col) * cellSize.width, y: gridOrigin.y + CGFloat(row) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        }
    }

    /// Math Writer's character set (its glyph library), with more samples of the common ones:
    /// small letters and digits three times, capitals and umlauts twice, symbols once.
    static let characters: [(Character, Int)] = {
        var list: [(Character, Int)] = []
        list += "abcdefghijklmnopqrstuvwxyz".map { ($0, 3) }
        list += "0123456789".map { ($0, 3) }
        list += "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { ($0, 2) }
        list += "äöüÄÖÜ".map { ($0, 2) }
        list += Array(".,:;!?'\"()[]{}|/+-*=<>^÷").map { ($0, 1) }
        list += Array("αβγθλπΣ∞∈∉⊂⊆∪∩∀∃≠≤≥√∫→←").map { ($0, 1) }
        return list
    }()

    static let cells: [Cell] = {
        let perPage = columns * rows
        var cells: [Cell] = []
        var n = 0
        for (character, count) in characters {
            for _ in 0..<count {
                cells.append(Cell(page: n / perPage, index: n % perPage, character: character))
                n += 1
            }
        }
        return cells
    }()

    static var pageCount: Int { (cells.count + columns * rows - 1) / (columns * rows) }

    // MARK: - PDF

    static func pdf() -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in 0..<pageCount {
            context.beginPDFPage(nil)
            // Draw top-down like the layout.
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            draw(page: page, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(page: Int, in context: CGContext) {
        // Corner markers.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for (i, centre) in markerCentres.enumerated() {
            let size = i == 0 ? firstMarkerSize : markerSize
            context.fill(CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size))
        }
        // Page number: page + 1 filled squares out of two.
        for (i, centre) in pageMarkCentres().enumerated() where i <= page {
            context.fill(CGRect(x: centre.x - pageMarkSize / 2, y: centre.y - pageMarkSize / 2, width: pageMarkSize, height: pageMarkSize))
        }

        let grey = CGColor(gray: 0.45, alpha: 1)
        text("Handwriting template · page \(page + 1) of \(pageCount)", at: CGPoint(x: 62, y: 46), size: 13, bold: true, color: grey, in: context)
        text("Write each character once per box with a dark pen, sitting on the blue line; small letters reach the dashed line.",
             at: CGPoint(x: 62, y: 64), size: 7.5, color: grey, in: context)
        text("Leave a box empty to skip it. Then take a straight, well-lit photo (all four black squares visible) or export the page from your iPad.",
             at: CGPoint(x: 62, y: 75), size: 7.5, color: grey, in: context)

        let border = CGColor(gray: 0.82, alpha: 1)
        let guide = CGColor(red: 0.55, green: 0.72, blue: 0.95, alpha: 1)
        let label = CGColor(gray: 0.62, alpha: 1)
        for cell in cells where cell.page == page {
            let rect = cell.rect
            context.setStrokeColor(border)
            context.setLineWidth(0.5)
            context.stroke(rect)
            context.setStrokeColor(guide)
            context.setLineWidth(0.6)
            context.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + baseline))
            context.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY + baseline))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [2, 2])
            context.setLineWidth(0.4)
            context.move(to: CGPoint(x: rect.minX + 3, y: rect.minY + xLine))
            context.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.minY + xLine))
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            text(String(cell.character), at: CGPoint(x: rect.maxX - labelBox.width + 1, y: rect.minY + 1), size: 7, color: label, in: context)
        }
    }

    /// Draws one line of text with its top-left at `point` (the context is flipped, top-down).
    private static func text(_ string: String, at point: CGPoint, size: CGFloat, bold: Bool = false, color: CGColor, in context: CGContext) {
        let font = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: color) ?? .gray,
        ]))
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: point.x, y: point.y + font.ascender)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
