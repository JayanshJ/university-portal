import CoreGraphics
import Foundation

/// Renders Math Writer markup (see Math Writer's MARKUP.md) as handwritten A4
/// pages: a Swift port of `render.py`, `validate.py` and `charset.py`.
/// Pure functions, safe to call from any task.
enum HandwritingRenderer {
    struct Validation: Sendable {
        var errors: [String]
        var warnings: [String]
    }

    /// Page size in pixels (A4 at 200 dpi).
    static let pageSize = (width: 1654, height: 2339)
    static let dpi = 200.0
    /// Apple-Pencil blue, #0F46B4.
    static let inkRGB: (UInt8, UInt8, UInt8) = (15, 70, 180)

    /// validate.py + charset.py, with "known characters" taken from the given library.
    static func validate(_ markup: String, library: GlyphLibrary) -> Validation {
        HandwritingValidator.validate(markup, known: library.characters)
    }

    /// render_pages(): A4 pages 1654×2339 px with render.py's defaults (iPad-style
    /// grid paper, blue ink #0F46B4, jitter). `dropped` = characters with no
    /// glyph and no fallback, with how often each was skipped.
    static func render(_ markup: String, library: GlyphLibrary, seed: UInt64? = nil)
        -> (pages: [CGImage], dropped: [Character: Int]) {
        let engine = HandwritingEngine(library: library, seed: seed ?? UInt64.random(in: .min ... .max))
        let layout = PageLayout(engine: engine)
        let pages = layout.render(markup.replacingOccurrences(of: "\r\n", with: "\n"))
        return (pages.compactMap(makePageImage), engine.dropped)
    }

