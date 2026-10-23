import Foundation
import SwiftSoup

/// A course on `/system/courses`, under its term heading.
public struct CMSCourseListing: Sendable, Equatable, Identifiable {
    public var slug: String
    public var name: String
    public var lecturer: String?
    /// The heading's term, e.g. "Winter term 2026/2027"; nil for headings without one.
    public var term: AcademicTerm?
    public var termHeading: String

    public var id: String { slug }
}

public struct CMSNewsEntry: Sendable, Equatable {
    public var id: Int
    public var title: String
    public var postedAt: Date?
    public var author: String?
    public var bodyHtml: String
}

public struct CMSCalendarCategory: Sendable, Equatable {
    public var id: Int
    public var name: String
}

/// A file on `/<slug>/materials/`, linked as `/<slug>/dl/<id>/<filename>`.
public struct CMSMaterial: Sendable, Equatable {
    public var id: Int
    public var filename: String
    public var title: String
    public var section: String?
    /// Site-relative path of the download.
    public var path: String
}

/// A link to another site listed among the materials (e.g. a code folder or an interactive sheet).
public struct CMSMaterialLink: Sendable, Equatable {
    public var url: String
    public var title: String
    public var section: String?
}

public enum CMSPageError: Error, Equatable {
    case unexpectedMarkup(String)
}

/// Readers for the CMS's server-rendered pages. Each one checks for the structure it relies on,
/// so a redesign shows up as an error (and a degraded source) rather than as silently empty data.
enum CMSPages {
    /// `/system/courses`: one `<h3>` term heading followed by a table of courses.
    static func courses(_ html: String) throws -> [CMSCourseListing] {
        let document = try SwiftSoup.parse(html)
        let headings = try document.select("h3")
        guard !headings.isEmpty() else { throw CMSPageError.unexpectedMarkup("course list has no term headings") }

        var listings: [CMSCourseListing] = []
        for heading in headings {
            let termHeading = try heading.text()
            guard let table = try heading.nextElementSibling(), table.tagName() == "table" else { continue }
            for row in try table.select("tr") {
                guard let link = try row.select("h6 a[href]").first() else { continue }
                let href = try link.attr("href")
                guard let slug = href.split(separator: "/").last.map(String.init), !slug.isEmpty, slug != ".." else { continue }
                let lecturer = try row.select("div.text-muted").first()?.text()
                listings.append(CMSCourseListing(
                    slug: slug, name: try link.text(),
                    lecturer: lecturer.flatMap { $0.isEmpty ? nil : $0 },
                    term: AcademicTerm.parse(termHeading), termHeading: termHeading))
            }
        }
        guard !listings.isEmpty else { throw CMSPageError.unexpectedMarkup("course list has no courses") }
        return listings
    }

