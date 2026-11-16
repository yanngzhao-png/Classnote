import Foundation

public struct ScheduleSource: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: String
    public var link: String?
    public var defaultTimeZoneID: String?
    public var enabled: Bool
    public var updatedAt: Date
    public var from: Date
    public var through: Date
    public init(id: UUID = UUID(), name: String, kind: String, link: String? = nil, from: Date, through: Date) {
        self.id = id; self.name = name; self.kind = kind; self.link = link; defaultTimeZoneID = nil; enabled = true; updatedAt = Date(); self.from = from; self.through = through
    }
}
public struct ScheduleEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var sourceID: UUID
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneID: String
    public var location: String
    public var courseID: UUID?
    public init(id: String, sourceID: UUID, title: String, start: Date, end: Date, timeZoneID: String, location: String = "", courseID: UUID? = nil) {
        self.id = id; self.sourceID = sourceID; self.title = title; self.start = start; self.end = end; self.timeZoneID = timeZoneID; self.location = location; self.courseID = courseID
    }
}
public struct ScheduleBook: Codable, Equatable, Sendable {
    public var courseAliases: [String: UUID]?
    public var sources: [ScheduleSource] = []
    public var events: [ScheduleEvent] = []
    public init() {}
    public func candidates(at date: Date, courses: [Course]) -> [ScheduleEvent] {
        let enabled = Set(sources.filter(\.enabled).map(\.id))
        let valid = events.filter { enabled.contains($0.sourceID) }
        let current = valid.filter { $0.start <= date && date < $0.end }
        let chosen = current.isEmpty ? valid.filter { $0.start > date && $0.start.timeIntervalSince(date) <= 600 } : current
        return chosen.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
    public func suggestedCourse(at date: Date, courses: [Course]) -> UUID? {
        let matches = candidates(at: date, courses: courses)
        let ids = Set(matches.compactMap(\.courseID))
        guard !matches.isEmpty, matches.allSatisfy({ event in courses.contains { $0.id == event.courseID } }), ids.count == 1 else { return nil }
        return ids.first
    }
    public mutating func replace(_ source: ScheduleSource, with imported: [ScheduleEvent]) {
        let old = events.filter { $0.sourceID == source.id }
        var mapping: [String: UUID] = [:]
        for e in old { if let id = e.courseID { mapping[e.title] = id } }
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        events.removeAll { $0.sourceID == source.id }
        events += imported.map { event in
            var result = event
            // Keep explicit unassignment and use title mapping for newly expanded dates.
            if let prior = previous[event.id] { result.courseID = prior.courseID }
            else { result.courseID = mapping[event.title] ?? event.courseID }
            return result
        }
        sources.removeAll { $0.id == source.id }; sources.append(source)
    }
}
extension LectureStore {
    public func loadSchedule() throws -> ScheduleBook {
        try recoverScheduleGrouping()
        let url = root.appendingPathComponent(".schedule.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ScheduleBook() }
        let book = try JSONDecoder().decode(ScheduleBook.self, from: Data(contentsOf: url)); try validateSchedule(book); return book
    }
    public func saveSchedule(_ book: ScheduleBook) throws {
        try validateSchedule(book)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(book).write(to: root.appendingPathComponent(".schedule.json"), options: .atomic)
    }
    func validateSchedule(_ book: ScheduleBook) throws {
        let ids = Set(book.sources.map(\.id))
        guard ids.count == book.sources.count, Set(book.events.map(\.id)).count == book.events.count, book.events.count <= 20000,
              book.sources.allSatisfy({ $0.from < $0.through }),
              book.events.allSatisfy({ ids.contains($0.sourceID) && !$0.title.isEmpty && $0.start < $0.end && TimeZone(identifier: $0.timeZoneID) != nil }) else {
            throw CoursewareFailure("课表数据不完整或重复，原文件已保留。")
        }
    }
}
public struct ScheduleImport: Sendable {
    public var events: [ScheduleEvent]
    public var warnings: [String]
    public init(events: [ScheduleEvent], warnings: [String] = []) { self.events = events; self.warnings = warnings }
}
public enum ScheduleImporter {
    public static let maximumBytes = 5_000_000
    public static func range(from: Date, through: Date) throws {
        guard through > from, through.timeIntervalSince(from) <= 370 * 86400 else { throw CoursewareFailure("导入日期范围需为 1–370 天。") }
    }
    public static func subscriptionURL(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("webcal://") { value = "https://" + value.dropFirst(9) }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw CoursewareFailure("请输入 HTTPS 或 webcal 日历订阅链接。")
        }
        return url
    }
    public static func localDate(_ text: String, zone: TimeZone) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.isLenient = false
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm"] {
            f.dateFormat = format
            if let date = f.date(from: text), f.string(from: date) == text { return date }
        }
        return nil
    }
    static func eventID(source: UUID, uid: String, original: Date) -> String { source.uuidString + "|" + uid + "|" + String(Int(original.timeIntervalSince1970)) }
    public static func csv(_ data: Data, source: ScheduleSource, defaultZone: TimeZone) throws -> ScheduleImport {
        try range(from: source.from, through: source.through)
        guard data.count <= maximumBytes, var text = String(data: data, encoding: .utf8) else { throw CoursewareFailure("CSV 需为 UTF-8，且不超过 5 MB。") }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let rows = try csvRows(text)
        guard let header = rows.first else { throw CoursewareFailure("CSV 没有内容。") }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard Set(names).count == names.count else { throw CoursewareFailure("CSV 列名重复。") }
        func column(_ choices: [String]) -> Int? { names.firstIndex { choices.contains($0) } }
        guard let title = column(["title","course","课程","课程名称"]), let start = column(["start","开始"]), let end = column(["end","结束"]) else {
            throw CoursewareFailure("CSV 必须包含 title,start,end 列；可加 timezone,location。日期示例：2026-11-12 09:00。")
        }
        let tz = column(["timezone","时区"]), location = column(["location","地点"])
        var events: [ScheduleEvent] = []; var seen: Set<String> = []
        for (i,row) in rows.dropFirst().enumerated() where !row.allSatisfy({ $0.isEmpty }) {
            guard row.count == header.count else { throw CoursewareFailure("CSV 第 \(i + 2) 行列数不一致。") }
            let zoneText = tz.map { row[$0] } ?? ""
            guard let zone = zoneText.isEmpty ? defaultZone : TimeZone(identifier: zoneText), let begin = localDate(row[start], zone: zone), let finish = localDate(row[end], zone: zone), begin < finish, finish.timeIntervalSince(begin) <= 86400 else {
                throw CoursewareFailure("CSV 第 \(i + 2) 行日期、时区或结束时间无效。")
            }
            let name = try Course.validatedName(row[title]); let uid = name + "|" + String(Int(begin.timeIntervalSince1970))
            let id = eventID(source: source.id, uid: uid, original: begin)
            if begin < source.through && finish > source.from && seen.insert(id).inserted {
                events.append(.init(id: id, sourceID: source.id, title: name, start: begin, end: finish, timeZoneID: zone.identifier, location: location.map { row[$0] } ?? ""))
            }
        }
        return .init(events: events.sorted { $0.start < $1.start })
    }
    private static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")); var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(c) }
            } else if c == "," || c == "\n" {
                row.append(field); field = ""; closed = false
                if c == "\n" { rows.append(row); row = [] }
            } else if c == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed && c != "\"" else { throw CoursewareFailure("CSV 引号格式有误。") }
                field.append(c)
            }
            i += 1
        }
        guard !quoted else { throw CoursewareFailure("CSV 有未闭合的引号。") }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
