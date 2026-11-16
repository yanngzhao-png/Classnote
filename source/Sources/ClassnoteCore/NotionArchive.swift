import Foundation
import CryptoKit

public struct NotionFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}
public struct NotionPageUnavailable: LocalizedError {
    public enum Reason: String, Sendable { case deleted, notFound }
    public let pageID: String
    public let reason: Reason
    public init(pageID: String, reason: Reason) { self.pageID = pageID; self.reason = reason }
    public var errorDescription: String? {
        reason == .deleted ? "Notion 页面已在回收站或已归档。" : "Notion 页面不存在或当前连接无法访问。"
    }
}
public struct NotionPageTarget: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var url: String
    public var meetings: NotionMeetingTarget?
    public var parentPageID: String?
    public var parentDataSourceID: String?
    public init(id: String, title: String, url: String? = nil) {
        self.id = id; self.title = title; self.url = url ?? "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: "")
    }
    public static func pageID(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: value) { return id.uuidString.lowercased() }
        let candidate: String
        if let url = URL(string: value), url.scheme != nil {
            guard url.scheme == "https", let host = url.host?.lowercased(), host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.com" || host.hasSuffix(".notion.com") || host.hasSuffix(".notion.site") else {
                throw NotionFailure("请粘贴 Notion 页面链接或页面 ID。")
            }
            candidate = url.path.removingPercentEncoding ?? url.path
        } else { candidate = value }
        let pattern = "([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9a-fA-F]{32})$"
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)), let range = Range(match.range, in: candidate) else {
            throw NotionFailure("链接中没有页面 ID；请在 Notion 用「复制链接」获取课程页面链接。")
        }
        let raw = String(candidate[range]).replacingOccurrences(of: "-", with: "")
        let chars = Array(raw)
        let normalized = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]), String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        guard let uuid = UUID(uuidString: normalized) else { throw NotionFailure("页面 ID 无效。") }
        return uuid.uuidString.lowercased()
    }
}
public struct NotionConfiguration: Codable, Sendable {
    public var automatic = false
    public var mappings: [String: NotionPageTarget] = [:]
    /// Keep Notion compact by default; the complete bilingual transcript stays local.
    public var includeTranscript = false
    private enum CodingKeys: String, CodingKey { case automatic, mappings, includeTranscript }
    public init() {}
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        mappings = try container.decodeIfPresent([String: NotionPageTarget].self, forKey: .mappings) ?? [:]
        includeTranscript = try container.decodeIfPresent(Bool.self, forKey: .includeTranscript) ?? false
    }
}
public struct NotionBlockText: Codable, Equatable, Sendable {
    public var type: String
    public var text: String
    public var richText: [NotionTextRun]?
    public var children: [NotionBlockText]?
    public init(_ type: String, _ text: String) { self.type = type; self.text = text }
    public init(_ text: String) { self.init("paragraph", text) }
    public static func toggle(_ title: String, children: [NotionBlockText]) -> Self {
        var block = Self("toggle", title); block.children = children; return block
    }
    public var shallow: Self { var copy = self; copy.children = nil; return copy }
    /// Children are uploaded separately with durable per-container checkpoints.
    public var json: [String: Any] {
        ["object": "block", "type": type, type: ["rich_text": (richText ?? [.init(text)]).map(\.json)]]
    }
}
public struct NotionRemoteBlock: Sendable {
    public var id: String
    public var content: NotionBlockText
    public var hasChildren: Bool
    public init(id: String, type: String, text: String, hasChildren: Bool = false, richText: [NotionTextRun]? = nil) {
        self.id = id; self.content = .init(type, text); self.hasChildren = hasChildren
        self.content.richText = richText
    }
}
public struct NotionArchivePayload: Codable, Equatable, Sendable {
    public var title: String
    public var startedAt: Date?
    public var blocks: [NotionBlockText]
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public init(lecture: Lecture, title: String, courseName: String, includeTranscript: Bool = false) {
        self.title = title; self.startedAt = lecture.startedAt
        blocks = [.init("\(courseName) · \(lecture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatTime(lecture.activeSeconds))")]
        if lecture.isDemo { blocks += Self.render("> 演示数据，并非真实课堂录音。") }
        if let note = lecture.combinedNote, !note.isPreview, !note.isStale(for: lecture) {
            if let bindings = note.bindings {
                blocks += NotionStudyNotes.render(bindings, source: note.source)
            } else {
                // Older notes have no structured teaching fields. Keep the source text
                // intact and folded; do not guess which paragraphs were teacher quotes.
                blocks += Self.render(lecture.notes)
                blocks.append(.toggle("旧版课件关联资料 · " + note.source.name, children: Self.render(note.markdown)))
            }
        } else { blocks += Self.render(lecture.notes) }
        if includeTranscript {
            var transcript: [NotionBlockText] = []
            for segment in lecture.orderedSegments {
                transcript.append(.init("heading_3", formatTime(segment.offset)))
                transcript += NotionStudyNotes.literal(segment.english)
                if !segment.chinese.isEmpty { transcript += NotionStudyNotes.literal(segment.chinese) }
            }
            blocks.append(.toggle("完整英文原稿与中文翻译", children: transcript))
        }
    }
    public init(title: String, blocks: [NotionBlockText]) { self.title = title; self.blocks = blocks }
    public static func render(_ markdown: String) -> [NotionBlockText] {
        NotionStudyNotes.markdown(markdown)
    }
}
public enum NotionArchivePhase: String, Codable, Sendable { case queued, syncing, failed, synced }
public struct NotionUploadCheckpoint: Codable, Sendable {
    public var uploadedCount = 0
    public var appendPending = false
    public var blockIDs: [String]?
    public init() {}
}
public struct NotionArchiveJob: Codable, Sendable {
    public var id = UUID()
    public var createdAt = Date()
    public var payload: NotionArchivePayload
    public var revisionID: String?
    public var revisionPending = false
    public var appendPending = false
    public var uploadedCount = 0
    public var nestedProgress: [String: NotionUploadCheckpoint]?
    public var fingerprint: String { payload.fingerprint }
    public var pendingTitle: String { "资料上传中 · " + id.uuidString.lowercased() }
    public var finishedTitle: String { "课堂资料 · " + createdAt.formatted(date: .abbreviated, time: .shortened) }
    public init(payload: NotionArchivePayload) { self.payload = payload }
}
public struct NotionArchiveReplacement: Codable, Sendable {
    public var parent: NotionPageTarget
    public var payload: NotionArchivePayload
    public init(parent: NotionPageTarget, payload: NotionArchivePayload) { self.parent = parent; self.payload = payload }
}
public struct NotionArchiveRecord: Codable, Sendable {
    public var lectureID: UUID
    public var parent: NotionPageTarget
    public var page: NotionPageTarget?
    public var pagePending = false
    public var phase: NotionArchivePhase = .queued
    public var job: NotionArchiveJob?
    public var fingerprint: String?
    public var syncedAt: Date?
    public var error: String?
    /// The page can be archived even when an optional meeting property cannot be written.
    /// Keep this separate from `error`: the archive itself succeeded and is safe to retry.
    public var meetingWarning: String? = nil
    public var relocation: NotionPageTarget?
    public var relocationDate: Date?
    public var movePending: Bool?
    /// Only an explicit rebuild action sets this request. Ordinary retries never recreate pages.
    public var replacement: NotionArchiveReplacement?
    public var archiveAttemptID: UUID?
    public var previousArchives: [NotionArchiveRecord]?
    public var pendingTitle: String { "课堂归档中 · " + (archiveAttemptID ?? lectureID).uuidString.lowercased() }
    public func isCurrent(for payload: NotionArchivePayload) -> Bool {
        phase == .synced && page != nil && fingerprint == payload.fingerprint && job == nil && relocation == nil && replacement == nil
    }
    public init(lectureID: UUID, parent: NotionPageTarget, payload: NotionArchivePayload) {
        self.lectureID = lectureID; self.parent = parent; job = .init(payload: payload)
    }
}