    /// A course's main page: each news entry is an `<h4>` link to `news/view/<id>`, a "Written on … by …"
    /// line, and the body. Long entries come twice, shortened (`.collapse.show`) and full (`.collapse`).
    static func news(_ html: String) throws -> [CMSNewsEntry] {
        let document = try SwiftSoup.parse(html)
        var entries: [CMSNewsEntry] = []
        for link in try document.select("h4 a[href*=/news/view/]") {
            let href = try link.attr("href")
            guard let id = href.split(separator: "/").last.flatMap({ Int($0) }),
                  let cell = link.parents().first(where: { $0.tagName() == "td" }) else { continue }

            let stamp = try cell.select("span[data-bs-title]").first()
            let postedAt = try stamp.flatMap { try date(fromTooltip: $0.attr("data-bs-title")) ?? date(fromShort: $0.text()) }
            let byline = try cell.select("small").first()?.text() ?? ""
            // "Written on 20.10.26 by …" or "Geschrieben am 22.10.26 (letzte Änderung am …) von …"
            let author = (byline.range(of: " by ", options: .backwards) ?? byline.range(of: " von ", options: .backwards))
                .map { String(byline[$0.upperBound...]).trimmingCharacters(in: .whitespaces) }

            // Long entries come as a shortened and a full `.collapse` block; short ones are plain
            // paragraphs after the byline.
            let collapses = try cell.select("div.collapse")
            let bodyHtml: String
            if let full = collapses.first(where: { !$0.hasClass("show") }) ?? collapses.first() {
                bodyHtml = try full.html()
            } else {
                let byline = try cell.select("small").first()?.parents().first { $0.parent() == cell }
                bodyHtml = try cell.children().filter { child in
                    child.tagName() != "h4" && child.tagName() != "a" && child !== byline
                }.map { try $0.outerHtml() }.joined(separator: "\n")
            }
            entries.append(CMSNewsEntry(id: id, title: try link.text(), postedAt: postedAt,
                                        author: author.flatMap { $0.isEmpty ? nil : $0 },
                                        bodyHtml: bodyHtml.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return entries
    }

    /// `/<slug>/termine`: the "Export a category" links `…/termine/events/download/<id>`.
    static func calendarCategories(_ html: String, slug: String) throws -> [CMSCalendarCategory] {
        let document = try SwiftSoup.parse(html)
        let pattern = try NSRegularExpression(pattern: "^/\(NSRegularExpression.escapedPattern(for: slug))/termine/events/download/(\\d+)$")
        var seen = Set<Int>()
        return try document.select("a[href]").compactMap { link in
            let href = try link.attr("href")
            guard let match = pattern.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
                  let range = Range(match.range(at: 1), in: href), let id = Int(href[range]),
                  seen.insert(id).inserted else { return nil }
            return CMSCalendarCategory(id: id, name: try link.text())
        }
    }

    /// The materials page (logged in): files (`/<slug>/dl/<id>/<file>`) and links to other sites,
    /// each with the nearest preceding section heading or accordion button. Same-site links that are
    /// not files ("Download all" zips, placeholders pointing back at the page) are skipped.
    static func materials(_ html: String, slug: String) throws -> [CMSMaterial] {
        try materialsPage(html, slug: slug).files
    }

    static func materialsPage(_ html: String, slug: String) throws -> (files: [CMSMaterial], links: [CMSMaterialLink]) {
        let document = try SwiftSoup.parse(html)
        let root = try document.select("#content").first() ?? document
        let pattern = try NSRegularExpression(
            pattern: "^(?:https?://[^/]+)?(/\(NSRegularExpression.escapedPattern(for: slug))/dl/(\\d+)/([^?#]+))")
        let cmsHost = CMSClient.siteURL.host
        var section: String?
        var order: [Int] = []
        var byId: [Int: CMSMaterial] = [:]
        var links: [CMSMaterialLink] = []

        for element in try root.select("h3, h4, h5, .accordion-button, a[href]") {
            guard element.tagName() == "a", !element.hasClass("accordion-button") else {
                let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { section = text }
                continue
            }
            let href = try element.attr("href")
            let text = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = pattern.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
                  let pathRange = Range(match.range(at: 1), in: href),
                  let idRange = Range(match.range(at: 2), in: href), let id = Int(href[idRange]),
                  let nameRange = Range(match.range(at: 3), in: href) else {
                if let url = URL(string: href), let host = url.host, host != cmsHost,
                   ["http", "https"].contains(url.scheme ?? ""), !text.isEmpty,
                   !links.contains(where: { $0.url == href }) {
                    links.append(CMSMaterialLink(url: href, title: text, section: section))
                }
                continue
            }
            let filename = String(href[nameRange]).removingPercentEncoding ?? String(href[nameRange])

            if var existing = byId[id] {
                // The same file linked twice (e.g. a name and a download icon): keep the better title.
                if existing.title == existing.filename, !text.isEmpty { existing.title = text }
                byId[id] = existing
                continue
            }
            order.append(id)
            byId[id] = CMSMaterial(id: id, filename: filename, title: text.isEmpty ? filename : text,
                                   section: section, path: String(href[pathRange]))
        }
        return (order.compactMap { byId[$0] }, links)
    }

    /// Diagnostics for the parser: every link inside the page content that is not a `dl` file link,
    /// with its text. Addresses only; no cookies or form values.
    static func otherContentLinks(_ html: String, slug: String) throws -> [String] {
        let document = try SwiftSoup.parse(html)
        let content = try document.select("#content").first() ?? document.body()
        return try content?.select("a[href]").compactMap { link in
            let href = try link.attr("href")
            guard !href.contains("/\(slug)/dl/"), !href.hasPrefix("#"), !href.hasPrefix("mailto:") else { return nil }
            let text = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(href) [\(text.prefix(60))]"
        } ?? []
    }

    private static func berlinFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = format
        return formatter
    }

    /// "20.10.2026 12:36:50", in Saarbrücken time.
    static func date(fromTooltip text: String) -> Date? {
        berlinFormatter("dd.MM.yyyy HH:mm:ss").date(from: text.trimmingCharacters(in: .whitespaces))
    }

    /// "20.10.26"
    static func date(fromShort text: String) -> Date? {
        berlinFormatter("dd.MM.yy").date(from: text.trimmingCharacters(in: .whitespaces))
    }
}
