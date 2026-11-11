import CoreGraphics
import Foundation

/// The per-render state shared by every block renderer: the glyphs, the seeded
/// generator and the dropped-character tally. Lives for one `render` call.
final class HandwritingEngine {
    typealias Block = (image: AlphaBitmap, baseline: Int)

    let library: GlyphLibrary
    var rng: SeededRandom
    var dropped: [Character: Int] = [:]

    init(library: GlyphLibrary, seed: UInt64) {
        self.library = library
        rng = SeededRandom(seed: seed)
    }

    // MARK: Glyph picking

    struct Glyph {
        var bitmap: AlphaBitmap
        var w: Int
        var h: Int
        var baselineY: Int
    }

    /// `pick_glyph`: resolves sub/superscripts and fallbacks, avoids repeating
    /// the previous variant of the same character.
    func pickGlyph(_ ch: Character, last: inout [Character: Int], countDrop: Bool = true) -> Glyph? {
        let sub = HandwritingCharset.subscriptMap[ch]
        let sup = sub == nil ? HandwritingCharset.superscriptMap[ch] : nil
        var lookup = sub ?? sup ?? ch
        if library.variants[lookup] == nil {
            lookup = HandwritingCharset.fallbacks[lookup] ?? lookup
            if library.variants[lookup] == nil {
                if countDrop && !HandwritingCharset.whitespace.contains(ch) {
                    dropped[ch, default: 0] += 1
                }
                return nil
            }
        }
        let variants = library.variants[lookup]!
        let idx: Int
        if variants.count == 1 {
            idx = 0
        } else {
            let previous = last[lookup] ?? -1
            let choices = (0..<variants.count).filter { $0 != previous }
            idx = choices[rng.index(below: choices.count)]
        }
        last[lookup] = idx
        let v = variants[idx]
        let g = Glyph(bitmap: v.bitmap, w: v.w, h: v.h, baselineY: v.baselineY)
        if sup != nil {
            // 80 % size, sitting above the baseline near the x-height.
            return shrinkAndBoost(g, 0.8, baseline: Int(Double(v.h) * 0.8) + 20)
        } else if sub != nil {
            // 80 % size, hanging below the baseline.
            return shrinkAndBoost(g, 0.8, baseline: -8)
        }
        return g
    }

    private func shrinkAndBoost(_ g: Glyph, _ factor: Double, baseline: Int) -> Glyph {
        let sw = max(1, Int(Double(g.w) * factor))
        let sh = max(1, Int(Double(g.h) * factor))
        var img = g.bitmap.resized(width: sw, height: sh)
        img.boost()
        return Glyph(bitmap: img, w: sw, h: sh, baselineY: baseline)
    }

    static func ink(_ pts: [(Double, Double)]) -> [CGPoint] { pts.map { CGPoint(x: $0.0, y: $0.1) } }

    // MARK: Text chunks and inline content

    /// `render_text_chunk`: a short string in a tight image, no wrapping.
    func renderTextChunk(_ text: String, scale: Double = 0.85, rotateJitter: Double = 2.0,
                         sizeJitter: Double = 0.04, kerning: Int = 4, spaceWidth: Int = 14) -> Block {
        if text.isEmpty { return (AlphaBitmap(width: 1, height: 1), 0) }
        var last: [Character: Int] = [:]
        var specs: [(Glyph, Double, Int, Int, Int)?] = []
        for ch in text {
            if ch == " " { specs.append(nil); continue }
            guard let g = pickGlyph(ch, last: &last) else { specs.append(nil); continue }
            let s = scale * (1 + rng.uniform(-sizeJitter, sizeJitter))
            specs.append((g, s, max(1, Int(Double(g.w) * s)), max(1, Int(Double(g.h) * s)),
                          Int(Double(g.baselineY) * s)))
        }
        var totalW = 0, maxAbove = 0, maxBelow = 0
        for spec in specs {
            guard let (_, _, gw, gh, bl) = spec else { totalW += spaceWidth; continue }
            totalW += gw + kerning
            maxAbove = max(maxAbove, bl)
            maxBelow = max(maxBelow, gh - bl)
        }
        if totalW <= 0 { return (AlphaBitmap(width: 1, height: 1), 0) }
        var canvas = AlphaBitmap(width: totalW + 4, height: maxAbove + maxBelow + 4)
        let baseline = maxAbove + 2
        var x = 2
        for spec in specs {
            guard let (g, _, gw, gh, bl) = spec else { x += spaceWidth; continue }
            var img = g.bitmap.resized(width: gw, height: gh)
            if rotateJitter != 0 { img = img.rotated(degrees: rng.uniform(-rotateJitter, rotateJitter)) }
            canvas.composite(img, x: x, y: baseline - bl)
            x += gw + kerning
        }
        return (canvas, baseline)
    }

