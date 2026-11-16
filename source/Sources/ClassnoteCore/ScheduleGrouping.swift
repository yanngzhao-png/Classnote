import Foundation

/// Calendar occurrence titles remain intact; only the course label is cleaned.
public struct ScheduleCourseIdentity: Equatable, Sendable {
    public let key: String
    public let name: String
    public init(_ title: String) {
        func replace(_ value: String, _ pattern: String, _ replacement: String = "") -> String {
            value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        var value = replace(title.trimmingCharacters(in: .whitespacesAndNewlines), #"\s*<\s*[0-9,\s–—-]+>\s*$"#)
        let code = #"(?:[0-9]+[A-Za-z]+[0-9]+|[A-Za-z]{2,}[0-9]{2,}[A-Za-z]?)"#
        let regex = try! NSRegularExpression(pattern: "^(" + code + "(?:\\s*/\\s*" + code + ")*)\\s+(.+)$")
        let range = NSRange(value.startIndex..., in: value)
        var codes = ""
        if let match = regex.firstMatch(in: value, range: range), let a = Range(match.range(at: 1), in: value), let b = Range(match.range(at: 2), in: value) {
            codes = value[a].uppercased().components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }.sorted().joined(separator: "/")
            value = String(value[b])
        }
        if codes.isEmpty {
            let prefix = try! NSRegularExpression(pattern: #"^([A-Z]{2,6})\s+(.+)$"#)
            if let match = prefix.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
               let codeRange = Range(match.range(at: 1), in: value), let nameRange = Range(match.range(at: 2), in: value),
               value[nameRange].rangeOfCharacter(from: .lowercaseLetters) != nil {
                codes = String(value[codeRange]).lowercased()
                value = String(value[nameRange])
            }
        }
        if !codes.isEmpty {
            value = replace(value, #"(?i)\s+(?:NSY|SY|SEM[0-9]+)(?=\s+(?:[0-9]{4,}/)?(?:lecture|seminar|sem|smg|tut(?:orial)?|lab|workshop|lec))"#)
        }
        // Administrative activity paths, e.g. 000001/Sem/01 or Lecture02/01.
        value = replace(value, #"(?i)\s+(?:[0-9]{4,}/)?(?:lecture|seminar|sem|smg|tut(?:orial)?|lab|workshop|lec)[0-9]*/.*$"#)
        value = replace(value, #"(?i)\s+[0-9]{4,}/(?:lecture|seminar|sem|smg|tut(?:orial)?|lab|workshop|lec)[^\s]*.*$"#)
        // Human-written activity suffixes, without deleting subject words inside a title.
        value = replace(value, #"(?i)\s*(?:[-–—·,:]\s*|\(\s*)(?:lecture|seminar|tutorial|lab|workshop|讲座|研讨课)\s*[0-9]*\s*\)?\s*$"#)
        value = replace(value, #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_:/,."))
        if value.isEmpty { value = "Untitled course" }
        let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        key = (codes.isEmpty ? "name:" : "codes:" + codes.lowercased() + "|name:") + normalized
        let label = replace(replace(value, #"[0-9]+"#), #"\s+"#, " ").trimmingCharacters(in: .whitespacesAndNewlines)
        name = String((label.isEmpty ? "Untitled course" : label).prefix(100))
    }
}
public struct ScheduleCourseGroup: Identifiable, Sendable {
    public var id: String { identity.key }
    public var identity: ScheduleCourseIdentity
    public var events: [ScheduleEvent]
}
public struct ScheduleGrouping: Sendable {
    public var book: ScheduleBook
    public var courses: [Course]
    public var redirects: [UUID: UUID]
}
extension ScheduleBook {
    public static func courseGroups(_ events: [ScheduleEvent]) -> [ScheduleCourseGroup] {
        Dictionary(grouping: events, by: { ScheduleCourseIdentity($0.title).key }).map { _, values in
            let sorted = values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            return ScheduleCourseGroup(identity: ScheduleCourseIdentity(sorted[0].title), events: sorted)
        }.sorted { $0.identity.key < $1.identity.key }
    }
    /// Idempotent across refreshes and renamed courses. Never rewrites lecture files.
    public func groupingCourses(_ original: [Course], protectedIDs: Set<UUID> = [], overrides: [String: UUID] = [:]) -> ScheduleGrouping {
        var book = self, courses = original, redirects: [UUID: UUID] = [:]
        var aliases = courseAliases ?? [:]
        var assignments: [String: UUID] = [:]
        let groups = Self.courseGroups(events)
        let groupKeysByCourse = Dictionary(grouping: groups.flatMap { group in
            Set(group.events.compactMap(\.courseID)).map { ($0, group.id) }
        }, by: \.0).mapValues { Set($0.map(\.1)) }
        func valid(_ id: UUID?) -> UUID? { id.flatMap { id in courses.contains { $0.id == id } ? id : nil } }
        for group in groups {
            let key = group.id
            let bound = Set(group.events.compactMap(\.courseID))
            let candidates = courses.filter {
                ScheduleCourseIdentity($0.name).key == key || (bound.contains($0.id) && groupKeysByCourse[$0.id] == [key])
            }.sorted {
                if protectedIDs.contains($0.id) != protectedIDs.contains($1.id) { return protectedIDs.contains($0.id) }
                if bound.contains($0.id) != bound.contains($1.id) { return bound.contains($0.id) }
                return $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            let remembered = valid(aliases[key])
            let id: UUID
            if let chosen = valid(overrides[key]) ?? remembered ?? candidates.first?.id { id = chosen }
            else {
                let course = Course(name: group.identity.name); courses.append(course); id = course.id
            }
            // Clean labels from the old import workflow once, preserving later custom names.
            if let index = courses.firstIndex(where: { $0.id == id }),
               ((remembered == nil && overrides[key] == nil) || courses[index].name.contains(where: \.isNumber)),
               ScheduleCourseIdentity(courses[index].name).key == key {
                courses[index].name = group.identity.name
            }
            aliases[key] = id; assignments[key] = id
        }
        for index in book.events.indices { book.events[index].courseID = assignments[ScheduleCourseIdentity(book.events[index].title).key] }
        // Consolidate empty legacy occurrence menus only. Recorded/deleted/unreadable sessions are protected.
        let used = Set(book.events.compactMap(\.courseID))
        for course in courses where !protectedIDs.contains(course.id) && !used.contains(course.id) {
            let key = ScheduleCourseIdentity(course.name).key
            if let winner = assignments[key], winner != course.id { redirects[course.id] = winner }
        }
        courses.removeAll { redirects[$0.id] != nil }
        aliases = aliases.mapValues { redirects[$0] ?? $0 }
        book.courseAliases = aliases
        return .init(book: book, courses: courses, redirects: redirects)
    }
}

private struct ScheduleGroupingJournal: Codable {
    var courses: [Course]
    var book: ScheduleBook
}
extension LectureStore {
    /// A write-ahead journal makes the two catalog files recover together after interruption.
    public func saveScheduleGrouping(_ result: ScheduleGrouping) throws {
        try validateCourses(result.courses); try validateSchedule(result.book)
        let journal = ScheduleGroupingJournal(courses: result.courses, book: result.book)
        try JSONEncoder().encode(journal).write(to: root.appendingPathComponent(".schedule-grouping.json"), options: .atomic)
        try recoverScheduleGrouping()
    }
    public func recoverScheduleGrouping() throws {
        let url = root.appendingPathComponent(".schedule-grouping.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(ScheduleGroupingJournal.self, from: Data(contentsOf: url))
        try validateCourses(journal.courses); try validateSchedule(journal.book)
        try saveCourses(journal.courses); try saveSchedule(journal.book)
        try FileManager.default.removeItem(at: url)
    }
}
