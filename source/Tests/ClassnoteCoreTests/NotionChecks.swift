import Foundation
import ClassnoteCore

@MainActor private final class FakeNotion: NotionAPI {
    let parent = NotionPageTarget(id: UUID().uuidString.lowercased(), title: "Existing course")
    var pages: [String: NotionPageTarget] = [:]
    var lists: [String: [NotionRemoteBlock]] = [:]
    var moveCalls = 0
    var fillCalls = 0
    var createCalls = 0
    var appendCalls = 0
    var lost: String?
    var rejectNext = false
    var hideNextRead = false
    var returnAllSiblings = false
    var hideSourceRead = false
    var sourceReads = 0
    var pageErrors: [String: Error] = [:]
    init() { pages[parent.id] = parent }
    func page(_ id: String) async throws -> NotionPageTarget {
        if let error = pageErrors[id] { throw error }
        guard let p = pages[id] else { throw NotionPageUnavailable(pageID: id, reason: .notFound) }; return p
    }
    func children(_ id: String) async throws -> [NotionRemoteBlock] {
        if hideNextRead, lists[id]?.first?.content.type == "paragraph" { hideNextRead = false; return [] }
        if hideSourceRead, lists[id]?.first?.content.text == "Source 0" { hideSourceRead = false; return [] }
        if lists[id]?.first?.content.text == "Source 0" { sourceReads += 1 }
        return (lists[id] ?? []).map { value in
            var block = value; block.hasChildren = block.hasChildren || !(lists[block.id] ?? []).isEmpty
            return block
        }
    }
    func createPage(parent: String, title: String) async throws -> NotionPageTarget {
        createCalls += 1
        var p = NotionPageTarget(id: UUID().uuidString.lowercased(), title: title); p.parentPageID = parent
        pages[p.id] = p; lists[parent, default: []].append(.init(id: p.id, type: "child_page", text: title))
        if lost == "page" { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
        return p
    }
    func validateDestination(_ parent: NotionPageTarget) async throws { _ = try await page(parent.id) }
    func pendingPages(parent: NotionPageTarget, title: String) async throws -> [NotionPageTarget] {
        if let meetings = parent.meetings { return pages.values.filter { $0.parentDataSourceID == meetings.dataSourceID && $0.title == title } }
        return pages.values.filter { $0.parentPageID == parent.id && $0.title == title }
    }
    func createArchivePage(parent: NotionPageTarget, title: String, date: Date?) async throws -> NotionPageTarget {
        guard let meetings = parent.meetings else { return try await createPage(parent: parent.id, title: title) }
        createCalls += 1
        var p = NotionPageTarget(id: UUID().uuidString.lowercased(), title: title); p.parentDataSourceID = meetings.dataSourceID
        pages[p.id] = p
        if lost == "page" { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
        return p
    }
    func movePage(_ id: String, dataSourceID: String) async throws {
        moveCalls += 1; pages[id]?.parentPageID = nil; pages[id]?.parentDataSourceID = dataSourceID
        if lost == "move" { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
    }
    func fillMeetingProperties(_ id: String, target: NotionPageTarget, date: Date?) async throws -> [String] {
        fillCalls += 1
        if lost == "properties" { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
        return []
    }
    func append(parent: String, blocks: [NotionBlockText], atStart: Bool) async throws -> [NotionRemoteBlock] {
        appendCalls += 1
        if rejectNext { rejectNext = false; throw NotionRequestFailure("rate limited", definiteRejection: true) }
        let values = blocks.map { NotionRemoteBlock(id: UUID().uuidString.lowercased(), type: $0.type, text: $0.text, richText: $0.richText) }
        if atStart { lists[parent, default: []].insert(contentsOf: values, at: 0) } else { lists[parent, default: []].append(contentsOf: values) }
        if lost == "source", blocks.first?.text == "Source 0" { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
        if (lost == "toggle" && atStart) || (lost == "batch" && !atStart) { lost = nil; throw NotionRequestFailure("response lost", definiteRejection: false) }
        return returnAllSiblings ? lists[parent, default: []] : values
    }
    func renamePage(_ id: String, title: String) async throws { pages[id]?.title = title }
    func renameToggle(_ id: String, title: String) async throws {
        for key in Array(lists.keys) { if let index = lists[key]?.firstIndex(where: { $0.id == id }) { lists[key]?[index].content.text = title } }
    }
}
private func flattened(_ blocks: [NotionBlockText]) -> [NotionBlockText] {
    blocks.flatMap { [$0] + flattened($0.children ?? []) }
}
private final class NotionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], [String: Any]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, body) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
extension ClassnoteCoreTests {
    @MainActor func testNotionNestedSourcesResumeAndReadBack() async throws {
        for failure in ["none", "lost", "delayed"] {
            let api = FakeNotion(); api.returnAllSiblings = true
            api.lost = failure == "lost" ? "source" : nil
            api.hideSourceRead = failure == "delayed"
            let evidence = (0..<85).map { NotionBlockText("Source \($0)") }
            let payload = NotionArchivePayload(title: "Date", blocks: NotionStudyNotes.markdown("## 知识点\n- **整理笔记**") + [
                .toggle("原话与来源", children: evidence + [.toggle("更多来源", children: [.init("Deep source")])])
            ])
            var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: payload)
            if failure != "none" {
                do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
                checkEqual(saved.phase, .failed)
                checkTrue(saved.job!.nestedProgress!["/2"]!.appendPending)
                saved = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONEncoder().encode(saved))
            }
            let result = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
            checkEqual(result.phase, .synced); checkEqual(result.fingerprint, payload.fingerprint)
            let revision = api.lists[result.page!.id]!.first!.id
            let body = api.lists[revision]!
            checkEqual(body.map(\.content), payload.blocks.map(\.shallow))
            let sources = api.lists[body[2].id]!
            checkEqual(sources.count, 86); checkEqual(sources.prefix(85).map(\.content), evidence)
            checkEqual(api.lists[sources.last!.id]?.first?.content.text, "Deep source")
            checkTrue(api.sourceReads > 0)
            checkEqual(api.appendCalls, 6) // revision + body + 3 source batches + deep source
            checkEqual(api.createCalls, 1)
        }
    }
    @MainActor func testNotionNestedEditsAndReplacedContainersArePreserved() async throws {
        for change in ["quote", "style", "id", "extra-child"] {
            let api = FakeNotion(); api.lost = "source"
            let payload = NotionArchivePayload(title: "Date", blocks: [
                .init("Visible notes"), .toggle("原话与来源", children: [.init("Source 0"), .init("Source 1")])
            ])
            var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: payload)
            do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
            let revision = saved.job!.revisionID!, source = api.lists[revision]![1].id
            switch change {
            case "quote": api.lists[source]![0].content.text = "My annotation"
            case "style": api.lists[revision]![0].content.richText = [.init("Visible notes", bold: true)]
            case "id": api.lists[revision]![1].id = UUID().uuidString
            default: api.lists[revision]![0].hasChildren = true
            }
            let calls = api.appendCalls
            do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
            checkEqual(saved.phase, .failed); checkEqual(api.appendCalls, calls)
            if change == "quote" { checkEqual(api.lists[source]![0].content.text, "My annotation") }
        }
    }
    @MainActor func testNotionNativeRichTextHTTPReadback() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotionURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel(); NotionURLProtocol.handler = nil }
        let formatted = NotionStudyNotes.formatted("**理论**与 `concept`").first!
        let id = UUID().uuidString.lowercased()
        NotionURLProtocol.handler = { _ in
            var json = formatted.json; json["id"] = id; json["has_children"] = false
            return (200, [:], ["results": [json], "has_more": false])
        }
        let api = NotionClient(token: "fixture-token", session: session, pause: { _ in })
        let remote = try await api.children(id)
        checkEqual(remote.first?.content, formatted)
        let toggle = NotionBlockText.toggle("来源", children: [formatted])
        let json = toggle.json["toggle"] as! [String: Any]
        checkNil(json["children"]) // nested appends need their own durable checkpoints
        let decoded = try JSONDecoder().decode(NotionArchivePayload.self, from: JSONEncoder().encode(NotionArchivePayload(title: "Date", blocks: [toggle])))
        checkEqual(decoded.blocks[0].children, [formatted])
    }
    @MainActor func testNotionDeletedArchiveRebuildUsesLatestNotesAndDestination() async throws {
        for reason in [NotionPageUnavailable.Reason.deleted, .notFound] {
            let api = FakeNotion()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let store = try LectureStore(root: root)
            let lecture = fixtureLecture(); try store.save(lecture)
            let localBytes = try Data(contentsOf: store.directory(lecture.id).appendingPathComponent("lecture.json"))
            let oldPayload = NotionArchivePayload(title: "Old", blocks: [.init("Old transcript")])
            var record = NotionArchiveRecord(lectureID: lecture.id, parent: api.parent, payload: oldPayload)
            let save: (NotionArchiveRecord) throws -> Void = { try store.saveNotionArchive($0); record = $0 }
            record = try await NotionArchiveEngine.sync(record, api: api, save: save, progress: { _ in })
            let oldPage = record.page!.id
            let oldRevision = api.lists[oldPage]!.first!.id
            api.pageErrors[oldPage] = NotionPageUnavailable(pageID: oldPage, reason: reason)
            record.job = .init(payload: .init(title: "Stale interrupted version", blocks: [.init("Stale body")]))
            do { _ = try await NotionArchiveEngine.sync(record, api: api, save: save, progress: { _ in }); checkTrue(false) } catch {}
            checkEqual(api.createCalls, 1); checkEqual(record.phase, .failed)
            checkTrue(record.error?.contains("重建页面") == true)
            var destination = api.parent
            destination.meetings = .init(dataSourceID: UUID().uuidString.lowercased(), title: "Meetings", titleProperty: "title", courseProperty: nil, dateProperty: nil)
            let latest = NotionArchivePayload(title: "New date", blocks: [.init("AI summary only")])
            record.replacement = .init(parent: destination, payload: latest)
            try store.saveNotionArchive(record)
            record = try store.loadNotionArchive(lecture.id)!
            let rebuilt = try await NotionArchiveEngine.sync(record, api: api, save: save, progress: { _ in })
            checkTrue(rebuilt.page?.id != oldPage); checkEqual(api.createCalls, 2)
            checkEqual(rebuilt.page?.parentDataSourceID, destination.meetings?.dataSourceID)
            checkEqual(rebuilt.fingerprint, latest.fingerprint); checkTrue(rebuilt.isCurrent(for: latest))
            checkEqual(rebuilt.previousArchives?.count, 1)
            checkEqual(rebuilt.previousArchives?.first?.page?.id, oldPage)
            checkEqual(rebuilt.previousArchives?.first?.job?.payload.title, "Stale interrupted version")
            let revision = api.lists[rebuilt.page!.id]!.first!.id
            checkEqual(api.lists[revision]?.map(\.content), latest.blocks)
            checkEqual(api.lists[oldRevision]?.map(\.content), oldPayload.blocks)
            checkEqual(try Data(contentsOf: store.directory(lecture.id).appendingPathComponent("lecture.json")), localBytes)
        }
    }
    @MainActor func testNotionRebuildRejectsHealthyDeniedAndUnknownPages() async throws {
        for failure in ["healthy", "forbidden", "offline", "parent", "save"] {
            let api = FakeNotion()
            let payload = NotionArchivePayload(title: "Date", blocks: [.init("Body")])
            var record = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: payload)
            record = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in })
            let oldPage = record.page!.id
            switch failure {
            case "healthy": break
            case "forbidden": api.pageErrors[oldPage] = NotionRequestFailure("forbidden", definiteRejection: true, statusCode: 403)
            case "offline": api.pageErrors[oldPage] = NotionRequestFailure("offline", definiteRejection: true)
            default:
                api.pageErrors[oldPage] = NotionPageUnavailable(pageID: oldPage, reason: .deleted)
                if failure == "parent" { api.pages.removeValue(forKey: api.parent.id) }
            }
            record.replacement = .init(parent: api.parent, payload: payload)
            let writes = api.appendCalls
            do {
                _ = try await NotionArchiveEngine.sync(record, api: api, save: {
                    if failure == "save", $0.archiveAttemptID != nil { throw NotionFailure("disk unavailable") }
                    record = $0
                }, progress: { _ in })
                checkTrue(false)
            } catch {}
            checkEqual(api.createCalls, 1); checkEqual(api.appendCalls, writes)
            checkEqual(record.page?.id, oldPage); checkNil(record.previousArchives)
            checkFalse(record.isCurrent(for: payload))
            if failure == "healthy" { checkNil(record.replacement) }
            if failure == "parent" { checkTrue(record.error?.contains("课程目标") == true) }
        }
        let api = FakeNotion()
        var pending = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Date", blocks: []))
        pending.pagePending = true
        pending.replacement = .init(parent: api.parent, payload: .init(title: "Date", blocks: []))
        do { _ = try await NotionArchiveEngine.sync(pending, api: api, save: { pending = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        checkTrue(pending.pagePending); checkEqual(api.createCalls, 0)
    }
    @MainActor func testNotionRebuildLostResponsesResumeSameAttempt() async throws {
        for stage in ["page", "toggle", "batch"] {
            let api = FakeNotion()
            var record = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Old", blocks: [.init("Original")]))
            record = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in })
            let oldPage = record.page!.id
            // The old pending title may remain in a stale listing. Rebuild must use a new identity.
            api.pages[oldPage]?.title = record.pendingTitle
            api.pageErrors[oldPage] = NotionPageUnavailable(pageID: oldPage, reason: .deleted)
            let latest = NotionArchivePayload(title: "Rebuilt", blocks: (0..<85).map { .init("New \($0)") })
            record.replacement = .init(parent: api.parent, payload: latest)
            api.lost = stage
            do { _ = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in }); checkTrue(false) } catch {}
            let attempt = record.archiveAttemptID
            checkTrue(attempt != nil); checkNil(record.replacement)
            record = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONEncoder().encode(record))
            let result = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in })
            checkEqual(api.createCalls, 2); checkEqual(result.archiveAttemptID, attempt)
            checkEqual(result.previousArchives?.count, 1); checkEqual(result.phase, .synced)
            let revisions = api.lists[result.page!.id]!
            checkEqual(revisions.count, 1); checkEqual(api.lists[revisions[0].id]?.map(\.content), latest.blocks)
        }
    }
    @MainActor func testNotionPageUnavailableHTTPClassification() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); NotionURLProtocol.handler = nil }
        let client = NotionClient(token: "fixture-token", session: session, pause: { _ in })
        let id = UUID().uuidString.lowercased()
        NotionURLProtocol.handler = { _ in (404, [:], ["code": "object_not_found"]) }
        do { _ = try await client.page(id); checkTrue(false) }
        catch { checkEqual((error as? NotionPageUnavailable)?.reason, .notFound); checkEqual((error as? NotionPageUnavailable)?.pageID, id) }
        do { _ = try await client.children(id); checkTrue(false) }
        catch { checkNil(error as? NotionPageUnavailable); checkEqual((error as? NotionRequestFailure)?.statusCode, 404) }
        for field in ["in_trash", "archived", "is_archived"] {
            NotionURLProtocol.handler = { _ in (200, [:], ["object": "page", "id": id, field: true]) }
            do { _ = try await client.page(id); checkTrue(false) }
            catch { checkEqual((error as? NotionPageUnavailable)?.reason, .deleted) }
        }
        for status in [401, 403, 429, 503] {
            NotionURLProtocol.handler = { _ in (status, [:], ["code": "fixture_error"]) }
            do { _ = try await client.page(id); checkTrue(false) }
            catch { checkNil(error as? NotionPageUnavailable); checkEqual((error as? NotionRequestFailure)?.statusCode, status) }
        }
    }
    func testNotionLegacyRecordAndFailedCurrentState() throws {
        let payload = NotionArchivePayload(title: "Date", blocks: [.init("Body")])
        var record = NotionArchiveRecord(lectureID: UUID(), parent: .init(id: UUID().uuidString, title: "Course"), payload: payload)
        record.page = .init(id: UUID().uuidString, title: "Date")
        record.phase = .synced; record.fingerprint = payload.fingerprint; record.job = nil
        let data = try JSONEncoder().encode(record)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["replacement", "archiveAttemptID", "previousArchives"] { json.removeValue(forKey: key) }
        record = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONSerialization.data(withJSONObject: json))
        checkTrue(record.isCurrent(for: payload)); checkNil(record.archiveAttemptID); checkNil(record.previousArchives)
        checkEqual(record.pendingTitle, "课堂归档中 · " + record.lectureID.uuidString.lowercased())
        record.phase = .failed
        checkFalse(record.isCurrent(for: payload))
    }
    func testNotionPageLinksAndStableCourseMappings() throws {
        let raw = "12345678123442348234123456789abc"
        let normalized = "12345678-1234-4234-8234-123456789abc"
        for input in [raw,normalized,"https://www.notion.so/Course-"+raw+"?pvs=4#unrelated", "https://app.notion.com/p/"+raw] {
            checkEqual(try NotionPageTarget.pageID(input), normalized)
        }
        for input in ["https://evil.test/"+raw,"https://notion.so.evil.test/"+raw,"file:///"+raw,"https://www.notion.so/course"] {
            do { _ = try NotionPageTarget.pageID(input); checkTrue(false) } catch {}
        }
        var config = NotionConfiguration(); let course = Course(name: "Economics")
        config.mappings[course.id.uuidString] = .init(id: normalized, title: "Existing page")
        let loaded = try JSONDecoder().decode(NotionConfiguration.self, from: JSONEncoder().encode(config))
        var renamed = course; renamed.name = "Renamed"
        checkEqual(loaded.mappings[renamed.id.uuidString]?.id, normalized); checkFalse(loaded.automatic)
        checkFalse(loaded.includeTranscript)
        let oldJSON = "{\"automatic\":true,\"mappings\":{}}".data(using: .utf8)!
        let oldConfig = try JSONDecoder().decode(NotionConfiguration.self, from: oldJSON)
        checkTrue(oldConfig.automatic); checkFalse(oldConfig.includeTranscript)
    }
    func testNotionPayloadKeepsSourcesAndBoundsUnicode() throws {
        var lecture = fixtureLecture(); lecture.notes = "## 中文笔记\n- **概念** [00:12]"
        let material = Courseware(name: "Lecture.pdf", byteCount: 1, pages: (1...3).map { .init(number: $0, text: "Source") })
        lecture.courseware = material
        let source = material.source
        lecture.combinedNote = CombinedNote(markdown: "## 关联\n课件 Lecture.pdf p.2\n原稿 [00:12] Opportunity cost", source: source, transcript: lecture.transcript)
        let payload = NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics", includeTranscript: true)
        let text = flattened(payload.blocks).map(\.text).joined(separator: "\n")
        checkTrue(text.contains(lecture.segments[0].english)); checkTrue(text.contains(lecture.segments[0].chinese)); checkTrue(text.contains("Lecture.pdf p.2")); checkTrue(text.contains("原稿 [00:12]"))
        let long = String(repeating: "🙂e\u{301}中文", count: 3000)
        let blocks = NotionArchivePayload.render(long)
        checkEqual(blocks.map(\.text).joined(), long); checkTrue(blocks.allSatisfy { $0.text.utf16.count <= 1500 })
        checkEqual(payload.fingerprint, try JSONDecoder().decode(NotionArchivePayload.self, from: JSONEncoder().encode(payload)).fingerprint)
        lecture.courseware = nil
        checkFalse(NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics").blocks.contains { $0.text.contains("Lecture.pdf") })
        let compact = NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics", includeTranscript: false)
        let compactText = compact.blocks.map(\.text).joined(separator: "\n")
        checkFalse(compactText.contains(lecture.segments[0].english))
        checkFalse(compactText.contains(lecture.segments[0].chinese))
        checkTrue(compactText.contains("中文笔记"))
        let expanded = NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics", includeTranscript: true)
        checkTrue(flattened(expanded.blocks).map(\.text).joined(separator: "\n").contains(lecture.segments[0].english))
        checkTrue(compact.fingerprint != expanded.fingerprint)
    }
    @MainActor func testNotionLongSyncAndVersionPreservesAnnotations() async throws {
        let api = FakeNotion()
        api.returnAllSiblings = true
        let payload = NotionArchivePayload(title: "2026年11月13日", blocks: (0..<125).map { .init("paragraph", "Line \($0)") })
        var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: payload)
        let result = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
        checkEqual(api.createCalls, 1); checkEqual(result.phase, .synced); checkNil(result.job)
        let page = result.page!.id
        let revision = api.lists[page]!.first!.id
        checkEqual(api.lists[revision]!.map(\.content), payload.blocks)
        let calls = api.appendCalls
        _ = try await NotionArchiveEngine.sync(result, api: api, save: { saved = $0 }, progress: { _ in })
        checkEqual(api.appendCalls, calls)
        api.lists[revision]!.append(.init(id: UUID().uuidString, type: "paragraph", text: "My annotation"))
        saved.job = .init(payload: .init(title: payload.title, blocks: [.init("New notes")]))
        let updated = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
        checkEqual(updated.page?.id, page); checkEqual(api.createCalls, 1); checkEqual(api.lists[page]?.count, 2)
        checkEqual(api.lists[revision]?.last?.content.text, "My annotation")
    }
    @MainActor func testNotionLostResponsesRecoverWithoutDuplicateWrites() async throws {
        for stage in ["page", "toggle", "batch"] {
            let api = FakeNotion(); api.lost = stage
            var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Date", blocks: (0..<80).map { .init("Line \($0)") }))
            do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
            checkEqual(saved.phase, .failed)
            // Serialize to simulate a restart while the write response was lost.
            saved = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONEncoder().encode(saved))
            let result = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
            checkEqual(api.createCalls, 1); checkEqual(result.phase, .synced)
            let revisions = api.lists[result.page!.id]!
            checkEqual(revisions.count, 1); checkEqual(api.lists[revisions[0].id]?.count, 80)
        }
    }
    @MainActor func testNotionUnknownWritesAndManualEditsNeverOverwrite() async throws {
        let api = FakeNotion()
        var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Date", blocks: [.init("Original")]))
        saved.pagePending = true
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        checkEqual(api.createCalls, 0)
        saved.pagePending = false; api.lost = "batch"
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        let revision = saved.job!.revisionID!
        api.lists[revision]![0].content.text = "Manual change"
        let count = api.appendCalls
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        checkEqual(api.appendCalls, count); checkEqual(api.lists[revision]![0].content.text, "Manual change")
    }
    @MainActor func testNotionDelayedReadbackDoesNotRepeatSuccessfulBatch() async throws {
        let api = FakeNotion(); api.hideNextRead = true
        var saved = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Date", blocks: [.init("Original")]))
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        checkTrue(saved.job!.appendPending)
        let calls = api.appendCalls
        let result = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
        checkEqual(result.phase, .synced); checkEqual(api.appendCalls, calls)
    }
    @MainActor func testNotionRejectedWriteRetryAndPersistenceProtection() async throws {
        let api = FakeNotion(); api.rejectNext = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root); let lecture = fixtureLecture(); try store.save(lecture)
        let original = try Data(contentsOf: store.directory(lecture.id).appendingPathComponent("lecture.json"))
        var saved = NotionArchiveRecord(lectureID: lecture.id, parent: api.parent, payload: .init(title: "Date", blocks: [.init("Body")]))
        let save: (NotionArchiveRecord) throws -> Void = { saved = $0; try store.saveNotionArchive($0) }
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: save, progress: { _ in }); checkTrue(false) } catch {}
        checkFalse(saved.job!.revisionPending)
        let resumed = try store.loadNotionArchive(lecture.id)!
        _ = try await NotionArchiveEngine.sync(resumed, api: api, save: save, progress: { _ in })
        checkEqual(saved.phase, .synced); checkEqual(api.createCalls, 1)
        checkEqual(try Data(contentsOf: store.directory(lecture.id).appendingPathComponent("lecture.json")), original)
        try store.moveToTrash(lecture.id); try store.restore(lecture.id)
        checkEqual(try store.loadNotionArchive(lecture.id)?.page?.id, saved.page?.id)
        try Data("corrupt".utf8).write(to: store.directory(lecture.id).appendingPathComponent("notion-archive.json"))
        do { _ = try store.loadNotionArchive(lecture.id); checkTrue(false) } catch {}
    }
    @MainActor func testNotionHTTPPaginationRetryAndCredentialBoundaries() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotionURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel(); NotionURLProtocol.handler = nil }
        let id = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        var calls = 0, waits: [Double] = []
        NotionURLProtocol.handler = { request in
            calls += 1
            checkEqual(request.url?.host, "api.notion.com")
            checkEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            checkEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
            if calls == 1 { return (429, ["Retry-After": "2"], ["code": "rate_limited"]) }
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "start_cursor" }?.value
            let block: [String: Any] = ["id": cursor == nil ? id : second, "type": "paragraph", "paragraph": ["rich_text": [["plain_text": cursor == nil ? "First" : "Second"]]]]
            if cursor == nil { return (200, [:], ["results": [block], "has_more": true, "next_cursor": "opaque/+ cursor"]) }
            checkEqual(cursor, "opaque/+ cursor")
            return (200, [:], ["results": [block], "has_more": false])
        }
        let client = NotionClient(token: "fixture-token", session: session, pause: { waits.append($0) })
        let children = try await client.children(id)
        checkEqual(children.map(\.content.text), ["First", "Second"]); checkTrue(waits.contains { $0 > 1.9 })
        calls = 0
        NotionURLProtocol.handler = { _ in calls += 1; return (503, [:], ["code": "service_unavailable", "message": "sensitive server text"]) }
        do { _ = try await client.createPage(parent: id, title: "Date"); checkTrue(false) }
        catch { checkFalse(error.localizedDescription.contains("sensitive")); checkFalse((error as? NotionRequestFailure)?.definiteRejection ?? true) }
        checkEqual(calls, 1)
    }
}

