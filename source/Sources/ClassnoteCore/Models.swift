import Foundation

public enum SegmentState: String, Codable, Sendable { case pending, transcribed, translated, failed }
public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var offset: Double
    public var duration: Double
    public var english: String
    public var chinese: String
    public var state: SegmentState
    public var error: String?
    public var audioFile: String?
    public init(id: UUID = UUID(), offset: Double, duration: Double = 0, english: String = "", chinese: String = "", state: SegmentState = .pending, audioFile: String? = nil) {
        self.id = id; self.offset = offset; self.duration = duration
        self.english = english; self.chinese = chinese; self.state = state; self.audioFile = audioFile
    }
}
public enum LectureState: String, Codable, Sendable { case recording, paused, processing, ended, interrupted }
public struct Lecture: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var title: String
    public var hasAutomaticTitle: Bool?
    public var startedAt = Date()
    public var activeSeconds: Double = 0
    public var state: LectureState = .paused
    public var isDemo: Bool
    public var segments: [TranscriptSegment] = []
    public var notes = ""
    public var noteError: String?
    // Optional fields keep v0.1 session JSON readable without a migration rewrite.
    public var courseware: Courseware?
    public var combinedNote: CombinedNote?
    public var combinedNoteError: String?
    public var courseID: UUID?
    public var inputTokens = 0
    public var outputTokens = 0
    public init(title: String, isDemo: Bool = false) { self.title = title; self.isDemo = isDemo }
    public var orderedSegments: [TranscriptSegment] {
        segments.enumerated().sorted { $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset }.map(\.element)
    }
    public var unfinishedCount: Int { segments.filter { $0.english.isEmpty || $0.state == .pending }.count }
    public var transcript: String {
        orderedSegments.filter { !$0.english.isEmpty }.map { "[\(formatTime($0.offset))] \($0.english)" }.joined(separator: "\n\n")
    }
    public func markdown(includeTranslation: Bool = true, combined: Bool = false, includeOriginal: Bool = true) -> String {
        let date = DateFormatter.localizedString(from: startedAt, dateStyle: .medium, timeStyle: .short)
        var result = "# \(title)\n\n日期：\(date)  \n有效收音时长：\(formatTime(activeSeconds))\(isDemo ? "  \n**演示数据**" : "")\n\n"
        if combined, let note = combinedNote {
            result += "## 课件综合笔记\n\n课件：\(note.source.name)（\(note.source.pageCount) 页）  \n生成时间：\(DateFormatter.localizedString(from: note.createdAt, dateStyle: .medium, timeStyle: .short))\n\n"
            if note.isPreview { result += "> 离线资料预览，未调用 AI，不是综合结论。\n\n" }
            if note.isStale(for: self) { result += "> 课堂原稿或所选课件已变化，请重新生成。以下保留上次结果。\n\n" }
            result += note.markdown + "\n\n---\n\n"
        } else if !notes.isEmpty { result += notes + "\n\n---\n\n" }
        guard includeOriginal else { return result }
        result += "## 英文原稿\n\n"
        for s in orderedSegments {
            result += "### \(formatTime(s.offset))\n\n"
            result += s.english.isEmpty ? "[此段待转录，可在 App 中重试]\n\n" : s.english + "\n\n"
            if includeTranslation && !s.chinese.isEmpty { result += s.chinese + "\n\n" }
        }
        return result
    }
}
public func formatTime(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

public final class LectureStore {
    public let root: URL
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    public func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func save(_ lecture: Lecture) throws {
        let folder = directory(lecture.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lecture)
        try data.write(to: folder.appendingPathComponent("lecture.json"), options: .atomic)
    }
    public func load() throws -> (lectures: [Lecture], unreadable: [String]) {
        try load(from: root)
    }
    public var trashRoot: URL { root.appendingPathComponent(".Trash", isDirectory: true) }
    public func loadTrash() throws -> (lectures: [Lecture], unreadable: [String]) {
        guard FileManager.default.fileExists(atPath: trashRoot.path) else { return ([], []) }
        return try load(from: trashRoot)
    }
    /// Move the whole session atomically on the same volume; retain audio and metadata.
    public func moveToTrash(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: directory(id), to: trashRoot.appendingPathComponent(id.uuidString, isDirectory: true))
    }
    public func restore(_ id: UUID) throws {
        // moveItem refuses an existing destination instead of overwriting a newer record.
        try FileManager.default.moveItem(at: trashRoot.appendingPathComponent(id.uuidString, isDirectory: true), to: directory(id))
    }
    private func load(from parent: URL) throws -> (lectures: [Lecture], unreadable: [String]) {
        var lectures: [Lecture] = []; var unreadable: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey]) where !folder.lastPathComponent.hasPrefix(".") {
            let file = folder.appendingPathComponent("lecture.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            do {
                var lecture = try JSONDecoder().decode(Lecture.self, from: Data(contentsOf: file))
                if [.recording, .paused, .processing].contains(lecture.state) { lecture.state = .interrupted }
                for i in lecture.segments.indices where lecture.segments[i].state == .pending {
                    lecture.segments[i].state = .failed
                    lecture.segments[i].error = "上次转录未完成，可用本地音频重试。"
                }
                lectures.append(lecture)
            } catch { unreadable.append(folder.lastPathComponent) }
        }
        return (lectures.sorted { $0.startedAt > $1.startedAt }, unreadable)
    }
    public func saveAudio(_ pcm: Data, lectureID: UUID, segmentID: UUID) throws -> String {
        let folder = directory(lectureID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = segmentID.uuidString + ".wav"
        try PCM.wav(pcm).write(to: folder.appendingPathComponent(filename), options: .atomic)
        return filename
    }
}
public enum PCM {
    public static let rate = 24_000
    public static func wav(_ pcm: Data) -> Data {
        var data = Data()
        func tag(_ s: String) { data.append(contentsOf: s.utf8) }
        func u32(_ n: UInt32) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ n: UInt16) { var v = n.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        tag("RIFF"); u32(UInt32(pcm.count + 36)); tag("WAVEfmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16); tag("data"); u32(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}

public enum AudioSegmentationMode: Sendable { case voiceGated, complete }

/// Complete mode forwards every PCM frame; energy controls boundaries only, never inclusion.
public struct TurnDetector {
    public var threshold: Float = 0.008
    public let mode: AudioSegmentationMode
    public private(set) var buffer = Data()
    public private(set) var active = false
    private var leadIn = Data()
    private var silence = 0.0
    public init(mode: AudioSegmentationMode = .voiceGated) { self.mode = mode }
    public mutating func push(_ data: Data, rms: Float) -> (append: Data, commit: Data?) {
        let seconds = Double(data.count) / Double(PCM.rate * 2)
        if mode == .complete {
            guard !data.isEmpty else { return (Data(), nil) }
            active = true; buffer.append(data)
            silence = rms < threshold ? silence + seconds : 0
            // Keep enough context for an accented/quiet phrase; never gate its beginning or tail.
            if buffer.count >= PCM.rate * 2 * 12 || (buffer.count >= PCM.rate * 2 * 4 && silence >= 1.2) {
                let complete = buffer; reset(); return (data, complete)
            }
            return (data, nil)
        }
        if !active {
            leadIn.append(data)
            if leadIn.count > 14_400 { leadIn.removeFirst(leadIn.count - 14_400) }
            guard rms >= threshold else { return (Data(), nil) }
            active = true; buffer = leadIn; leadIn = Data(); silence = 0
            return (buffer, nil)
        }
        buffer.append(data)
        silence = rms < threshold ? silence + seconds : 0
        if silence >= 0.85 || buffer.count >= PCM.rate * 2 * 12 {
            let complete = buffer; reset(); return (data, complete)
        }
        return (data, nil)
    }
    public mutating func flush() -> Data? {
        defer { reset() }
        if mode == .complete { return buffer.isEmpty ? nil : buffer }
        return buffer.count >= 4_800 ? buffer : nil
    }
    private mutating func reset() { buffer = Data(); leadIn = Data(); active = false; silence = 0 }
}

public enum TextChunks {
    public static func split(_ text: String, limit: Int = 12_000) -> [String] {
        precondition(limit > 0)
        var chunks: [String] = []; var current = ""
        for line in text.components(separatedBy: "\n") {
            if !current.isEmpty && current.count + line.count + 1 > limit { chunks.append(current); current = "" }
            var remainder = line[...]
            while remainder.count > limit { chunks.append(String(remainder.prefix(limit))); remainder = remainder.dropFirst(limit) }
            if !current.isEmpty { current += "\n" }; current += remainder
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