    /// `render_inline`: text plus nested markup, all aligned on one baseline.
    func renderInline(_ content: String, scale: Double = 0.85) -> Block {
        var parts: [Block] = []
        for tok in HandwritingMarkup.tokenize(content) {
            switch tok {
            case .text(let t):
                if !t.isEmpty { parts.append(renderTextChunk(t, scale: scale)) }
            case .matrix(let rows, let dividers):
                parts.append(renderMatrix(rows, scale: scale * 0.9, dividers: dividers))
            case .frac(let n, let d):
                parts.append(renderFraction(n, d, scale: scale * 0.9))
            case .sum(let lo, let up):
                parts.append(renderSum(lo, up, scale: scale * 0.9))
            case .table(let rows):
                parts.append(renderTable(rows, scale: scale * 0.85))
            case .arrow:
                parts.append(renderArrowGlyph(scale: scale) ?? renderArrow(scale: scale))
            case .approx:
                parts.append(renderApprox(scale: scale))
            case .integral:
                parts.append(renderIntegralGlyph(scale: scale) ?? renderIntegral(scale: scale))
            case .integralBounded(let lo, let up):
                parts.append(renderIntegralBounded(lo, up, scale: scale))
            case .strike(let c): parts.append(renderStrike(c, scale: scale))
            case .vec(let c): parts.append(renderVec(c, scale: scale))
            case .hat(let c): parts.append(renderHat(c, scale: scale))
            case .sqrt(let c): parts.append(renderSqrt(c, scale: scale))
            case .down(let c): parts.append(renderDown(c, scale: scale))
            case .up(let c): parts.append(renderUp(c, scale: scale))
            case .box:
                break // Math Writer drops boxes nested inside other blocks.
            }
        }
        if parts.isEmpty { return (AlphaBitmap(width: 1, height: 1), 0) }
        let maxAbove = parts.map(\.baseline).max()!
        let maxBelow = parts.map { $0.image.height - $0.baseline }.max()!
        let totalW = parts.reduce(0) { $0 + $1.image.width } + 4 * (parts.count - 1)
        var canvas = AlphaBitmap(width: totalW + 4, height: maxAbove + maxBelow + 4)
        var x = 2
        for (img, bl) in parts {
            canvas.composite(img, x: x, y: maxAbove + 2 - bl)
            x += img.width + 4
        }
        return (canvas, maxAbove + 2)
    }

    // MARK: Blocks