extension ClassnoteCoreTests {
    @MainActor func testNotionMeetingCreateAndMoveRecoverWithoutDuplicates() async throws {
        let api = FakeNotion()
        var destination = api.parent
        destination.meetings = .init(dataSourceID: UUID().uuidString.lowercased(), title: "Meetings", titleProperty: "title", courseProperty: "course", dateProperty: "date")
        var saved = NotionArchiveRecord(lectureID: UUID(), parent: destination, payload: .init(title: "Meeting", blocks: [.init("Body")]))
        api.lost = "page"
        do { _ = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in }); checkTrue(false) } catch {}
        saved = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONEncoder().encode(saved))
        let created = try await NotionArchiveEngine.sync(saved, api: api, save: { saved = $0 }, progress: { _ in })
        checkEqual(api.createCalls, 1); checkEqual(created.page?.parentDataSourceID, destination.meetings?.dataSourceID)
        for lost in ["move", "properties"] {
            var record = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Old", blocks: [.init("Original body")]))
            record = try await NotionArchiveEngine.sync(record, api: api, save: { _ in }, progress: { _ in })
            let id = record.page!.id, oldRevisions = api.lists[id]!.map(\.id), calls = api.createCalls
            record.relocation = destination; record.relocationDate = Date(); api.lost = lost
            let moves = api.moveCalls
            let result: NotionArchiveRecord
            if lost == "properties" {
                // Placement succeeded even when metadata write was unavailable.
                result = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in })
                checkTrue(result.meetingWarning?.contains("部分字段") == true)
            } else {
                do { _ = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in }); checkTrue(false) } catch {}
                record = try JSONDecoder().decode(NotionArchiveRecord.self, from: JSONEncoder().encode(record))
                result = try await NotionArchiveEngine.sync(record, api: api, save: { record = $0 }, progress: { _ in })
            }
            checkEqual(result.phase, .synced); checkNil(result.relocation); checkEqual(result.page?.id, id)
            checkEqual(api.moveCalls, moves + 1); checkEqual(api.createCalls, calls)
            checkEqual(api.lists[id]!.map(\.id), oldRevisions)
        }
        var unknown = NotionArchiveRecord(lectureID: UUID(), parent: api.parent, payload: .init(title: "Old", blocks: []))
        unknown.page = try await api.createPage(parent: api.parent.id, title: "Old"); unknown.job = nil
        unknown.relocation = destination; unknown.movePending = true
        let moves = api.moveCalls
        do { _ = try await NotionArchiveEngine.sync(unknown, api: api, save: { _ in }, progress: { _ in }); checkTrue(false) } catch {}
        checkEqual(api.moveCalls, moves)
        // An external move must never be silently undone.
        unknown.movePending = nil; api.pages[unknown.page!.id]?.parentPageID = UUID().uuidString
        do { _ = try await NotionArchiveEngine.sync(unknown, api: api, save: { _ in }, progress: { _ in }); checkTrue(false) } catch {}
        checkEqual(api.moveCalls, moves)
    }
    @MainActor func testNotionMeetingSchemaAndHTTPDestination() async throws {
        let source = UUID().uuidString.lowercased(), course = UUID().uuidString.lowercased(), db = UUID().uuidString.lowercased(), meetingSource = UUID().uuidString.lowercased(), meetingPage = UUID().uuidString.lowercased()
        var schema: [String: Any] = ["object": "data_source", "id": meetingSource, "title": [["plain_text": "Meetings"]], "properties": [
            "名称": ["id": "title", "type": "title"],
            "课程": ["id": "course-id", "type": "relation", "relation": ["data_source_id": source]],
            "上课或会议日期": ["id": "date-id", "type": "date"]
        ]]
        let target = try NotionClient.meetingSchema(schema, courseSource: source)
        checkEqual(target.courseProperty, "course-id")
        let looseTarget = try NotionClient.meetingSchema(schema, courseSource: UUID().uuidString)
        checkNil(looseTarget.courseProperty)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NotionURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel(); NotionURLProtocol.handler = nil }
        var methods: [String] = []
        func body(_ request: URLRequest) throws -> [String: Any] {
            if let data = request.httpBody { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
            guard let stream = request.httpBodyStream else { return [:] }
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        NotionURLProtocol.handler = { request in
            let path = request.url!.path; methods.append(request.httpMethod! + " " + path)
            if path == "/v1/pages/" + course { return (200, [:], ["object": "page", "id": course, "parent": ["data_source_id": source], "properties": [:]]) }
            if path == "/v1/databases/" + db { return (200, [:], ["data_sources": [["id": meetingSource]]]) }
            if path == "/v1/data_sources/" + meetingSource { return (200, [:], schema) }
            let json = try body(request)
            if path.hasSuffix("/query") {
                let filter = json["filter"] as! [String: Any]; checkEqual(filter["property"] as? String, "title")
                return (200, [:], ["results": [], "has_more": false])
            }
            if path == "/v1/pages" {
                checkEqual((json["parent"] as? [String: String])?["data_source_id"], meetingSource)
                let props = json["properties"] as! [String: [String: Any]]
                checkEqual((props["course-id"]?["relation"] as? [[String: String]])?.first?["id"], course)
                checkTrue(props["date-id"]?["date"] != nil)
                return (200, [:], ["object": "page", "id": meetingPage, "parent": ["data_source_id": meetingSource], "properties": [:]])
            }
            throw NotionFailure("Unexpected endpoint")
        }
        let client = NotionClient(token: "fixture-token", session: session, pause: { _ in })
        let choices = try await client.meetingTargets(databaseLink: db, courseID: course)
        var parent = try await client.page(course); parent.meetings = choices[0]
        try await client.validateDestination(parent)
        _ = try await client.pendingPages(parent: parent, title: "Unique job")
        _ = try await client.createArchivePage(parent: parent, title: "Unique job", date: Date())
        checkTrue(methods.contains("POST /v1/pages"))
        schema["properties"] = ["Wrong": ["id": "course-id", "type": "rich_text"]]
        do { try await client.validateDestination(parent); checkTrue(false) } catch {}
    }
}
