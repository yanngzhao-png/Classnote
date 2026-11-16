import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func testNotionStudyBodyFoldsEvidenceAndKeepsCitations() throws {
        let json = #"{"summary":"- 本节讨论**机会成本**","points":[{"title":"机会成本","teaching":"选择意味着放弃其他机会。\n- **关键区别**：成本包括放弃的最佳选项。","transcript":[{"time":"00:12","quote":"The best alternative forgone.","verification":"verified"}],"slides":[{"page":2,"quote":"Opportunity cost definition","explanation":"定义对应课堂讲解。","verification":"verified"},{"page":3,"quote":"Unconfirmed excerpt","explanation":"可能关联","verification":"needsReview"}],"unmatchedReason":""},{"title":"课堂例子","teaching":"例子帮助理解权衡。","transcript":[],"slides":[],"unmatchedReason":"课件未覆盖此例子"}],"supplements":[{"page":1,"quote":"Additional reading","explanation":"课件补充，不是教授讲过的内容。"}],"reviewQuestions":["什么是机会成本？"]}"#
        let notes = try JSONDecoder().decode(BoundNotes.self, from: Data(json.utf8))
        var lecture = fixtureLecture()
        let material = Courseware(name: "Lecture.pdf", byteCount: 1, pages: (1...3).map { .init(number: $0, text: "Source") })
        lecture.courseware = material
        var combined = CombinedNote(markdown: notes.markdown(source: material.source), source: material.source, transcript: lecture.transcript)
        combined.bindings = notes; lecture.combinedNote = combined
        let payload = NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics")
        let visible = payload.blocks.map(\.text).joined(separator: "\n")
        checkTrue(visible.contains("选择意味着放弃其他机会"))
        checkTrue(visible.contains("Lecture.pdf · p.2、p.3（待核对）"))
        checkFalse(visible.contains("The best alternative")); checkFalse(visible.contains("Opportunity cost definition"))
        checkFalse(visible.contains("00:12")); checkFalse(visible.contains("**"))
        checkFalse(visible.contains(lecture.segments[0].english))
        let toggles = payload.blocks.filter { $0.type == "toggle" }
        checkEqual(toggles.count, 3)
        checkTrue(toggles[0].text.contains("待核对"))
        let evidence = toggles[0].children!.map(\.text).joined(separator: "\n")
        checkTrue(evidence.contains("The best alternative forgone."))
        checkTrue(evidence.contains("00:12")); checkTrue(evidence.contains("对应课堂讲解"))
        checkTrue(evidence.contains("非已核实引文"))
        checkTrue(toggles[1].children!.contains { $0.text == "课件未覆盖此例子" })
        checkTrue(payload.blocks.contains { $0.type == "numbered_list_item" })
        checkTrue(payload.blocks.contains { $0.richText?.contains(where: { $0.bold }) == true })
        let expanded = NotionArchivePayload(lecture: lecture, title: "Date", courseName: "Economics", includeTranscript: true)
        checkEqual(expanded.blocks.last?.text, "完整英文原稿与中文翻译")
        checkTrue(expanded.blocks.last!.children!.contains { $0.text == lecture.segments[0].english })
        checkTrue(payload.fingerprint != expanded.fingerprint)
    }

    func testNotionRichTextUnicodeAndLegacyFingerprint() throws {
        let markdown = "## 标题\n- **机会成本**和 `cost`\n1. 回想例子\n未闭合**保持原样"
        let blocks = NotionArchivePayload.render(markdown)
        checkEqual(blocks.map(\.type), ["heading_2", "bulleted_list_item", "numbered_list_item", "paragraph"])
        checkEqual(blocks[1].text, "机会成本和 cost")
        checkTrue(blocks[1].richText!.first!.bold); checkTrue(blocks[1].richText!.last!.code)
        checkEqual(blocks[3].text, "未闭合**保持原样")
        let long = String(repeating: "🙂e\u{301}中文", count: 3000)
        let rich = NotionStudyNotes.formatted("**" + long + "**")
        checkEqual(rich.map(\.text).joined(), long)
        checkTrue(rich.allSatisfy { $0.text.utf16.count <= 1500 && $0.richText!.allSatisfy(\.bold) })
        let many = NotionStudyNotes.formatted(String(repeating: "**粗体**普通", count: 200))
        checkTrue(many.allSatisfy { ($0.richText?.count ?? 0) <= 81 })
        checkEqual(many.map(\.text).joined(), String(repeating: "粗体普通", count: 200))
        // Old persisted payloads must hash identically after optional fields are added.
        let old = #"{"blocks":[{"text":"Body","type":"paragraph"}],"title":"Date"}"#
        let payload = try JSONDecoder().decode(NotionArchivePayload.self, from: Data(old.utf8))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        checkEqual(String(data: try encoder.encode(payload), encoding: .utf8), old)
        let job = try JSONDecoder().decode(NotionArchiveJob.self, from: encoder.encode(NotionArchiveJob(payload: payload)))
        checkNil(job.nestedProgress)
        checkEqual(job.fingerprint, payload.fingerprint)
    }
}
