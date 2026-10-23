import CryptoKit
import Foundation

/// One `VEVENT`, reduced to what the app shows.
public struct CalendarEvent: Sendable, Equatable {
    public var summary: String
    public var description: String?
    public var location: String?
    public var start: Date
    public var end: Date?
    public var allDay: Bool

    /// A key that survives re-downloads. CMS regenerates every `UID` on each download, so the
    /// event's own fields are the only stable identity. A moved event therefore gets a new key.
    public var contentKey: String {
        let fields = [summary, String(Int(start.timeIntervalSince1970)),
                      end.map { String(Int($0.timeIntervalSince1970)) } ?? "", location ?? ""]
        let digest = SHA256.hash(data: Data(fields.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// A small iCalendar (RFC 5545) reader: line unfolding, text escapes, UTC / TZID / all-day dates.
/// Recurrence rules are not expanded; CMS exports every occurrence as its own event.
public enum ICalendar {
    public static func events(in text: String) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var properties: [(name: String, params: [String: String], value: String)]?

        for line in unfold(text) {
            if line == "BEGIN:VEVENT" {
                properties = []
            } else if line == "END:VEVENT" {
                if let properties, let event = event(from: properties) { events.append(event) }
                properties = nil
            } else if properties != nil, let property = parse(line) {
                properties!.append(property)
            }
        }
        return events
    }

    /// Joins continuation lines (starting with a space or tab) onto the previous line.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    private static func parse(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon].split(separator: ";").map(String.init)
        guard let name = head.first?.uppercased() else { return nil }
        var params: [String: String] = [:]
        for param in head.dropFirst() {
            let parts = param.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { params[parts[0].uppercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, String(line[line.index(after: colon)...]))
    }

    private static func event(from properties: [(name: String, params: [String: String], value: String)]) -> CalendarEvent? {
        func property(_ name: String) -> (params: [String: String], value: String)? {
            properties.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        func text(_ name: String) -> String? {
            property(name).map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let startProperty = property("DTSTART"),
              let (start, allDay) = date(startProperty.value, params: startProperty.params) else { return nil }
        let end = property("DTEND").flatMap { date($0.value, params: $0.params)?.date }
        return CalendarEvent(summary: text("SUMMARY") ?? "Untitled", description: text("DESCRIPTION"),
                             location: text("LOCATION"), start: start, end: end, allDay: allDay)
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            result.append(next == "n" || next == "N" ? "\n" : next)
        }
        return result
    }

    /// `20261211T125900Z` (UTC), `20261022T101500` with `TZID=…` (local), `VALUE=DATE:20260907` (all-day).
    static func date(_ value: String, params: [String: String]) -> (date: Date, allDay: Bool)? {
        let allDay = params["VALUE"] == "DATE" || value.count == 8
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        if allDay {
            // All-day dates are calendar days in Saarbrücken.
            formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
            formatter.dateFormat = "yyyyMMdd"
            return formatter.date(from: String(value.prefix(8))).map { ($0, true) }
        }
        if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            formatter.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "Europe/Berlin")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        return formatter.date(from: value).map { ($0, false) }
    }
}