    /// Matrix with hand-drawn parentheses; `dividers` are column indices that
    /// get an augmented-matrix bar before them.
    func renderMatrix(_ rows: [[String]], scale: Double = 0.85, dividers: [Int] = []) -> Block {
        let cells = rows.map { row in row.map { renderInline($0, scale: scale).image } }
        let nRows = cells.count
        let nCols = cells.map(\.count).max() ?? 0
        var colW = [Int](repeating: 0, count: nCols)
        var rowH = [Int](repeating: 0, count: nRows)
        for (i, row) in cells.enumerated() {
            for (j, img) in row.enumerated() {
                colW[j] = max(colW[j], img.width)
                rowH[i] = max(rowH[i], img.height)
            }
        }
        let colPad = Int(28 * scale), rowPad = Int(14 * scale), parenW = Int(20 * scale)
        let innerW = colW.reduce(0, +) + colPad * (nCols - 1)
        let innerH = rowH.reduce(0, +) + rowPad * (nRows - 1)
        let totalW = innerW + 2 * parenW + 28
        let totalH = innerH + 16
        var img = AlphaBitmap(width: totalW, height: totalH)
        var cy = 6
        for (i, row) in cells.enumerated() {
            var cx = parenW + 12
            for j in 0..<nCols {
                if j < row.count {
                    let cell = row[j]
                    img.composite(cell, x: cx + (colW[j] - cell.width) / 2, y: cy + (rowH[i] - cell.height) / 2)
                }
                cx += colW[j] + colPad
            }
            cy += rowH[i] + rowPad
        }

        let L = 4.0, R = Double(totalW - 4), T = 4.0, B = Double(totalH - 4)
        let midY = (T + B) / 2 + rng.uniform(-1.5, 1.5)
        let ry = (B - T) / 2
        let rxLeft = Double(parenW) * rng.uniform(0.85, 1.05)
        let rxRight = Double(parenW) * rng.uniform(0.85, 1.05)
        let leanL = rng.uniform(-2.0, 1.0)
        let leanR = rng.uniform(-1.0, 2.0)
        let N = 40
        func paren(_ cx: Double, _ rx: Double, _ side: Double, _ lean: Double) {
            var pts: [(Double, Double)] = []
            for t in 0...N {
                let u = Double(t) / Double(N)
                var bow = sin(.pi * u)
                bow *= 0.92 + 0.08 * sin(.pi * u)
                var px = cx + side * rx * bow
                var py = midY - ry * cos(.pi * u)
                px += lean * (py - midY) / ry
                if 0 < t && t < N {
                    px += rng.uniform(-0.4, 0.4)
                    py += rng.uniform(-0.4, 0.4)
                }
                pts.append((px, py))
            }
            img.stroke(Self.ink(pts), width: 3)
        }
        paren(L + Double(parenW), rxLeft, -1, leanL)
        paren(R - Double(parenW), rxRight, 1, leanR)

        for col in dividers where col > 0 && col < nCols {
            var cx = parenW + 12
            for j in 0..<col { cx += colW[j] + colPad }
            let barX = Double(cx - colPad / 2) + rng.uniform(-1, 1)
            var pts: [(Double, Double)] = []
            for k in 0...12 {
                let u = Double(k) / 12
                let y = T + (B - T) * u + rng.uniform(-0.4, 0.4)
                pts.append((barX + rng.uniform(-0.3, 0.3), y))
            }
            img.stroke(Self.ink(pts), width: 2)
        }
        return (img, totalH / 2)
    }

    /// Fraction with a wavy bar; the baseline sits just under the bar.
    func renderFraction(_ num: String, _ den: String, scale: Double = 0.85) -> Block {
        let n = renderInline(num, scale: scale).image
        let d = renderInline(den, scale: scale).image
        let W = max(n.width, d.width) + 16
        let gap = 6
        var img = AlphaBitmap(width: W, height: n.height + d.height + 2 * gap + 2)
        img.composite(n, x: (W - n.width) / 2, y: 1)
        img.composite(d, x: (W - d.width) / 2, y: n.height + 2 * gap)
        let barY = n.height + gap
        var pts: [(Double, Double)] = []
        for i in stride(from: 0, to: W, by: 6) { pts.append((Double(i), Double(barY + rng.randint(-1, 1)))) }
        pts.append((Double(W - 2), Double(barY)))
        img.stroke(Self.ink(pts), width: 3)
        return (img, barY + 2)
    }

