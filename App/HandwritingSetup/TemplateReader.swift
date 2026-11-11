import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Reads a filled handwriting template (a photo, a scan or a PDF exported from an iPad) into
/// glyphs: finds the four corner squares, straightens the page, works out which page it is from
/// the squares under the title, and cuts each box's ink out at Math Writer's glyph scale.
enum TemplateReader {
    /// Pixels per point of the straightened page.
    static let scale: CGFloat = 3
    /// Math Writer's glyphs have an x-height of about 16 px.
    static let glyphXHeight: CGFloat = 16

    struct Glyph {
        var character: Character
        var png: Data
        var width: Int
        var height: Int
        /// Pixels from the image top to the baseline.
        var baseline: Int
    }

    struct Page {
        var number: Int  // 0-based
        var glyphs: [Glyph]
        /// Characters whose boxes were all empty.
        var empty: [Character]
    }

    enum Failure: LocalizedError {
        case unreadable
        case noMarkers
        case unknownPage

        var errorDescription: String? {
            switch self {
            case .unreadable: "The file isn't an image or PDF that can be read."
            case .noMarkers: "The four black corner squares weren't all found. Take the photo from straight above, with the whole page and all four squares in view, in good light."
            case .unknownPage: "Couldn't tell which template page this is: the small squares under the title weren't readable."
            }
        }
    }

    // MARK: - Input

    /// The pages of an image or PDF file.
    static func images(from url: URL) throws -> [CGImage] {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
            return (0..<document.pageCount).compactMap { document.page(at: $0).flatMap(render) }
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        else { throw Failure.unreadable }
        // Apply the photo's EXIF orientation.
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1 else { return [image] }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        return [CIContext().createCGImage(oriented, from: oriented.extent)].compactMap { $0 }
    }

    /// A PDF page at 3 px per point, on white.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Reading

    static func read(_ image: CGImage) throws -> Page {
        let corners = try findMarkers(in: image)
        let page = try straighten(image, corners: corners)
        let number = try pageNumber(page)
        var glyphs: [Glyph] = []
        var found: Set<Character> = []
        let cells = HandwritingTemplate.cells.filter { $0.page == number }
        for cell in cells {
            if let glyph = extract(cell, from: page) {
                glyphs.append(glyph)
                found.insert(cell.character)
            }
        }
        var empty: [Character] = []
        for cell in cells where !found.contains(cell.character) && !empty.contains(cell.character) { empty.append(cell.character) }
        return Page(number: number, glyphs: glyphs, empty: empty)
    }

    /// A greyscale bitmap, row-major from the top, 0 = black.
    struct Grey {
        var width: Int
        var height: Int
        var pixels: [UInt8]

        init(_ image: CGImage, maxSide: Int? = nil) {
            let factor = maxSide.map { min(1, CGFloat($0) / CGFloat(max(image.width, image.height))) } ?? 1
            width = max(1, Int(CGFloat(image.width) * factor))
            height = max(1, Int(CGFloat(image.height) * factor))
            pixels = [UInt8](repeating: 255, count: width * height)
            let (w, h) = (width, height)
            pixels.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }

        subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
    }

    struct Component {
        var area: Int
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var sumX: Int, sumY: Int
        var centre: CGPoint { CGPoint(x: CGFloat(sumX) / CGFloat(area), y: CGFloat(sumY) / CGFloat(area)) }
        var boxWidth: Int { maxX - minX + 1 }
        var boxHeight: Int { maxY - minY + 1 }
        var fill: CGFloat { CGFloat(area) / CGFloat(boxWidth * boxHeight) }
    }

    /// 4-connected components of `mask`, with each pixel's component in `labels` (0 = none).
    static func components(_ mask: [Bool], width: Int, height: Int, labels: inout [Int32]) -> [Component] {
        labels = [Int32](repeating: 0, count: mask.count)
        var result: [Component] = []
        var stack: [Int] = []
        for start in 0..<mask.count where mask[start] && labels[start] == 0 {
            let label = Int32(result.count + 1)
            var c = Component(area: 0, minX: .max, minY: .max, maxX: 0, maxY: 0, sumX: 0, sumY: 0)
            labels[start] = label
            stack.append(start)
            while let i = stack.popLast() {
                let x = i % width, y = i / width
                c.area += 1; c.sumX += x; c.sumY += y
                c.minX = min(c.minX, x); c.maxX = max(c.maxX, x); c.minY = min(c.minY, y); c.maxY = max(c.maxY, y)
                for n in [x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, y > 0 ? i - width : -1, y < height - 1 ? i + width : -1]
                where n >= 0 && mask[n] && labels[n] == 0 {
                    labels[n] = label
                    stack.append(n)
                }
            }
            result.append(c)
        }
        return result
    }

