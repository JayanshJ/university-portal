import CoreGraphics
import Foundation

/// An 8-bit coverage map. Every mark the renderer makes is in the same ink
/// colour, so ink is tracked as alpha only and coloured when a page is finished.
/// Compositing two maps is Pillow's `alpha_composite` for same-coloured layers.
struct AlphaBitmap: Sendable {
    private(set) var width: Int
    private(set) var height: Int
    var data: [UInt8]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        data = [UInt8](repeating: 0, count: self.width * self.height)
    }

    init(width: Int, height: Int, data: [UInt8]) {
        self.width = width
        self.height = height
        self.data = data
    }

    // MARK: Compositing

    /// Source-over composite of `src` with its top-left at (x, y); clipped to bounds.
    mutating func composite(_ src: AlphaBitmap, x: Int, y: Int) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + src.width), y1 = min(height, y + src.height)
        guard x0 < x1, y0 < y1 else { return }
        let w = width, sw = src.width
        src.data.withUnsafeBufferPointer { s in
            data.withUnsafeMutableBufferPointer { d in
                for yy in y0..<y1 {
                    let drow = yy * w
                    let srow = (yy - y) * sw - x
                    for xx in x0..<x1 {
                        let a = Int(s[srow + xx])
                        if a == 0 { continue }
                        if a == 255 { d[drow + xx] = 255; continue }
                        let b = Int(d[drow + xx])
                        d[drow + xx] = UInt8(a + (b * (255 - a) + 127) / 255)
                    }
                }
            }
        }
    }

    /// Pixels above `threshold` become fully opaque, the rest ×4 (Math Writer's
    /// "boost so small text doesn't fade in print").
    mutating func boost(threshold: UInt8 = 40) {
        for i in data.indices {
            let a = data[i]
            data[i] = a > threshold ? 255 : UInt8(min(255, Int(a) * 4))
        }
    }

    // MARK: Resampling

    /// Pillow-style Lanczos (a = 3) resize with antialiasing support scaling.
    func resized(width ow: Int, height oh: Int) -> AlphaBitmap {
        let ow = max(1, ow), oh = max(1, oh)
        if ow == width && oh == height { return self }
        let hk = Self.lanczosKernel(inSize: width, outSize: ow)
        let vk = Self.lanczosKernel(inSize: height, outSize: oh)
        var tmp = [Float](repeating: 0, count: ow * height)
        data.withUnsafeBufferPointer { s in
            for y in 0..<height {
                let row = y * width
                for x in 0..<ow {
                    let (start, weights) = hk[x]
                    var acc: Float = 0
                    for k in 0..<weights.count { acc += Float(s[row + start + k]) * weights[k] }
                    tmp[y * ow + x] = acc
                }
            }
        }
        var out = AlphaBitmap(width: ow, height: oh)
        for y in 0..<oh {
            let (start, weights) = vk[y]
            for x in 0..<ow {
                var acc: Float = 0
                for k in 0..<weights.count { acc += tmp[(start + k) * ow + x] * weights[k] }
                out.data[y * ow + x] = UInt8(max(0, min(255, acc.rounded())))
            }
        }
        return out
    }

    private static func lanczosKernel(inSize: Int, outSize: Int) -> [(Int, [Float])] {
        func sinc(_ x: Double) -> Double { x == 0 ? 1 : sin(.pi * x) / (.pi * x) }
        func lanczos(_ x: Double) -> Double { (-3 < x && x < 3) ? sinc(x) * sinc(x / 3) : 0 }
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = 3 * filterScale
        let ss = 1 / filterScale
        var result: [(Int, [Float])] = []
        result.reserveCapacity(outSize)
        for i in 0..<outSize {
            let center = (Double(i) + 0.5) * scale
            let xmin = max(Int(center - support + 0.5), 0)
            let xmax = min(Int(center + support + 0.5), inSize)
            var w: [Double] = []
            var total = 0.0
            if xmax > xmin {
                for x in xmin..<xmax {
                    let v = lanczos((Double(x) - center + 0.5) * ss)
                    w.append(v)
                    total += v
                }
            }
            if total != 0 { w = w.map { $0 / total } }
            result.append((xmin, w.map(Float.init)))
        }
        return result
    }

    /// Pillow's `rotate(angle, BICUBIC, expand=True)`: counter-clockwise degrees,
    /// canvas grown to hold the rotated image, transparent fill.
    func rotated(degrees angle: Double) -> AlphaBitmap {
        let w = Double(width), h = Double(height)
        let r = -angle * .pi / 180
        let a = cos(r), b = sin(r), d = -sin(r), e = cos(r)
        var c = a * (-w / 2) + b * (-h / 2) + w / 2
        var f = d * (-w / 2) + e * (-h / 2) + h / 2
        func tf(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + b * y + c, d * x + e * y + f) }
        let corners = [tf(0, 0), tf(w, 0), tf(w, h), tf(0, h)]
        let xs = corners.map(\.0), ys = corners.map(\.1)
        let nw = Int(ceil(xs.max()!)) - Int(floor(xs.min()!))
        let nh = Int(ceil(ys.max()!)) - Int(floor(ys.min()!))
        (c, f) = tf(-(Double(nw) - w) / 2, -(Double(nh) - h) / 2)

        var out = AlphaBitmap(width: nw, height: nh)
        let iw = width, ih = height
        data.withUnsafeBufferPointer { s in
            func px(_ x: Int, _ y: Int) -> Double {
                Double(s[min(max(y, 0), ih - 1) * iw + min(max(x, 0), iw - 1)])
            }
            func cubic(_ v1: Double, _ v2: Double, _ v3: Double, _ v4: Double, _ t: Double) -> Double {
                let p1 = v2, p2 = -v1 + v3
                let p3 = 2 * (v1 - v2) + v3 - v4
                let p4 = -v1 + v2 - v3 + v4
                return p1 + t * (p2 + t * (p3 + t * p4))
            }
            for oy in 0..<out.height {
                for ox in 0..<out.width {
                    var xin = a * (Double(ox) + 0.5) + b * (Double(oy) + 0.5) + c
                    var yin = d * (Double(ox) + 0.5) + e * (Double(oy) + 0.5) + f
                    if xin < 0 || xin >= w || yin < 0 || yin >= h { continue }
                    xin -= 0.5; yin -= 0.5
                    let x0 = Int(floor(xin)), y0 = Int(floor(yin))
                    let dx = xin - Double(x0), dy = yin - Double(y0)
                    var rows = [Double](repeating: 0, count: 4)
                    for k in 0..<4 {
                        let yy = y0 - 1 + k
                        rows[k] = cubic(px(x0 - 1, yy), px(x0, yy), px(x0 + 1, yy), px(x0 + 2, yy), dx)
                    }
                    let v = cubic(rows[0], rows[1], rows[2], rows[3], dy)
                    out.data[oy * out.width + ox] = UInt8(max(0, min(255, v.rounded())))
                }
            }
        }
        return out
    }

    /// 3×3 Gaussian blur (σ = 0.5, reflect-101 border), result truncated like
    /// OpenCV's float → uint8 `astype`.
    func gaussianBlurred3x3() -> AlphaBitmap {
        let g0 = exp(-1.0 / (2 * 0.25))
        let sum = 1 + 2 * g0
        let k: [Float] = [Float(g0 / sum), Float(1 / sum), Float(g0 / sum)]
        func reflect(_ i: Int, _ n: Int) -> Int {
            if n == 1 { return 0 }
            if i < 0 { return -i }
            if i >= n { return 2 * n - 2 - i }
            return i
        }
        var tmp = [Float](repeating: 0, count: data.count)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for j in -1...1 { acc += Float(data[y * width + reflect(x + j, width)]) * k[j + 1] }
                tmp[y * width + x] = acc
            }
        }
        var out = AlphaBitmap(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                var acc: Float = 0
                for j in -1...1 { acc += tmp[reflect(y + j, height) * width + x] * k[j + 1] }
                out.data[y * width + x] = UInt8(max(0, min(255, acc)))
            }
        }
        return out
    }

    // MARK: Strokes

    /// Anti-aliased polyline (Math Writer's `aa_line`): butt ends, round joins.
    /// Drawn straight into this bitmap; anything outside is clipped.
    mutating func stroke(_ points: [CGPoint], width lineWidth: Double) {
        guard points.count >= 2 else { return }
        let pad = max(lineWidth * 2, 6)
        let minX = points.map(\.x).min()! - pad, maxX = points.map(\.x).max()! + pad
        let minY = points.map(\.y).min()! - pad, maxY = points.map(\.y).max()! + pad
        let x0 = max(0, Int(floor(minX))), x1 = min(width, Int(ceil(maxX)))
        let y0 = max(0, Int(floor(minY))), y1 = min(height, Int(ceil(maxY)))
        guard x0 < x1, y0 < y1 else { return }
        let fullWidth = width
        let subW = x1 - x0, subH = y1 - y0
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base + (y0 * fullWidth + x0),
                                      width: subW, height: subH,
                                      bitsPerComponent: 8, bytesPerRow: fullWidth,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            // Top-left origin, in this bitmap's coordinates.
            ctx.translateBy(x: 0, y: CGFloat(subH))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
            ctx.setShouldAntialias(true)
            ctx.setAllowsAntialiasing(true)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(CGFloat(max(1, lineWidth)))
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            ctx.addLines(between: points)
            ctx.strokePath()
        }
    }
}

/// Deterministic generator (SplitMix64) with the handful of Python `random`
/// helpers the renderer uses.
struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `random.random()`: [0, 1).
    mutating func random() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    /// `random.uniform(a, b)`.
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * random() }
    /// `random.randint(a, b)`, both ends inclusive.
    mutating func randint(_ a: Int, _ b: Int) -> Int { Int.random(in: a...b, using: &self) }
    /// Index for `random.choice` over `count` items.
    mutating func index(below count: Int) -> Int { Int.random(in: 0..<count, using: &self) }
}