    /// Σ with limits, one continuous stroke.
    func renderSum(_ lower: String, _ upper: String, scale: Double = 0.85) -> Block {
        let lo = renderInline(lower, scale: scale * 0.6).image
        let up = renderInline(upper, scale: scale * 0.6).image
        let sigmaH = Int(54 * scale), sigmaW = Int(44 * scale)
        let pad = 2
        let W = max(sigmaW + 8, lo.width, up.width) + 8
        var img = AlphaBitmap(width: W, height: up.height + pad + sigmaH + pad + lo.height)
        img.composite(up, x: (W - up.width) / 2, y: 0)
        let sxLeft = Double((W - sigmaW) / 2)
        let syTop = up.height + pad
        let syBot = syTop + sigmaH
        let midY = (syTop + syBot) / 2
        let apexX = sxLeft + Double(Int(Double(sigmaW) * 0.82))
        let slant = rng.uniform(-1.5, 1.5)
        let full: [(Double, Double)] = [
            (sxLeft + Double(sigmaW), Double(syTop)),
            (sxLeft, Double(syTop) + slant * 0.3),
            (apexX, Double(midY)),
            (sxLeft, Double(syBot) - slant * 0.3),
            (sxLeft + Double(sigmaW), Double(syBot)),
        ]
        img.stroke(Self.ink(full), width: 3)
        img.composite(lo, x: (W - lo.width) / 2, y: syBot + pad)
        return (img, midY + sigmaH / 5)
    }

    /// Points of a slightly wobbly line with optional over/undershoot.
    private func handSegment(_ p1: (Double, Double), _ p2: (Double, Double), segments: Int = 10,
                             jitter: Double = 0.7, overshoot: (Double, Double) = (0, 2.5),
                             trimEnd: Bool = false, trimStart: Bool = false) -> [(Double, Double)] {
        let (x1, y1) = p1, (x2, y2) = p2
        let length = max(1.0, hypot(x2 - x1, y2 - y1))
        let px = -(y2 - y1) / length, py = (x2 - x1) / length
        let ux = (x2 - x1) / length, uy = (y2 - y1) / length
        let oEnd = trimEnd ? 0 : rng.uniform(overshoot.0, overshoot.1)
        let oStart = trimStart ? 0 : rng.uniform(overshoot.0, overshoot.1) * 0.7
        let sx = x1 - ux * oStart, sy = y1 - uy * oStart
        let ex = x2 + ux * oEnd, ey = y2 + uy * oEnd
        var pts: [(Double, Double)] = []
        for k in 0...segments {
            let u = Double(k) / Double(segments)
            var x = sx + (ex - sx) * u, y = sy + (ey - sy) * u
            if 0 < k && k < segments {
                let wob = rng.uniform(-jitter, jitter)
                x += px * wob
                y += py * wob
            }
            pts.append((x, y))
        }
        return pts
    }

    private func handLine(_ img: inout AlphaBitmap, _ p1: (Double, Double), _ p2: (Double, Double),
                          width: Double = 3, jitter: Double = 0.7, overshoot: (Double, Double) = (0, 2.5)) {
        img.stroke(Self.ink(handSegment(p1, p2, jitter: jitter, overshoot: overshoot)), width: width)
    }

    /// Hand-drawn table, first row as header.
    func renderTable(_ rows: [[String]], scale: Double = 0.8, headerRow: Bool = true) -> Block {
        if rows.isEmpty { return (AlphaBitmap(width: 1, height: 1), 0) }
        let nCols = rows.map(\.count).max() ?? 0
        let cells = rows.map { row in
            (0..<nCols).map { j in renderInline(j < row.count ? row[j] : "", scale: scale).image }
        }
        let colPadH = Int(14 * scale), rowPadV = Int(9 * scale)
        var colW = [Int](repeating: 0, count: nCols)
        var uniformH = 0
        for row in cells {
            for (j, c) in row.enumerated() {
                colW[j] = max(colW[j], c.width)
                uniformH = max(uniformH, c.height)
            }
        }
        var cellX = [3]
        for j in 0..<nCols { cellX.append(cellX.last! + colW[j] + 2 * colPadH) }
        var cellY = [3]
        for _ in cells { cellY.append(cellY.last! + uniformH + 2 * rowPadV) }
        let W = cellX.last! + 6, H = cellY.last! + 6
        var img = AlphaBitmap(width: W, height: H)
        for (i, row) in cells.enumerated() {
            for (j, c) in row.enumerated() {
                img.composite(c, x: cellX[j] + colPadH, y: cellY[i] + rowPadV + (uniformH - c.height) / 2)
            }
        }
        let top = Double(cellY.first!), bot = Double(cellY.last!)
        let left = Double(cellX.first!), right = Double(cellX.last!)
        var outer: [(Double, Double)] = [(left + rng.uniform(-1, 2), top + rng.uniform(-1, 2))]
        let corners = [((left, top), (right, top)), ((right, top), (right, bot)),
                       ((right, bot), (left, bot)), ((left, bot), (left, top))]
        for (a, b) in corners {
            outer += handSegment(a, b, segments: 14, jitter: 0.55, overshoot: (0, 0), trimEnd: true, trimStart: true)
        }
        outer.append((left + rng.uniform(2, 6), top + rng.uniform(-0.5, 1.5)))
        img.stroke(Self.ink(outer), width: 3)
        for j in 1..<max(1, nCols) {
            let x = Double(cellX[j])
            handLine(&img, (x, top), (x, bot), jitter: 0.5, overshoot: (0, 1.4))
        }
        if headerRow && cells.count > 1 {
            handLine(&img, (left, Double(cellY[1])), (right, Double(cellY[1])), jitter: 0.5)
            for i in 2..<max(2, cells.count) {
                handLine(&img, (left, Double(cellY[i])), (right, Double(cellY[i])), jitter: 0.6, overshoot: (0, 1.6))
            }
        }
        return (img, H / 2)
    }

