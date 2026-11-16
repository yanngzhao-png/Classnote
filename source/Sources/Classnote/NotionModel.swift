import AppKit
import ClassnoteCore

extension AppModel {
    var notionConfiguration: NotionConfiguration { settings.notion ?? .init() }
    func openNotionPreferences() { settingsSection = 3; showSettings = true }
    func setNotionAutomatic(_ value: Bool) {
        var config = notionConfiguration; config.automatic = value; settings.notion = config; settings.save()
        if !value { status = "已关闭后续自动归档，已开始的同步仍会完成" }
    }
    func setNotionIncludeTranscript(_ value: Bool) {
        var config = notionConfiguration
        config.includeTranscript = value
        settings.notion = config
        settings.save()
        status = value ? "Notion 将包含完整英中原稿" : "Notion 将只同步总结与课件关联笔记"
    }
    func bindNotionPage(_ page: NotionPageTarget, to course: Course) {
        var config = notionConfiguration; config.mappings[course.id.uuidString] = page
        settings.notion = config; settings.save(); status = "已绑定「\(course.name)」的 Notion 页面"
    }
    func unbindNotionPage(_ course: Course) {
        var config = notionConfiguration; config.mappings.removeValue(forKey: course.id.uuidString)
        settings.notion = config; settings.save()
    }
    func notionTarget(for lecture: Lecture) -> NotionPageTarget? {
        notionArchives[lecture.id]?.parent ?? notionConfiguration.mappings[Course.groupID(for: lecture, courses: courses).uuidString]
    }
    func notionPayload(_ lecture: Lecture) -> NotionArchivePayload {
        let group = courseGroups.first { $0.id == Course.groupID(for: lecture, courses: courses) }
        return .init(lecture: lecture, title: lectureTitle(lecture), courseName: group?.name ?? "未分类课堂", includeTranscript: notionConfiguration.includeTranscript)
    }
    func notionReadiness(_ lecture: Lecture) -> String? {
        if notionUnavailable.contains(lecture.id) { return "同步记录无法读取，原文件已保留。" }
        if lecture.state != .ended || activeID == lecture.id { return "结束课堂并完成整理后可同步。" }
        if busyNotes.contains(lecture.id) || busyCombinedNotes.contains(lecture.id) || retrying.contains(lecture.id) || importingCourseware.contains(lecture.id) { return "等待课堂资料处理完成。" }
        if lecture.unfinishedCount > 0 || lecture.segments.contains(where: { $0.state != .translated }) { return "请先完成原稿和翻译，未完成段落可重试。" }
        if lecture.courseware != nil {
            guard let note = lecture.combinedNote, !note.isPreview, !note.isStale(for: lecture), lecture.combinedNoteError == nil else { return "请先生成最新的课件关联笔记。" }
        } else if lecture.notes.isEmpty || lecture.noteError != nil { return "请先生成课堂笔记。" }
        if notionTarget(for: lecture) == nil { return "先在设置 → Notion 绑定这门课的页面。" }
        return nil
    }
    func loadNotionArchives() {
        guard let store else { return }
        for lecture in lectures {
            do {
                if let record = try store.loadNotionArchive(lecture.id) {
                    notionArchives[lecture.id] = record
                    // A failed request is never retried silently; queued/interrupted work can resume.
                    if notionConfiguration.automatic, [.queued, .syncing].contains(record.phase), (record.job != nil || record.relocation != nil || record.replacement != nil), !lecture.isDemo {
                        notionQueue.append(lecture.id)
                    }
                }
            } catch { notionUnavailable.insert(lecture.id) }
        }
        if !notionQueue.isEmpty { startNotionWorker() }
    }
    func saveNotionRecord(_ record: NotionArchiveRecord) throws {
        guard let store else { throw NotionFailure("本地存储不可用，同步已停止。") }
        try store.saveNotionArchive(record); notionArchives[record.lectureID] = record
    }
    func enqueueNotionIfReady(_ id: UUID) {
        guard notionConfiguration.automatic, let lecture = lectures.first(where: { $0.id == id }), !lecture.isDemo,
              notionReadiness(lecture) == nil, notionArchives[id]?.phase != .failed else { return }
        queueNotion(id)
    }
    func queueNotion(_ id: UUID) {
        guard notionSyncingID != id, !notionQueue.contains(id), let lecture = lectures.first(where: { $0.id == id }), !notionUnavailable.contains(id) else { return }
        do {
            var record = notionArchives[id]
            // An interrupted upload resumes its saved snapshot before any newer revision.
            if record?.job == nil && record?.relocation == nil && record?.replacement == nil {
                if let reason = notionReadiness(lecture) { throw NotionFailure(reason) }
                let payload = notionPayload(lecture)
                if record?.isCurrent(for: payload) == true { status = "Notion 已是最新版本"; return }
                guard let target = notionTarget(for: lecture) else { throw NotionFailure("请先绑定课程页面。") }
                if record == nil { record = .init(lectureID: id, parent: target, payload: payload) }
                else { record?.job = .init(payload: payload) }
            }
            guard var record else { return }
            record.phase = .queued; record.error = nil; try saveNotionRecord(record)
            notionQueue.append(id); startNotionWorker()
        } catch { self.error = error.localizedDescription }
    }
    func rebuildNotionArchive(_ id: UUID) {
        guard notionSyncingID != id, !notionQueue.contains(id),
              let lecture = lectures.first(where: { $0.id == id }),
              var record = notionArchives[id], record.page != nil else { return }
        do {
            if let reason = notionReadiness(lecture) { throw NotionFailure(reason) }
            let target = notionConfiguration.mappings[Course.groupID(for: lecture, courses: courses).uuidString] ?? record.parent
            record.replacement = .init(parent: target, payload: notionPayload(lecture))
            record.phase = .queued; record.error = nil
            try saveNotionRecord(record)
            notionQueue.append(id); startNotionWorker()
        } catch { self.error = error.localizedDescription }
    }
    func notionMeetingMigrationTarget(_ lecture: Lecture) -> NotionPageTarget? {
        guard let record = notionArchives[lecture.id], record.page != nil, record.job == nil, record.replacement == nil,
              record.parent.meetings == nil,
              let mapped = notionConfiguration.mappings[Course.groupID(for: lecture, courses: courses).uuidString],
              mapped.id == record.parent.id, mapped.meetings != nil else { return nil }
        return mapped
    }
    func moveNotionArchiveToMeetings(_ lecture: Lecture) {
        guard notionSyncingID != lecture.id, !notionQueue.contains(lecture.id),
              var record = notionArchives[lecture.id], let destination = notionMeetingMigrationTarget(lecture) else { return }
        do {
            if record.relocation == nil { record.relocation = destination; record.relocationDate = lecture.startedAt }
            record.phase = .queued; record.error = nil; try saveNotionRecord(record)
            notionQueue.append(lecture.id); startNotionWorker()
        } catch { self.error = error.localizedDescription }
    }
    private func startNotionWorker() {
        guard notionWorker == nil else { return }
        notionWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.notionWorker = nil; self.notionSyncingID = nil; self.notionProgress = "" }
            while !self.notionQueue.isEmpty && !Task.isCancelled {
                let id = self.notionQueue.removeFirst()
                guard self.lectures.contains(where: { $0.id == id }), let record = self.notionArchives[id] else { continue }
                self.notionSyncingID = id; self.notionProgress = "连接 Notion…"
                do {
                    let token = try Keychain.readNotion()
                    guard !token.isEmpty else { throw NotionFailure("请先在设置 → Notion 保存连接凭证。") }
                    let result = try await NotionArchiveEngine.sync(record, api: NotionClient(token: token), save: { try self.saveNotionRecord($0) }, progress: { self.notionProgress = $0 })
                    self.notionArchives[id] = result; self.status = "已归档到 Notion"
                    self.notionSyncingID = nil
                    self.enqueueNotionIfReady(id)
                } catch {
                    var failed = self.notionArchives[id] ?? record
                    if failed.phase != .failed || failed.error == nil {
                        failed.error = error is CancellationError ? "同步已暂停，可重试。" : error.localizedDescription
                    }
                    failed.phase = .failed
                    do { try self.saveNotionRecord(failed) } catch { self.error = "Notion 同步状态保存失败，原稿仍在本机：\(error.localizedDescription)" }
                    self.status = "Notion 未同步完成 · 本地资料保留"
                    self.notionSyncingID = nil
                }
            }
        }
    }
    func openNotionPage(_ page: NotionPageTarget) {
        if let url = URL(string: page.url), url.scheme == "https", let host = url.host,
           host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.com" || host.hasSuffix(".notion.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