@MainActor public protocol NotionAPI {
    func page(_ id: String) async throws -> NotionPageTarget
    func children(_ id: String) async throws -> [NotionRemoteBlock]
    func createPage(parent: String, title: String) async throws -> NotionPageTarget
    func append(parent: String, blocks: [NotionBlockText], atStart: Bool) async throws -> [NotionRemoteBlock]
    func renamePage(_ id: String, title: String) async throws
    func renameToggle(_ id: String, title: String) async throws
    func validateDestination(_ parent: NotionPageTarget) async throws
    func pendingPages(parent: NotionPageTarget, title: String) async throws -> [NotionPageTarget]
    func createArchivePage(parent: NotionPageTarget, title: String, date: Date?) async throws -> NotionPageTarget
    func movePage(_ id: String, dataSourceID: String) async throws
    func fillMeetingProperties(_ id: String, target: NotionPageTarget, date: Date?) async throws -> [String]
}
public extension NotionAPI {
    func validateDestination(_ parent: NotionPageTarget) async throws {
        guard parent.meetings == nil else { throw NotionFailure("此连接不支持会议数据库。") }
        _ = try await page(parent.id)
    }
    func pendingPages(parent: NotionPageTarget, title: String) async throws -> [NotionPageTarget] {
        guard parent.meetings == nil else { throw NotionFailure("此连接不支持会议数据库。") }
        return try await children(parent.id).filter { $0.content.type == "child_page" && $0.content.text == title }.map { .init(id: $0.id, title: title) }
    }
    func createArchivePage(parent: NotionPageTarget, title: String, date: Date?) async throws -> NotionPageTarget {
        guard parent.meetings == nil else { throw NotionFailure("此连接不支持会议数据库。") }
        return try await createPage(parent: parent.id, title: title)
    }
    func movePage(_ id: String, dataSourceID: String) async throws { throw NotionFailure("此连接不支持移动页面。") }
    func fillMeetingProperties(_ id: String, target: NotionPageTarget, date: Date?) async throws -> [String] { throw NotionFailure("此连接不支持会议属性。") }
}
/// A write error with a definite rejection can safely clear the pending intent.
public struct NotionRequestFailure: LocalizedError {
    public var message: String
    public var definiteRejection: Bool
    public var statusCode: Int?
    public var errorDescription: String? { message }
    public init(_ message: String, definiteRejection: Bool, statusCode: Int? = nil) {
        self.message = message; self.definiteRejection = definiteRejection; self.statusCode = statusCode
    }
}
@MainActor public enum NotionArchiveEngine {
    private static func canFallbackFromMeeting(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let request = error as? NotionRequestFailure { return request.definiteRejection }
        return error is NotionFailure
    }
    private static func fallbackMessage(_ error: Error) -> String {
        "会议列表未能完整写入，课堂资料已保存到对应课程页；之后可重试移入会议列表：\(error.localizedDescription)"
    }
    /// Each container has its own durable intent. Never embed children in an append:
    /// separately reading them back makes interrupted nested uploads resumable.
    private static func upload(parent: String, expected: [NotionBlockText], path: String,
                               api: NotionAPI, record: inout NotionArchiveRecord,
                               save: (NotionArchiveRecord) throws -> Void,
                               progress: (String) -> Void) async throws {
        guard let job = record.job else { throw NotionFailure("资料上传状态丢失。") }
        var checkpoint = job.nestedProgress?[path] ?? .init()
        if path.isEmpty {
            // Legacy flat jobs stored progress on the job itself.
            checkpoint.uploadedCount = job.uploadedCount
            checkpoint.appendPending = job.appendPending
        }
        func persist(_ value: NotionUploadCheckpoint, in record: inout NotionArchiveRecord) throws {
            guard var current = record.job else { throw NotionFailure("资料上传状态丢失。") }
            if current.nestedProgress == nil { current.nestedProgress = [:] }
            current.nestedProgress?[path] = value
            if path.isEmpty { current.uploadedCount = value.uploadedCount; current.appendPending = value.appendPending }
            record.job = current; try save(record)
        }
        var confirmed: [NotionRemoteBlock] = []
        while true {
            try Task.checkCancellation()
            let remote = try await api.children(parent)
            guard remote.count <= expected.count,
                  remote.map(\.content) == expected.prefix(remote.count).map(\.shallow),
                  remote.enumerated().allSatisfy({ !$0.element.hasChildren || !(expected[$0.offset].children ?? []).isEmpty }) else {
                throw NotionFailure("上传中的笔记或来源已在 Notion 被修改，已停止同步以保留你的内容。")
            }
            guard remote.count >= checkpoint.uploadedCount,
                  checkpoint.blockIDs.map({ Array(remote.prefix($0.count).map(\.id)) == $0 }) ?? true else {
                throw NotionFailure("云端已上传内容发生变化，已停止同步，避免覆盖批注。")
            }
            if checkpoint.appendPending && remote.count == checkpoint.uploadedCount {
                throw NotionFailure("上一批上传结果尚未确认，请稍后重试；不会盲目重复追加。")
            }
            checkpoint.uploadedCount = remote.count; checkpoint.appendPending = false
            checkpoint.blockIDs = remote.map(\.id); try persist(checkpoint, in: &record)
            if remote.count == expected.count { confirmed = remote; break }
            let batch = Array(expected.dropFirst(remote.count).prefix(40).map(\.shallow))
            progress(path.isEmpty ? "上传笔记 \(remote.count)/\(expected.count)…" : "上传折叠来源…")
            checkpoint.appendPending = true; try persist(checkpoint, in: &record)
            do { _ = try await api.append(parent: parent, blocks: batch, atStart: false) }
            catch {
                if let error = error as? NotionRequestFailure, error.definiteRejection {
                    checkpoint.appendPending = false; try persist(checkpoint, in: &record)
                }
                throw error
            }
            // Keep the intent until readback, even when the append response succeeded.
        }
        for (index, block) in expected.enumerated() {
            if let children = block.children, !children.isEmpty {
                try await upload(parent: confirmed[index].id, expected: children, path: path + "/\(index)",
                                 api: api, record: &record, save: save, progress: progress)
            }
        }
    }
    public static func sync(_ original: NotionArchiveRecord, api: NotionAPI,
                            save: (NotionArchiveRecord) throws -> Void,
                            progress: (String) -> Void) async throws -> NotionArchiveRecord {
        var record = original
        record.phase = .syncing; record.error = nil; try save(record)
        do {
            try Task.checkCancellation()
            if let replacement = record.replacement {
                progress("核对原归档页面与课程位置…")
                guard let oldPage = record.page else { throw NotionFailure("原页面创建结果尚未确认，请先重试同步核对云端。") }
                do {
                    _ = try await api.page(oldPage.id)
                    record.replacement = nil
                    throw NotionFailure("原归档页面仍可访问，已保留原页；请使用更新归档。")
                } catch let unavailable as NotionPageUnavailable where unavailable.pageID == oldPage.id {
                    // A 404 can mean deletion OR a page-specific permission change. Only
                    // the user's explicit rebuild request permits a new page in this case.
                }
                var destination = replacement.parent
                var warning: String?
                do { try await api.validateDestination(destination) }
                catch {
                    guard destination.meetings != nil, canFallbackFromMeeting(error) else { throw error }
                    warning = fallbackMessage(error); destination.meetings = nil
                    try await api.validateDestination(destination)
                }
                var previous = record
                previous.replacement = nil; previous.previousArchives = nil
                previous.phase = original.phase; previous.error = original.error
                var fresh = NotionArchiveRecord(lectureID: record.lectureID, parent: destination, payload: replacement.payload)
                fresh.archiveAttemptID = UUID()
                fresh.previousArchives = (record.previousArchives ?? []) + [previous]
                fresh.meetingWarning = warning; fresh.phase = .syncing
                // Save the reset and its history before making any remote write. Once
                // saved, every retry uses this same attempt and the normal durable intents.
                try save(fresh)
                record = fresh
            }
            if let page = record.page { _ = try await api.page(page.id) }
            if let destination = record.relocation {
                guard record.job == nil, let page = record.page, let meetings = destination.meetings,
                      destination.id == record.parent.id else { throw NotionFailure("请先完成原归档，再移入该课程的会议列表。") }
                do { try await api.validateDestination(destination) }
                catch {
                    guard canFallbackFromMeeting(error) else { throw error }
                    record.meetingWarning = fallbackMessage(error)
                    record.relocation = nil; record.relocationDate = nil; record.movePending = nil
                    record.phase = .synced; record.error = nil; try save(record)
                    return record
                }
                var remote = try await api.page(page.id)
                if remote.parentDataSourceID != meetings.dataSourceID {
                    guard remote.parentPageID == record.parent.id, record.parent.meetings == nil else {
                        throw NotionFailure("页面已被移到其他位置，为保留你的整理，已停止自动移动。")
                    }
                    guard record.movePending != true else { throw NotionFailure("上次移动结果尚未确认，请稍后重试核对；不会重复移动。") }
                    record.movePending = true; try save(record)
                    do { try await api.movePage(page.id, dataSourceID: meetings.dataSourceID) }
                    catch {
                        if let e = error as? NotionRequestFailure, e.definiteRejection { record.movePending = false }
                        throw error
                    }
                    remote = try await api.page(page.id)
                    guard remote.parentDataSourceID == meetings.dataSourceID else { throw NotionFailure("会议位置尚未回读确认，请稍后重试。") }
                }
                progress("尽量填写会议的课程与日期…")
                do {
                    let warnings = try await api.fillMeetingProperties(page.id, target: destination, date: record.relocationDate)
                    record.meetingWarning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
                } catch {
                    // The page is already confirmed in the meeting data source. A missing
                    // relation/date/type must not move it back to the course page or lose the
                    // transcript. Keep the failure visible and let the user repair the field.
                    record.meetingWarning = "课堂已进入会议列表，但部分字段未能自动关联：" + error.localizedDescription
                }
                record.parent = destination; record.page = try await api.page(page.id)
                record.relocation = nil; record.relocationDate = nil; record.movePending = nil
                try save(record)
            }
            guard var job = record.job else { record.phase = .synced; record.error = nil; try save(record); return record }
            if record.parent.meetings != nil {
                do { try await api.validateDestination(record.parent) }
                catch {
                    guard canFallbackFromMeeting(error) else { throw error }
                    record.meetingWarning = fallbackMessage(error)
                    record.parent.meetings = nil
                    try save(record)
                    try await api.validateDestination(record.parent)
                }
            } else {
                try await api.validateDestination(record.parent)
            }
            if record.page == nil {
                progress("准备课堂页面…")
                let candidates = try await api.pendingPages(parent: record.parent, title: record.pendingTitle)
                guard candidates.count <= 1 else { throw NotionFailure("找到多个待归档页面，请先在 Notion 核对，未继续写入。") }
                if let found = candidates.first {
                    record.page = try await api.page(found.id); record.pagePending = false; try save(record)
                } else {
                    guard !record.pagePending else { throw NotionFailure("上次创建页面的结果尚未确认。请稍后重试，系统会先核对云端，避免重复建页。") }
                    record.pagePending = true; try save(record)
                    do { record.page = try await api.createArchivePage(parent: record.parent, title: record.pendingTitle, date: job.payload.startedAt) }
                    catch {
                        if let e = error as? NotionRequestFailure, e.definiteRejection { record.pagePending = false }
                        guard record.parent.meetings != nil, canFallbackFromMeeting(error) else { throw error }
                        record.meetingWarning = fallbackMessage(error)
                        record.parent.meetings = nil; record.pagePending = false
                        try save(record)
                        try await api.validateDestination(record.parent)
                        record.page = try await api.createArchivePage(parent: record.parent, title: record.pendingTitle, date: job.payload.startedAt)
                    }
                    record.pagePending = false; try save(record)
                }
            }
            guard let page = record.page else { throw NotionFailure("课堂页面未创建。") }
            _ = try await api.page(page.id)
            if record.parent.meetings != nil {
                progress("尽量填写会议的课程与日期…")
                do {
                    let warnings = try await api.fillMeetingProperties(page.id, target: record.parent, date: job.payload.startedAt)
                    record.meetingWarning = warnings.isEmpty ? nil : warnings.joined(separator: "；")
                    record.job = job; try save(record)
                } catch {
                    record.meetingWarning = "课堂已进入会议列表，但部分字段未能自动关联：" + error.localizedDescription
                    record.job = job; try save(record)
                }
            }
            if job.revisionID == nil {
                let matches = try await api.children(page.id).filter { $0.content.type == "toggle" && $0.content.text == job.pendingTitle }
                guard matches.count <= 1 else { throw NotionFailure("找到多个待上传资料区，请核对 Notion 页面后重试。") }
                if let match = matches.first { job.revisionID = match.id; job.revisionPending = false }
                else {
                    guard !job.revisionPending else { throw NotionFailure("资料区创建结果尚未确认，请稍后重试核对云端。") }
                    job.revisionPending = true; record.job = job; try save(record)
                    do {
                        let added = try await api.append(parent: page.id, blocks: [.init("toggle", job.pendingTitle)], atStart: true)
                        // Some API responses include existing siblings too. Identify our
                        // unique revision rather than assuming exactly one returned block.
                        var candidates = added.filter { $0.content.type == "toggle" && $0.content.text == job.pendingTitle }
                        if candidates.isEmpty {
                            candidates = try await api.children(page.id).filter { $0.content.type == "toggle" && $0.content.text == job.pendingTitle }
                        }
                        guard candidates.count == 1, let created = candidates.first else { throw NotionFailure("资料区响应不完整，请重试核对。") }
                        job.revisionID = created.id
                    } catch {
                        if let e = error as? NotionRequestFailure, e.definiteRejection { job.revisionPending = false }
                        record.job = job; throw error
                    }
                    job.revisionPending = false
                }
                record.job = job; try save(record)
            }
            guard let revision = job.revisionID else { throw NotionFailure("资料区未创建。") }
            try await upload(parent: revision, expected: job.payload.blocks, path: "", api: api,
                             record: &record, save: save, progress: progress)
            // Recursive uploads persist their own checkpoints; keep the latest snapshot.
            guard let completedJob = record.job else { throw NotionFailure("资料上传状态丢失。") }
            job = completedJob
            try await api.renameToggle(revision, title: job.finishedTitle)
            try await api.renamePage(page.id, title: job.payload.title)
            record.page = try await api.page(page.id)
            record.fingerprint = job.fingerprint; record.syncedAt = Date(); record.job = nil
            record.phase = .synced; record.error = nil; try save(record)
            return record
        } catch {
            record.phase = .failed
            if let unavailable = error as? NotionPageUnavailable, unavailable.pageID == record.page?.id {
                record.error = unavailable.reason == .deleted
                    ? "原归档页面已删除。可点击「重建页面」上传最新笔记。"
                    : "原归档页面不存在或无法访问；若已手动删除，可点击「重建页面」。"
            } else if let unavailable = error as? NotionPageUnavailable, unavailable.pageID == (record.replacement?.parent.id ?? record.parent.id) {
                record.error = "课程目标页面不存在或未授权，请到设置 → Notion 检查课程绑定与页面权限。"
            } else {
                record.error = error is CancellationError ? "同步已暂停，重新打开后可重试。" : error.localizedDescription
            }
            try save(record)
            throw error
        }
    }
}
extension LectureStore {
    public func loadNotionArchive(_ id: UUID) throws -> NotionArchiveRecord? {
        let url = directory(id).appendingPathComponent("notion-archive.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(NotionArchiveRecord.self, from: Data(contentsOf: url))
        guard record.lectureID == id else { throw NotionFailure("Notion 同步记录与课堂不匹配，原文件已保留。") }
        return record
    }
    public func saveNotionArchive(_ record: NotionArchiveRecord) throws {
        let folder = directory(record.lectureID)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("lecture.json").path) else { throw NotionFailure("课堂已移除，同步已停止。") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: folder.appendingPathComponent("notion-archive.json"), options: .atomic)
    }
}