    /// `→` from a real handwritten glyph, if the library has one.
    func renderArrowGlyph(scale: Double = 1.0) -> Block? {
        guard library.variants["→"] != nil else { return nil }
        var last: [Character: Int] = [:]
        guard let g = pickGlyph("→", last: &last) else { return nil }
        let s = scale * (1 + rng.uniform(-0.04, 0.04))
        let img = g.bitmap.resized(width: max(1, Int(Double(g.w) * s)), height: max(1, Int(Double(g.h) * s)))
            .rotated(degrees: rng.uniform(-2.5, 2.5))
        return (img, max(1, Int(Double(g.baselineY) * s)))
    }

    /// ∫ with the lower limit at its bottom right and the upper at its top right.
    func renderIntegralBounded(_ lower: String, _ upper: String, scale: Double = 1.0) -> Block {
        let (intImg, intBl) = renderIntegralGlyph(scale: scale) ?? renderIntegral(scale: scale)
        var lo = renderInline(lower, scale: scale * 0.55).image
        var up = renderInline(upper, scale: scale * 0.55).image
        lo.boost()
        up.boost()
        let IW = intImg.width, IH = intImg.height
        let gapX = Int(2 * scale)
        var canvas = AlphaBitmap(width: IW + gapX + max(lo.width, up.width) + 4, height: IH)
        canvas.composite(intImg, x: 0, y: 0)
        canvas.composite(up, x: IW + gapX, y: Int(Double(IH) * 0.08))
        canvas.composite(lo, x: IW + gapX, y: IH - lo.height - Int(Double(IH) * 0.06))
        return (canvas, intBl)
    }

    /// `∫` from a real handwritten glyph, shrunk to ~1.4× line height.
    func renderIntegralGlyph(scale: Double = 1.0) -> Block? {
        guard library.variants["∫"] != nil else { return nil }
        var last: [Character: Int] = [:]
        guard let g = pickGlyph("∫", last: &last) else { return nil }
        let s = scale * 0.42 * (1 + rng.uniform(-0.05, 0.05))
        let img = g.bitmap.resized(width: max(1, Int(Double(g.w) * s)), height: max(1, Int(Double(g.h) * s)))
            .rotated(degrees: rng.uniform(-1.5, 1.5))
        return (img, Int(Double(g.h) * 0.5 * s) + Int(Double(g.h) * 0.15 * s))
    }

