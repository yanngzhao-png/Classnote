import Foundation
import PDFKit
import CryptoKit

public struct CoursewarePage: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var text: String
    public var id: Int { number }
    public init(number: Int, text: String) { self.number = number; self.text = text }
}
public struct CoursewareSource: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var fileName: String
    public var pageCount: Int
}
public struct Courseware: Codable, Equatable, Sendable, Identifiable {
    public var source: CoursewareSource
    public var importedAt = Date()
    public var byteCount: Int
    public var pages: [CoursewarePage]
    public var id: UUID { source.id }
    public var textPages: [CoursewarePage] { pages.filter { !$0.text.isEmpty } }
    public var emptyPageNumbers: [Int] { pages.filter { $0.text.isEmpty }.map(\.number) }
    /// Bounded handout context used to improve spelling of course terminology.
    /// It must never cause unspoken handout text to appear in the transcript.
    public var transcriptionContext: String {
        let header = "Course handout: \(source.name)\n"
        let limit = 7_500
        var result = header
        for page in textPages {
            let text = page.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !text.isEmpty else { continue }
            let block = "[PDF p.\(page.number)] \(text)"
            guard result.utf8.count + block.utf8.count + 1 <= limit else { break }
            result += block + "\n"
        }
        return result == header ? "" : result
    }
    public init(id: UUID = UUID(), name: String, byteCount: Int, pages: [CoursewarePage]) {
        source = .init(id: id, name: name, fileName: id.uuidString + ".pdf", pageCount: pages.count)
        self.byteCount = byteCount; self.pages = pages
    }
}
public struct CombinedNote: Codable, Equatable, Sendable {
    public var markdown: String
    public var source: CoursewareSource
    public var transcriptDigest: String
    public var createdAt = Date()
    public var isPreview: Bool
    public var bindings: BoundNotes?
    public init(markdown: String, source: CoursewareSource, transcript: String, isPreview: Bool = false, bindings: BoundNotes? = nil) {
        self.markdown = markdown; self.source = source
        self.bindings = bindings
        transcriptDigest = Self.digest(transcript); self.isPreview = isPreview
    }
    public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func isStale(for lecture: Lecture) -> Bool {
        lecture.courseware?.id != source.id || Self.digest(lecture.transcript) != transcriptDigest
    }
}
public struct CoursewareFailure: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct PDFImportResult: Sendable {
    public let courseware: Courseware
    public let data: Data
}
public enum PDFCoursewareImporter {
    public static let maximumBytes = 25 * 1024 * 1024
    public static let maximumPages = 300
    public static let maximumCharacters = 500_000
    public static func read(_ url: URL) throws -> PDFImportResult {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true else { throw CoursewareFailure("请选择 PDF 文件。") }
        guard (attributes.fileSize ?? 0) <= maximumBytes else { throw CoursewareFailure("PDF 超过 25 MB，请压缩或拆分后导入。") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw CoursewareFailure("PDF 超过 25 MB，请拆分后导入。") }
        return try extract(data, name: url.lastPathComponent)
    }
    public static func extract(_ data: Data, name: String) throws -> PDFImportResult {
        guard data.count <= maximumBytes else { throw CoursewareFailure("PDF 超过 25 MB，请拆分后导入。") }
        guard let document = PDFDocument(data: data) else { throw CoursewareFailure("无法打开此 PDF，文件可能损坏。") }
        guard !document.isLocked else { throw CoursewareFailure("此 PDF 受密码保护，请先解锁再导入。") }
        guard document.allowsCopying else { throw CoursewareFailure("此 PDF 禁止复制文字，无法用于课件整理。") }
        guard document.pageCount > 0, document.pageCount <= maximumPages else { throw CoursewareFailure("请导入 1–300 页的 PDF；较长课件可拆分后导入。") }
        var pages: [CoursewarePage] = []; var count = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let text = (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            count += text.count
            guard count <= maximumCharacters else { throw CoursewareFailure("课件文字超过 50 万字，请拆分后导入。") }
            pages.append(.init(number: index + 1, text: text))
        }
        return .init(courseware: Courseware(name: name, byteCount: data.count, pages: pages), data: data)
    }
}
extension LectureStore {
    public func materialURL(_ source: CoursewareSource, lectureID: UUID) throws -> URL {
        guard source.fileName == source.id.uuidString + ".pdf" else { throw CoursewareFailure("课件文件引用无效。") }
        return directory(lectureID).appendingPathComponent("Materials", isDirectory: true).appendingPathComponent(source.fileName)
    }
    /// Write a private copy, so moving the user's original PDF never breaks this session.
    public func saveMaterial(_ imported: PDFImportResult, lectureID: UUID) throws {
        let file = try materialURL(imported.courseware.source, lectureID: lectureID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imported.data.write(to: file, options: .atomic)
    }
    public func courseMaterialURL(_ source: CoursewareSource, courseID: UUID) throws -> URL {
        guard source.fileName == source.id.uuidString + ".pdf" else { throw CoursewareFailure("课件文件引用无效。") }
        return root.appendingPathComponent("Courses", isDirectory: true)
            .appendingPathComponent(courseID.uuidString, isDirectory: true)
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(source.fileName)
    }
    public func saveCourseMaterial(_ imported: PDFImportResult, courseID: UUID) throws {
        let file = try courseMaterialURL(imported.courseware.source, courseID: courseID)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imported.data.write(to: file, options: .atomic)
    }
    /// Copy the prepared course material into a lecture snapshot so later course changes do not alter old notes.
    public func copyCourseMaterial(_ material: Courseware, courseID: UUID, lectureID: UUID) throws {
        let source = try courseMaterialURL(material.source, courseID: courseID)
        guard FileManager.default.fileExists(atPath: source.path) else { throw CoursewareFailure("课程课件副本不存在，请重新导入。") }
        let destination = try materialURL(material.source, lectureID: lectureID)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
