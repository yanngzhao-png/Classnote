import Foundation

public struct Course: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    /// Optional material prepared before class; a lecture receives a snapshot at start time.
    public var courseware: Courseware?
    private enum CodingKeys: String, CodingKey { case id, name, createdAt, courseware }
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), courseware: Courseware? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.courseware = courseware
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        courseware = try container.decodeIfPresent(Courseware.self, forKey: .courseware)
    }
    /// Virtual group: old records stay readable without rewriting their stored content.
    public static let unfiled = Course(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "未分类课堂", createdAt: .distantPast)
    public static func validatedName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100, !clean.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else {
            throw CoursewareFailure("课程名称需为 1–100 个字符，不能包含换行。")
        }
        return clean
    }
    public static func groupID(for lecture: Lecture, courses: [Course]) -> UUID {
        courses.first(where: { $0.id == lecture.courseID })?.id ?? unfiled.id
    }
    public static func records(in course: Course, courses: [Course], lectures: [Lecture]) -> [Lecture] {
        lectures.filter { groupID(for: $0, courses: courses) == course.id }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
    }
}
extension LectureStore {
    private var coursesURL: URL { root.appendingPathComponent(".courses.json") }
    public func loadCourses() throws -> [Course] {
        try recoverScheduleGrouping()
        guard FileManager.default.fileExists(atPath: coursesURL.path) else { return [] }
        let courses = try JSONDecoder().decode([Course].self, from: Data(contentsOf: coursesURL))
        try validateCourses(courses)
        return courses
    }
    public func saveCourses(_ courses: [Course]) throws {
        try validateCourses(courses)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(courses).write(to: coursesURL, options: .atomic)
    }
    func validateCourses(_ courses: [Course]) throws {
        guard Set(courses.map(\.id)).count == courses.count, !courses.contains(where: { $0.id == Course.unfiled.id }) else {
            throw CoursewareFailure("课程目录存在重复或保留编号，原文件已保留。")
        }
        for course in courses { _ = try Course.validatedName(course.name) }
    }
}

public struct CourseExportResult: Sendable {
    public var directory: URL
    public var count: Int
    public var missingNotes: Int
}
public enum CourseNotesExport {
    public static func safeName(_ text: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:\n\r\t").union(.controlCharacters)
        let value = text.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        for character in value {
            guard bounded.utf8.count + String(character).utf8.count <= 120 else { break }
            bounded.append(character)
        }
        let short = bounded.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return short.isEmpty ? "课堂笔记" : short
    }
    public static func hasNotes(_ lecture: Lecture) -> Bool {
        (lecture.combinedNote.map { !$0.isPreview && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false)
            || !lecture.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func content(_ lecture: Lecture, includeOriginal: Bool) -> String {
        let combined = lecture.combinedNote.map { !$0.isPreview && !$0.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        var text = lecture.markdown(combined: combined, includeOriginal: includeOriginal)
        if !hasNotes(lecture) { text += "\n> 此次课堂尚未生成笔记，请回到 App 整理。\n" }
        if lecture.courseware != nil && !combined { text += "\n> 此次导出不含已选课件的关联结果；请在 App 内生成关联笔记。\n" }
        if lecture.state != .ended { text += "\n> 此记录未正常结束，导出的是当前已保存内容。\n" }
        if lecture.unfinishedCount > 0 { text += "\n> 有 \(lecture.unfinishedCount) 段英文原稿尚未完成。\n" }
        return text
    }
    /// Writes into a new folder only. Repeated exports never replace a user's previous export.
    public static func write(course: Course, courses: [Course], lectures: [Lecture], parent: URL, includeOriginal: Bool) throws -> CourseExportResult {
        let records = Course.records(in: course, courses: courses, lectures: lectures).reversed()
        guard !records.isEmpty else { throw CoursewareFailure("这门课程还没有课堂记录。") }
        let fm = FileManager.default
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".classnote-export-" + token, isDirectory: true)
        let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyyMMdd-HHmmss"
        let destination = parent.appendingPathComponent(safeName(course.name) + "-笔记-" + stamp.string(from: Date()) + "-" + String(token.prefix(8)), isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var index = "# \(course.name) · 课堂笔记\n\n共 \(records.count) 次课堂，按日期从早到晚排列。\n\n"
            var merged = "# \(course.name) · 笔记合集\n\n"
            var missing = 0
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.dateFormat = "yyyy-MM-dd"
            for (offset, lecture) in records.enumerated() {
                let filename = String(format: "%03d", offset + 1) + "-" + date.string(from: lecture.startedAt) + "-" + safeName(lecture.title) + "-" + String(lecture.id.uuidString.prefix(8)) + ".md"
                let text = content(lecture, includeOriginal: includeOriginal)
                try text.write(to: staging.appendingPathComponent(filename), atomically: true, encoding: .utf8)
                let has = hasNotes(lecture); if !has { missing += 1 }
                let label = lecture.title.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）").replacingOccurrences(of: "\n", with: " ")
                let link = filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? filename
                index += "- [\(date.string(from: lecture.startedAt)) · \(label)](\(link))\(has ? "" : " — 尚未生成笔记")\n"
                merged += "---\n\n" + text + "\n\n"
            }
            index += "\n包括：每次课堂单独的 Markdown 文件和「全部笔记.md」。\(includeOriginal ? "包含双语原稿。" : "本次仅导出笔记，不附原稿。")\n\n尚未生成笔记：\(missing) 次，文件中有明确提示。课件来源名、页码和摘录随笔记保留；不导出录音或 PDF 原文件。\n"
            try index.write(to: staging.appendingPathComponent("课程索引.md"), atomically: true, encoding: .utf8)
            try merged.write(to: staging.appendingPathComponent("全部笔记.md"), atomically: true, encoding: .utf8)
            try fm.moveItem(at: staging, to: destination)
            return .init(directory: destination, count: records.count, missingNotes: missing)
        } catch { try? fm.removeItem(at: staging); throw error }
    }
}