    /// Procedural `->`: wavy shaft plus a V head.
    func renderArrow(scale: Double = 0.9) -> Block {
        let W = Int(54 * scale), H = Int(28 * scale)
        var img = AlphaBitmap(width: W, height: H)
        let midY = Double(H / 2)
        let tilt = rng.uniform(-1, 1)
        var pts: [(Double, Double)] = []
        for k in 0...10 {
            let u = Double(k) / 10
            pts.append((2 + u * Double(W - 6), midY + tilt * (u - 0.5) + rng.uniform(-0.4, 0.4)))
        }
        img.stroke(Self.ink(pts), width: 3)
        let tip = pts.last!
        let headLen = Double(max(6, Int(9 * scale)))
        let ang = (28 + rng.uniform(-4, 4)) * .pi / 180
        let upper = (tip.0 - headLen * cos(ang), tip.1 - headLen * sin(ang))
        let lower = (tip.0 - headLen * cos(ang), tip.1 + headLen * sin(ang) + rng.uniform(-0.5, 0.5))
        let head = [(upper.0 + rng.uniform(-0.4, 0.4), upper.1 + rng.uniform(-0.4, 0.4)), tip,
                    (lower.0 + rng.uniform(-0.4, 0.4), lower.1 + rng.uniform(-0.4, 0.4))]
        img.stroke(Self.ink(head), width: 3)
        return (img, Int(Double(H) * 0.85))
    }

    /// Procedural `≈`: two stacked wavy lines.
    func renderApprox(scale: Double = 0.9) -> Block {
        let W = Int(36 * scale), H = Int(26 * scale)
        var img = AlphaBitmap(width: W, height: H)
        for yc in [Double(H) * 0.40, Double(H) * 0.65] {
            var pts: [(Double, Double)] = []
            for k in 0...14 {
                let u = Double(k) / 14
                pts.append((2 + u * Double(W - 4), yc + sin(u * .pi * 2) * 1.4 + rng.uniform(-0.4, 0.4)))
            }
            img.stroke(Self.ink(pts), width: 2)
        }
        return (img, Int(Double(H) * 0.78))
    }

    /// Procedural `∫`: a tall S with hooks, drawn as one path.
    func renderIntegral(scale: Double = 0.9) -> Block {
        let W = Int(26 * scale), H = Int(96 * scale)
        var img = AlphaBitmap(width: W, height: H)
        let n = 40
        let cx = Double(W) / 2
        var pts: [(Double, Double)] = []
        for k in 0...n {
            let u = Double(k) / Double(n)
            var y = 4 + u * Double(H - 8)
            var x = cx + sin(.pi * (u - 0.5)) * (Double(W) * 0.28)
            if 0 < k && k < n {
                x += rng.uniform(-0.35, 0.35)
                y += rng.uniform(-0.35, 0.35)
            }
            pts.append((x, y))
        }
        let top = pts.first!, bot = pts.last!
        let full = [(top.0 - Double(W) * 0.35, top.1 + 3)] + pts + [(bot.0 + Double(W) * 0.35, bot.1 - 3)]
        img.stroke(Self.ink(full), width: 3)
        return (img, Int(Double(H) * 0.78))
    }

    /// Content with a small arrow above it.
    func renderVec(_ content: String, scale: Double = 1.0) -> Block {
        let (inner, innerBl) = renderInline(content, scale: scale)
        let W = inner.width
        let barH = Int(14 * scale)
        var img = AlphaBitmap(width: W + 6, height: inner.height + barH)
        img.composite(inner, x: 3, y: barH)
        let barY = Double(Int(Double(barH) * 0.55) + rng.randint(-1, 1))
        var pts: [(Double, Double)] = []
        let x0 = 4.0, x1 = Double(W + 2)
        for k in 0...10 {
            let u = Double(k) / 10
            pts.append((x0 + (x1 - x0) * u, barY + rng.uniform(-0.5, 0.5)))
        }
        img.stroke(Self.ink(pts), width: 2)
        let tip = pts.last!
        let headLen = Double(Int(5 * scale))
        img.stroke(Self.ink([(tip.0 - headLen, tip.1 - headLen * 0.55), tip,
                             (tip.0 - headLen, tip.1 + headLen * 0.55)]), width: 2)
        return (img, innerBl + barH)
    }