    /// The pages as a PDF at 200 dpi (A4), like solve.py.
    static func pdf(_ pages: [CGImage]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var box = CGRect(x: 0, y: 0,
                         width: Double(pageSize.width) * 72 / dpi,
                         height: Double(pageSize.height) * 72 / dpi)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for page in pages {
            var mediaBox = CGRect(x: 0, y: 0,
                                  width: Double(page.width) * 72 / dpi,
                                  height: Double(page.height) * 72 / dpi)
            let info = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)]
            ctx.beginPDFPage(info as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(page, in: mediaBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// Grid paper (white, 40 px grid in #C8D2DC) with the ink laid over it.
    private static func makePageImage(_ ink: AlphaBitmap) -> CGImage? {
        let w = ink.width, h = ink.height
        let grid = 40
        let line: (Int, Int, Int) = (200, 210, 220)
        var rgb = [UInt8](repeating: 255, count: w * h * 3)
        let (ir, ig, ib) = (Int(inkRGB.0), Int(inkRGB.1), Int(inkRGB.2))
        ink.data.withUnsafeBufferPointer { a in
            rgb.withUnsafeMutableBufferPointer { p in
                for y in 0..<h {
                    let onRow = y % grid == 0
                    for x in 0..<w {
                        let i = y * w + x
                        var (r, g, b) = (onRow || x % grid == 0) ? line : (255, 255, 255)
                        let alpha = Int(a[i])
                        if alpha > 0 {
                            r = (ir * alpha + r * (255 - alpha) + 127) / 255
                            g = (ig * alpha + g * (255 - alpha) + 127) / 255
                            b = (ib * alpha + b * (255 - alpha) + 127) / 255
                        }
                        p[i * 3] = UInt8(r); p[i * 3 + 1] = UInt8(g); p[i * 3 + 2] = UInt8(b)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The page layout loop of `render_pages()`: word wrap, line and page breaks,
/// per-line slope and start jitter, letter connectors and header underlines.
private final class PageLayout {
    // render_pages() defaults.
    let W = HandwritingRenderer.pageSize.width
    let H = HandwritingRenderer.pageSize.height
    let marginTop = 85, marginBottom = 90, marginLeft = 80, marginRightMin = 55
    let lineHeight = 64
    let scale = 1.45
    let spaceWidth = 22
    let rotateJitter = 1.8
    let baselineJitter = 2
    let sizeJitter = 0.03
    let spacingJitter = 3
    let lineStartJitter = 10
    let lineSlopeJitter = 0.008
    let lineHeightJitter = 3

    let engine: HandwritingEngine
    var pages: [AlphaBitmap] = []
    var canvas = AlphaBitmap(width: 1, height: 1)
    var x = 0, y = 0, lineY = 0, lineXStart = 0
    var lineSlope = 0.0
    var wordBaselineOffset = 0
    var last: [Character: Int] = [:]

    var maxX: Int { W - marginRightMin }
    var maxY: Int { H - marginBottom }
    var rng: SeededRandom {
        get { engine.rng }
        set { engine.rng = newValue }
    }

    init(engine: HandwritingEngine) {
        self.engine = engine
    }

    func newPage() {
        canvas = AlphaBitmap(width: W, height: H)
        lineY = marginTop + rng.randint(-6, 12)
        lineXStart = marginLeft + rng.randint(-lineStartJitter, lineStartJitter)
        lineSlope = rng.uniform(-lineSlopeJitter, lineSlopeJitter)
        x = lineXStart
        y = lineY
    }

    func finishPage() {
        pages.append(canvas)
    }

    func newLine(extra: Int = 0) {
        lineY += lineHeight + rng.randint(-lineHeightJitter, lineHeightJitter) + extra
        lineXStart = marginLeft + rng.randint(-lineStartJitter, lineStartJitter)
        lineSlope = 0.6 * lineSlope + 0.4 * rng.uniform(-lineSlopeJitter, lineSlopeJitter)
        x = lineXStart
        y = lineY
        if y > maxY {
            finishPage()
            newPage()
        }
    }

    func baseline() -> Int {
        let slopeDy = Int(lineSlope * Double(x - lineXStart))
        return y + Int(Double(lineHeight) * 0.78) + slopeDy + wordBaselineOffset
    }

    /// Paste a block (matrix, fraction, …) at the cursor, on the baseline.
    func pasteBlock(_ block: HandwritingEngine.Block, extraAdvance: Int = 8) {
        let (img, blockBl) = block
        let bw = img.width, bh = img.height
        var py = baseline() - blockBl
        if py < 10 || py + bh > maxY + 40 {
            newLine(extra: Int(Double(bh) * 0.4))
            py = baseline() - blockBl
        }
        if x + bw > maxX && x > lineXStart + 5 {
            newLine(extra: Int(Double(bh) * 0.4))
            py = baseline() - blockBl
        }
        canvas.composite(img, x: x, y: py)
        x += bw + extraAdvance
        let bottom = py + bh
        let lineBottom = y + lineHeight
        if bottom > lineBottom { lineY += bottom - lineBottom }
    }

    /// Where the pen leaves (`right`) or enters (`left`) a glyph near its baseline.
    static func penPoint(_ img: AlphaBitmap, baseline: Int, right: Bool,
                         band: Int = 14, threshold: UInt8 = 80) -> (Int, Int)? {
        let y0 = max(0, baseline - band / 2)
        let y1 = min(img.height, baseline + band / 2 + 2)
        guard y0 < y1 else { return nil }
        var col: Int?
        let xs = right ? Array((0..<img.width).reversed()) : Array(0..<img.width)
        search: for cx in xs {
            for yy in y0..<y1 where img.data[yy * img.width + cx] > threshold {
                col = cx
                break search
            }
        }
        guard let cx = col else { return nil }
        var total = 0.0, weighted = 0.0
        for yy in y0..<y1 {
            let a = Double(img.data[yy * img.width + cx])
            total += a
            weighted += a * Double(yy - y0)
        }
        guard total > 0 else { return nil }
        return (cx, Int((Double(y0) + weighted / total).rounded()))
    }

    /// Bezier connector arcing over the gap between two letters.
    func drawConnector(_ p1: (Double, Double), _ p2: (Double, Double), width: Double = 3) {
        let dist = hypot(p2.0 - p1.0, p2.1 - p1.1)
        if dist < 3 || dist > 80 { return }
        let arc = max(2.5, min(8.0, dist * 0.22))
        let midX = (p1.0 + p2.0) / 2 + rng.uniform(-0.8, 0.8)
        let midY = min(p1.1, p2.1) - arc + rng.uniform(-0.6, 0.6)
        let n = max(8, Int(dist / 4))
        var pts: [(Double, Double)] = []
        for k in 0...n {
            let t = Double(k) / Double(n)
            var px = (1 - t) * (1 - t) * p1.0 + 2 * (1 - t) * t * midX + t * t * p2.0
            var py = (1 - t) * (1 - t) * p1.1 + 2 * (1 - t) * t * midY + t * t * p2.1
            if 0 < k && k < n {
                let wob = sin(.pi * t) * rng.uniform(-0.35, 0.35)
                px += wob
                py += wob * 0.5
            }
            pts.append((px, py))
        }
        canvas.stroke(HandwritingEngine.ink(pts), width: width)
    }

    /// Joins multi-line `[M]`/`[F]`/`[S]`/`[B]`/`[T]` blocks onto one line.
    static func joinBlocks(_ text: String) -> String {
        let chars = Array(text)
        var out: [Character] = []
        var pos = 0
        for m in HandwritingMarkup.tagMatches(chars, tags: Set("MFSBT")) {
            out += chars[pos..<m.range.lowerBound]
            out += chars[m.range].map { $0 == "\n" ? HandwritingMarkup.marker : $0 }
            pos = m.range.upperBound
        }
        out += chars[pos...]
        let marker = String(HandwritingMarkup.marker)
        return String(out).replacingOccurrences(of: marker + marker, with: marker)
    }

    func render(_ text: String) -> [AlphaBitmap] {
        newPage()
        let joined = Self.joinBlocks(text)
        for rawPara in joined.split(separator: "\n", omittingEmptySubsequences: false) {
            var para = String(rawPara)
            if para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newLine(extra: Int(Double(lineHeight) * 0.25))
                continue
            }
            var headerUnderline = false
            let trimmedRight = String(para.reversed().drop(while: { $0.isWhitespace }).reversed())
            if para.hasPrefix("~~") && trimmedRight.hasSuffix("~~") {
                let c = Array(trimmedRight)
                let end = c.count - 2 // rfind("~~") on a string ending in "~~"
                para = end > 2 ? String(c[2..<end]) : ""
                headerUnderline = true
            }
            var headerStartX: Int?
            var headerBaseline: Int?

            for tok in HandwritingMarkup.tokenize(para) {
                switch tok {
                case .text(let content):
                    for word in Self.splitSpaces(content) {
                        if word.allSatisfy(\.isWhitespace) {
                            x += spaceWidth * word.count + rng.randint(-3, 4)
                            continue
                        }
                        layoutWord(word, headerUnderline: headerUnderline,
                                   headerStartX: &headerStartX, headerBaseline: &headerBaseline)
                    }
                case .matrix(let rows, let dividers):
                    pasteBlock(engine.renderMatrix(rows, scale: scale * 0.78, dividers: dividers), extraAdvance: 14)
                case .frac(let n, let d):
                    pasteBlock(engine.renderFraction(n, d, scale: scale * 0.78), extraAdvance: 8)
                case .sum(let lo, let up):
                    pasteBlock(engine.renderSum(lo, up, scale: scale * 0.78), extraAdvance: 10)
                case .box(let c):
                    pasteBlock(engine.renderBox(c, scale: scale * 0.9), extraAdvance: 8)
                case .table(let rows):
                    // Paragraph-level block: top at the current line.
                    if x > lineXStart + 5 { newLine() }
                    let block = engine.renderTable(rows, scale: scale * 0.78).image
                    if y + block.height > maxY {
                        finishPage()
                        newPage()
                    }
                    let py = y + 4
                    canvas.composite(block, x: x, y: py)
                    lineY = py + block.height - lineHeight + 8
                    newLine()
                case .arrow:
                    pasteBlock(engine.renderArrowGlyph(scale: scale) ?? engine.renderArrow(scale: scale), extraAdvance: 4)
                case .approx:
                    pasteBlock(engine.renderApprox(scale: scale), extraAdvance: 4)
                case .integral:
                    pasteBlock(engine.renderIntegralGlyph(scale: scale) ?? engine.renderIntegral(scale: scale), extraAdvance: 4)
                case .integralBounded(let lo, let up):
                    pasteBlock(engine.renderIntegralBounded(lo, up, scale: scale), extraAdvance: 4)
                case .strike(let c):
                    pasteBlock(engine.renderStrike(c, scale: scale * 0.95), extraAdvance: 4)
                case .vec(let c):
                    pasteBlock(engine.renderVec(c, scale: scale), extraAdvance: 4)
                case .hat(let c):
                    pasteBlock(engine.renderHat(c, scale: scale), extraAdvance: 4)
                case .sqrt(let c):
                    pasteBlock(engine.renderSqrt(c, scale: scale), extraAdvance: 4)
                case .down(let c):
                    pasteBlock(engine.renderDown(c, scale: scale), extraAdvance: 4)
                case .up(let c):
                    pasteBlock(engine.renderUp(c, scale: scale), extraAdvance: 4)
                }
            }

            if headerUnderline, let startX = headerStartX, let hb = headerBaseline {
                let ux1 = Double(startX - 4)
                let ux2 = Double(x - spaceWidth + 4)
                let uy = Double(hb + 6 + rng.randint(-1, 2))
                let mid = Double(Int(floor((ux1 + ux2) / 2)))
                let pts = [(ux1, uy + rng.uniform(-1, 1)), (mid, uy + rng.uniform(-1, 1)), (ux2, uy + rng.uniform(-1, 1))]
                canvas.stroke(HandwritingEngine.ink(pts), width: 3)
            }
            newLine()
        }
        finishPage()
        return pages
    }

    /// `re.split(r'( +)', s)`: words and the runs of spaces between them.
    static func splitSpaces(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inSpaces = false
        for ch in s {
            let isSpace = ch == " "
            if isSpace != inSpaces, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            inSpaces = isSpace
            cur.append(ch)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func layoutWord(_ word: String, headerUnderline: Bool,
                            headerStartX: inout Int?, headerBaseline: inout Int?) {
        // Estimate the width to decide on wrapping.
        var est = 0
        for ch in word {
            var scratch: [Character: Int] = [:]
            let g = engine.pickGlyph(ch, last: &scratch, countDrop: false)
            est += Int(Double(g?.w ?? 14) * scale) + Int(6 * scale)
        }
        if x + est > maxX && x > lineXStart + 5 { newLine() }
        if headerUnderline && headerStartX == nil { headerStartX = x }
        // One baseline offset per word: letters within a word stay aligned.
        wordBaselineOffset = rng.randint(-baselineJitter, baselineJitter)
        var prev: (Double, Double, Character)?
        for ch in word {
            guard let glyph = engine.pickGlyph(ch, last: &last) else {
                x += 12
                prev = nil
                continue
            }
            let s = scale * (1 + rng.uniform(-sizeJitter, sizeJitter))
            let gw = max(1, Int(Double(glyph.w) * s))
            let gh = max(1, Int(Double(glyph.h) * s))
            var gimg = glyph.bitmap.resized(width: gw, height: gh)
            if rotateJitter != 0 { gimg = gimg.rotated(degrees: rng.uniform(-rotateJitter, rotateJitter)) }
            let bl = Int(Double(glyph.baselineY) * s)
            let base = baseline()
            let py = base - bl
            // Connect letters occasionally, only where a pen would naturally flow.
            if let p = prev,
               HandwritingCharset.connectable.contains(ch),
               HandwritingCharset.connectable.contains(p.2),
               !HandwritingCharset.noRightConnect.contains(p.2),
               !HandwritingCharset.noLeftConnect.contains(ch),
               rng.random() < 0.32,
               let entry = Self.penPoint(gimg, baseline: bl, right: false) {
                let pEntry = (Double(x + entry.0), Double(py + entry.1))
                let gap = hypot(pEntry.0 - p.0, pEntry.1 - p.1)
                if 3 < gap && gap < 14 { drawConnector((p.0, p.1), pEntry) }
            }
            canvas.composite(gimg, x: x, y: py)
            if headerUnderline { headerBaseline = base }
            if let exit = Self.penPoint(gimg, baseline: bl, right: true) {
                prev = (Double(x + exit.0), Double(py + exit.1), ch)
            } else {
                prev = (Double(x + gw), Double(base - 3), ch)
            }
            let kern = HandwritingCharset.connectable.contains(ch) ? 4.0 : 6.0
            let advance = gw + Int(kern * s) + rng.randint(-spacingJitter, spacingJitter)
            x += max(Int(8 * s), advance)
        }
    }
}