    /// The corner squares' centres in image coordinates (top-left origin), ordered TL, TR, BR, BL
    /// as printed (so a rotated photo comes out upright).
    static func findMarkers(in image: CGImage) throws -> [CGPoint] {
        let grey = Grey(image, maxSide: 1400)
        let (w, h) = (grey.width, grey.height)
        // Dark against the local background (box mean over ~1/30 of the image), so shadows don't matter.
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += Int(grey[x, y])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        let r = max(8, max(w, h) / 30)
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = Double(sum) / Double((y1 - y0) * (x1 - x0))
                let v = Double(grey[x, y])
                mask[y * w + x] = v < mean * 0.6 && v < 110
            }
        }
        var labels: [Int32] = []
        let minArea = max(20, (max(w, h) / 140) * (max(w, h) / 140))
        let squares = components(mask, width: w, height: h, labels: &labels).filter {
            $0.area >= minArea && $0.fill > 0.72 && (0.6...1.65).contains(CGFloat($0.boxWidth) / CGFloat($0.boxHeight))
        }
        .sorted { $0.area > $1.area }
        .prefix(8)
        guard squares.count >= 4 else { throw Failure.noMarkers }

        // The square furthest towards each image corner.
        let directions: [CGPoint] = [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1), CGPoint(x: 1, y: 1), CGPoint(x: -1, y: 1)]
        var chosen: [Component] = []
        for d in directions {
            guard let best = squares.filter({ c in !chosen.contains { $0.minX == c.minX && $0.minY == c.minY } })
                .max(by: { $0.centre.x * d.x + $0.centre.y * d.y < $1.centre.x * d.x + $1.centre.y * d.y }) else { throw Failure.noMarkers }
            chosen.append(best)
        }
        // Similar sizes (the first is printed 1.5× larger, so ≤ 2.25× the area of the others).
        let areas = chosen.map(\.area).sorted()
        guard CGFloat(areas[3]) / CGFloat(areas[0]) < 4 else { throw Failure.noMarkers }

        // `chosen` is already clockwise from the image's top-left; start at the largest (printed TL).
        let first = chosen.indices.max { chosen[$0].area < chosen[$1].area }!
        let ordered = (0..<4).map { chosen[(first + $0) % 4] }
        let factor = CGFloat(image.width) / CGFloat(w)
        return ordered.map { CGPoint(x: ($0.centre.x + 0.5) * factor, y: ($0.centre.y + 0.5) * factor) }
    }

    /// The page between the corner squares' centres, straightened to `scale` px per point and
    /// padded back out to the whole A4 page, as greyscale.
    static func straighten(_ image: CGImage, corners: [CGPoint]) throws -> Grey {
        let ci = CIImage(cgImage: image)
        let height = CGFloat(image.height)
        func flip(_ p: CGPoint) -> CIVector { CIVector(x: p.x, y: height - p.y) }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { throw Failure.unreadable }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(flip(corners[0]), forKey: "inputTopLeft")
        filter.setValue(flip(corners[1]), forKey: "inputTopRight")
        filter.setValue(flip(corners[2]), forKey: "inputBottomRight")
        filter.setValue(flip(corners[3]), forKey: "inputBottomLeft")
        guard let corrected = filter.outputImage else { throw Failure.unreadable }

        let m = HandwritingTemplate.markerCentres
        let span = CGSize(width: (m[1].x - m[0].x) * scale, height: (m[3].y - m[0].y) * scale)
        let page = CGSize(width: HandwritingTemplate.pageSize.width * scale, height: HandwritingTemplate.pageSize.height * scale)
        // Scale the corrected quad to the span between marker centres, then place it on the page.
        let fitted = corrected
            .transformed(by: CGAffineTransform(translationX: -corrected.extent.minX, y: -corrected.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: span.width / corrected.extent.width, y: span.height / corrected.extent.height))
            .transformed(by: CGAffineTransform(translationX: m[0].x * scale, y: page.height - m[3].y * scale))
        let white = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: page))
        let composed = fitted.composited(over: white).cropped(to: CGRect(origin: .zero, size: page))
        guard let rendered = CIContext(options: [.workingColorSpace: NSNull()]).createCGImage(composed, from: composed.extent) else { throw Failure.unreadable }
        return Grey(rendered)
    }

    /// 0 or 1, from how many of the squares under the title are filled.
    static func pageNumber(_ page: Grey) throws -> Int {
        let filled = HandwritingTemplate.pageMarkCentres().map { centre -> Bool in
            let half = Int(HandwritingTemplate.pageMarkSize * scale * 0.3)
            let cx = Int(centre.x * scale), cy = Int(centre.y * scale)
            var dark = 0, total = 0
            for y in (cy - half)...(cy + half) where y >= 0 && y < page.height {
                for x in (cx - half)...(cx + half) where x >= 0 && x < page.width {
                    total += 1
                    if page[x, y] < 110 { dark += 1 }
                }
            }
            return total > 0 && Double(dark) / Double(total) > 0.5
        }
        switch (filled[0], filled[1]) {
        case (true, false): return 0
        case (true, true): return 1
        default: throw Failure.unknownPage
        }
    }

    /// One box's ink as a glyph, or nil when the box is empty.
    static func extract(_ cell: HandwritingTemplate.Cell, from page: Grey) -> Glyph? {
        let rect = cell.rect
        let inset: CGFloat = 2.5
        let x0 = Int((rect.minX + inset) * scale), x1 = Int((rect.maxX - inset) * scale)
        let y0 = Int((rect.minY + inset) * scale), y1 = Int((rect.maxY - inset) * scale)
        let labelX = Int((rect.maxX - HandwritingTemplate.labelBox.width) * scale)
        let labelY = Int((rect.minY + HandwritingTemplate.labelBox.height) * scale)
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return nil }

        var values = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w where !(x0 + x >= labelX && y0 + y < labelY) {
                values[y * w + x] = page[x0 + x, y0 + y]
            }
        }
        // Paper brightness: a high percentile of the box.
        let paper = Double(values.sorted()[Int(Double(values.count) * 0.85)])
        guard paper > 60 else { return nil }
        let mask = values.map { Double($0) < paper * 0.62 }
        var labels: [Int32] = []
        let all = components(mask, width: w, height: h, labels: &labels)
        // Keep strokes, not specks.
        let minArea = Int(scale * scale * 1.2)
        let kept = Set(all.indices.filter { all[$0].area >= minArea }.map { Int32($0 + 1) })
        guard !kept.isEmpty else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1, ink = 0
        for i in 0..<labels.count where kept.contains(labels[i]) {
            let x = i % w, y = i / w
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            ink += 1
        }
        // A stray mark isn't a character, but a full stop or a dash is small too.
        let small: Set<Character> = [".", ",", "'", "-", ":", ";", "\"", "^"]
        guard ink >= Int(scale * scale * (small.contains(cell.character) ? 1.5 : 6)) else { return nil }
        minX = max(0, minX - 2); minY = max(0, minY - 2); maxX = min(w - 1, maxX + 2); maxY = min(h - 1, maxY + 2)

        // Ink as alpha on black, kept only near the kept strokes.
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        var rgba = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            for x in 0..<cw {
                let sx = minX + x, sy = minY + y
                var near = false
                for dy in -2...2 where !near {
                    for dx in -2...2 {
                        let nx = sx + dx, ny = sy + dy
                        if nx >= 0, ny >= 0, nx < w, ny < h, kept.contains(labels[ny * w + nx]) { near = true; break }
                    }
                }
                guard near else { continue }
                // Linear from a little below paper to dark ink, so stroke edges stay thin.
                let darkness = (paper * 0.88 - Double(values[sy * w + sx])) / (paper * 0.5)
                let alpha = UInt8(max(0, min(1, darkness)) * 255)
                rgba[(y * cw + x) * 4 + 3] = alpha  // premultiplied black: RGB stays 0
            }
        }

        // Scale to Math Writer's size: the template's x-height becomes 16 px.
        let factor = glyphXHeight / (HandwritingTemplate.xHeight * scale)
        let outW = max(1, Int((CGFloat(cw) * factor).rounded())), outH = max(1, Int((CGFloat(ch) * factor).rounded()))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let source = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = context.makeImage(), let png = pngData(scaled) else { return nil }

        let baselineInCrop = (rect.minY + HandwritingTemplate.baseline) * scale - CGFloat(y0 + minY)
        return Glyph(character: cell.character, png: png, width: outW, height: outH,
                     baseline: Int((baselineInCrop * factor).rounded()))
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