    /// Content with a caret above it.
    func renderHat(_ content: String, scale: Double = 1.0) -> Block {
        let (inner, innerBl) = renderInline(content, scale: scale)
        let W = inner.width
        let barH = Int(12 * scale)
        var img = AlphaBitmap(width: W + 4, height: inner.height + barH)
        img.composite(inner, x: 2, y: barH)
        let cx = Double((W + 4) / 2)
        let cy = Double(Int(Double(barH) * 0.55))
        let halfW = Double(max(4, Int(Double(W) * 0.35)))
        let halfH = Double(max(3, Int(Double(barH) * 0.35)))
        let pts = [(cx - halfW + rng.uniform(-0.5, 0.5), cy + halfH + rng.uniform(-0.3, 0.3)),
                   (cx + rng.uniform(-0.5, 0.5), cy + rng.uniform(-0.4, 0.4)),
                   (cx + halfW + rng.uniform(-0.5, 0.5), cy + halfH + rng.uniform(-0.3, 0.3))]
        img.stroke(Self.ink(pts), width: 2)
        return (img, innerBl + barH)
    }

    /// Content under a radical with an overbar.
    func renderSqrt(_ content: String, scale: Double = 1.0) -> Block {
        let (inner, innerBl) = renderInline(content, scale: scale)
        let W = inner.width, H = inner.height
        let topPad = Int(6 * scale) + 3
        let radicalW = Int(14 * scale)
        var img = AlphaBitmap(width: W + radicalW + 4, height: H + topPad + 2)
        img.composite(inner, x: radicalW + 2, y: topPad)
        let radical: [(Double, Double)] = [
            (3, Double(topPad + H - Int(Double(H) * 0.35))),
            (Double(radicalW) * 0.45 + 1, Double(topPad + H - 4)),
            (Double(radicalW), 3),
        ]
        img.stroke(Self.ink(radical), width: 3)
        img.stroke(Self.ink([(Double(radicalW), 3), (Double(radicalW + 2 + W), 3)]), width: 2)
        return (img, innerBl + topPad)
    }

    /// Subscript group: small content hanging below the line.
    func renderDown(_ content: String, scale: Double = 1.0) -> Block {
        var inner = renderInline(content, scale: scale * 0.62).image
        inner.boost()
        return (inner, -4)
    }

    /// Superscript group: small content raised above the line.
    func renderUp(_ content: String, scale: Double = 1.0) -> Block {
        var inner = renderInline(content, scale: scale * 0.62).image
        inner.boost()
        return (inner, inner.height + 18)
    }

    /// Content with a hand-drawn line through it.
    func renderStrike(_ content: String, scale: Double = 1.0) -> Block {
        var (img, innerBl) = renderInline(content, scale: scale)
        let W = img.width, H = img.height
        let yStrike = Double(max(2, innerBl - Int(Double(H) * 0.18)) + rng.randint(-1, 1))
        var pts: [(Double, Double)] = []
        for k in 0...12 {
            let u = Double(k) / 12
            pts.append((1 + u * Double(W - 2), yStrike + sin(u * .pi * 2) * 0.6 + rng.uniform(-0.5, 0.5)))
        }
        img.stroke(Self.ink(pts), width: 3)
        return (img, innerBl)
    }

    /// Boxed content (supports nested markup).
    func renderBox(_ content: String, scale: Double = 1.0) -> Block {
        let (inner, innerBl) = renderInline(content, scale: scale)
        let pad = 10
        let W = inner.width + 2 * pad, H = inner.height + 2 * pad
        var img = AlphaBitmap(width: W, height: H)
        img.composite(inner, x: pad, y: pad)
        let j = 1.2
        let tl = (2 + rng.uniform(-j, j), 2 + rng.uniform(-j, j))
        let tr = (Double(W - 3) + rng.uniform(-j, j), 2 + rng.uniform(-j, j))
        let br = (Double(W - 3) + rng.uniform(-j, j), Double(H - 3) + rng.uniform(-j, j))
        let bl = (2 + rng.uniform(-j, j), Double(H - 3) + rng.uniform(-j, j))
        let close = (tl.0 + rng.uniform(1, 4), tl.1 + rng.uniform(-0.5, 1.5))
        img.stroke(Self.ink([tl, tr, br, bl, tl, close]), width: 3)
        return (img, innerBl + pad)
    }
}
