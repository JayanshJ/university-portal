import AppKit
import CoreImage
import PDFKit

/// Debug aid: launched with `--template-check`, fills the handwriting template with a handwriting
/// font, turns each page into a tilted, rotated, unevenly lit "photo", reads it back with
/// TemplateReader, and prints what was found plus "SHOT:<name>:<base64 PNG>" lines. Then quits.
@MainActor
enum TemplateCheck {
    static func run() async {
        guard let document = PDFDocument(data: HandwritingTemplate.pdf()) else { return finish("no template") }
        print("template pages: \(document.pageCount), cells: \(HandwritingTemplate.cells.count)")
        var shots: [(String, CGImage)] = []
        var photoPages: [TemplateReader.Page] = []
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number), let filled = fill(page, number: number) else { continue }
            for (name, rotation, tilt) in [("straight", 0.0, false), ("photo", 0.12, true), ("upside-down", Double.pi + 0.05, true)] {
                guard let photo = photograph(filled, rotation: rotation, tilt: tilt) else { continue }
                if number == 0 && name == "photo" { shots.append(("photo-p1", photo)) }
                do {
                    let read = try TemplateReader.read(photo)
                    let expected = HandwritingTemplate.cells.filter { $0.page == number }.count
                    print("page \(number + 1) \(name): read as page \(read.number + 1), \(read.glyphs.count)/\(expected) boxes, empty: \(String(read.empty))")
                    if number == 0 && name == "photo" { shots.append(("glyphs-p1", sheet(read.glyphs))) }
                    if name == "photo" { photoPages.append(read) }
                } catch {
                    print("page \(number + 1) \(name): FAILED \(error.localizedDescription)")
                }
            }
        }
        // End to end: the photographed pages as a library (in a temporary folder, not the
        // student's real one), then a solution written with it.
        let library = FileManager.default.temporaryDirectory.appending(path: "template-check-glyphs", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HandwritingProfile.write(photoPages, to: library)
            let glyphs = try GlyphLibrary.load(from: library)
            let markup = SolveCheck.demoMarkup + "\n\nThe quick brown fox jumps over the lazy dog: Ärger über Öl, [F]a + b|2[/F] ≤ [R]x² + 1[/R], α → β."
            let validation = HandwritingRenderer.validate(markup, library: glyphs)
            let started = Date()
            let (pages, dropped) = HandwritingRenderer.render(markup, library: glyphs, seed: 7)
            print("library: \(glyphs.characters.count) characters; validation errors: \(validation.errors); dropped: \(dropped); \(pages.count) page(s) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; pdf \(HandwritingRenderer.pdf(pages).count) bytes")
            if let first = pages.first { shots.append(("rendered", first)) }
        } catch {
            print("end to end FAILED: \(error)")
        }
        for (name, image) in shots {
            if let png = TemplateReader.pngData(image) { print("SHOT:\(name):" + png.base64EncodedString()) }
        }
        finish("done")
    }

    /// A glyph library written from photographed template pages filled in a handwriting font, in a
    /// temporary folder (never the student's own handwriting). Nil when the template can't be read.
    static func syntheticLibrary(named name: String) -> URL? {
        guard let document = PDFDocument(data: HandwritingTemplate.pdf()) else { return nil }
        var pages: [TemplateReader.Page] = []
        for number in 0..<document.pageCount {
            guard let page = document.page(at: number), let filled = fill(page, number: number),
                  let photo = photograph(filled, rotation: 0.12, tilt: true),
                  let read = try? TemplateReader.read(photo) else { continue }
            pages.append(read)
        }
        let library = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
            try HandwritingProfile.write(pages, to: library)
            return library
        } catch {
            return nil
        }
    }

    private static func finish(_ message: String) {
        print(message)
        fflush(stdout)
        NSApp.terminate(nil)
    }

    /// The page with every box written in a handwriting font, dark blue, on the baseline.
    static func fill(_ page: PDFPage, number: Int) -> CGImage? {
        let s: CGFloat = 3
        let size = HandwritingTemplate.pageSize
        guard let context = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s))
        context.scaleBy(x: s, y: s)
        page.draw(with: .mediaBox, to: context)
        let font = NSFont(name: "Bradley Hand", size: 22) ?? NSFont.systemFont(ofSize: 22)
        let ink = NSColor(red: 0.08, green: 0.12, blue: 0.35, alpha: 1)
        for cell in HandwritingTemplate.cells where cell.page == number {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(cell.character), attributes: [.font: font, .foregroundColor: ink]))
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let r = cell.rect
            context.textPosition = CGPoint(x: r.midX - width / 2 + CGFloat.random(in: -3...3), y: size.height - (r.minY + HandwritingTemplate.baseline))
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }

    /// A phone photo of it: on a desk, rotated, in perspective, with a shadow gradient and blur.
    static func photograph(_ image: CGImage, rotation: Double, tilt: Bool) -> CGImage? {
        var ci = CIImage(cgImage: image)
        let w = ci.extent.width, h = ci.extent.height
        if tilt, let f = CIFilter(name: "CIPerspectiveTransform") {
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 90, y: h - 40), forKey: "inputTopLeft")
            f.setValue(CIVector(x: w - 30, y: h - 120), forKey: "inputTopRight")
            f.setValue(CIVector(x: w - 110, y: 60), forKey: "inputBottomRight")
            f.setValue(CIVector(x: 20, y: 10), forKey: "inputBottomLeft")
            ci = f.outputImage ?? ci
        }
        ci = ci.transformed(by: CGAffineTransform(rotationAngle: CGFloat(rotation)))
        let desk = CIImage(color: CIColor(red: 0.35, green: 0.3, blue: 0.25)).cropped(to: ci.extent.insetBy(dx: -200, dy: -200))
        ci = ci.composited(over: desk)
        if tilt, let g = CIFilter(name: "CILinearGradient") {
            g.setValue(CIVector(x: ci.extent.minX, y: ci.extent.minY), forKey: "inputPoint0")
            g.setValue(CIVector(x: ci.extent.maxX, y: ci.extent.maxY), forKey: "inputPoint1")
            g.setValue(CIColor(red: 0.55, green: 0.55, blue: 0.55), forKey: "inputColor0")
            g.setValue(CIColor(red: 1, green: 1, blue: 1), forKey: "inputColor1")
            if let shade = g.outputImage?.cropped(to: ci.extent) { ci = ci.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: shade]) }
            ci = ci.applyingGaussianBlur(sigma: 1.2).cropped(to: ci.extent)
        }
        return CIContext().createCGImage(ci, from: ci.extent)
    }

    /// The first glyph of each character on a strip of paper.
    static func sheet(_ glyphs: [TemplateReader.Glyph]) -> CGImage {
        let perRow = 24, cell = 40
        var seen = Set<Character>()
        let unique = glyphs.filter { seen.insert($0.character).inserted }
        let rows = (unique.count + perRow - 1) / perRow
        let context = CGContext(data: nil, width: perRow * cell, height: rows * cell, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: perRow * cell, height: rows * cell))
        for (i, glyph) in unique.enumerated() {
            guard let image = NSImage(data: glyph.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let x = (i % perRow) * cell + 8, baseline = (rows - 1 - i / perRow) * cell + 12
            context.draw(image, in: CGRect(x: x, y: baseline - (glyph.height - glyph.baseline), width: glyph.width, height: glyph.height))
            context.setStrokeColor(CGColor(red: 1, green: 0.6, blue: 0.6, alpha: 1))
            context.stroke(CGRect(x: CGFloat(x - 4), y: CGFloat(baseline), width: CGFloat(cell - 8), height: 0.5))
        }
        return context.makeImage()!
    }
}
