import Foundation
import CoreGraphics
import AppKit
import CoreText
import PDFKit
import Darwin
import ClassnoteCore

struct ClassnoteCoreTests {
    func pdfFixture(_ texts: [String]) -> Data {
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for text in texts {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                context.textPosition = CGPoint(x: 50, y: 700)
                let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)])
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    func fixtureLecture() -> Lecture {
        var lecture = Lecture(title: "Economics"); lecture.state = .ended
        lecture.segments = [TranscriptSegment(offset: 12, english: "Opportunity cost is the next best alternative.", chinese: "机会成本是次优选择。", state: .translated)]
        return lecture
    }
    func testOldSessionDecodesWithoutCoursewareFields() throws {
        let lecture = fixtureLecture()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(lecture)) as! [String: Any]
        for key in ["courseware", "combinedNote", "combinedNoteError"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Lecture.self, from: JSONSerialization.data(withJSONObject: json))
        checkEqual(decoded.id, lecture.id); checkEqual(decoded.segments, lecture.segments)
        checkNil(decoded.courseware); checkNil(decoded.combinedNote)
    }
    func testPDFExtractionPreservesPhysicalPageNumbersAndEmptyPages() throws {
        let result = try PDFCoursewareImporter.extract(pdfFixture(["Opportunity cost", "", "Sunk cost"]), name: "Lecture.pdf")
        checkEqual(result.courseware.source.pageCount, 3)
        checkEqual(result.courseware.textPages.map(\.number), [1, 3])
        checkEqual(result.courseware.emptyPageNumbers, [2])
        checkTrue(result.courseware.pages[0].text.contains("Opportunity cost"))
        checkTrue(result.courseware.pages[2].text.contains("Sunk cost"))
        let blank = try PDFCoursewareImporter.extract(pdfFixture([""]), name: "Scanned.pdf")
        checkTrue(blank.courseware.textPages.isEmpty)
    }
    func testPDFRejectsCorruptOversizeAndLockedFiles() throws {
        do { _ = try PDFCoursewareImporter.extract(Data("not a PDF".utf8), name: "bad.pdf"); checkTrue(false) } catch {}
        do { _ = try PDFCoursewareImporter.extract(Data(repeating: 0, count: PDFCoursewareImporter.maximumBytes + 1), name: "large.pdf"); checkTrue(false) } catch {}
        let document = PDFDocument(data: pdfFixture(["Secret"]))!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: root) }
        checkTrue(document.write(to: root, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
        checkTrue(PDFDocument(url: root)?.isLocked == true)
        do { _ = try PDFCoursewareImporter.read(root); checkTrue(false) } catch {}
    }
    func testPDFCopySurvivesTrashAndRestoreAndRejectsTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root); var lecture = fixtureLecture()
        let imported = try PDFCoursewareImporter.extract(pdfFixture(["Lecture source"]), name: "source.pdf")
        try store.saveMaterial(imported, lectureID: lecture.id); lecture.courseware = imported.courseware; try store.save(lecture)
        try store.moveToTrash(lecture.id); try store.restore(lecture.id)
        let loaded = try store.load().lectures[0]
        checkEqual(loaded.courseware, lecture.courseware)
        checkEqual(try Data(contentsOf: store.materialURL(imported.courseware.source, lectureID: lecture.id)), imported.data)
        var bad = imported.courseware.source; bad.fileName = "../../outside.pdf"
        do { _ = try store.materialURL(bad, lectureID: lecture.id); checkTrue(false) } catch {}
    }
    func testCombinedNoteKeepsOriginalAndDetectsChangedSources() throws {
        var lecture = fixtureLecture(); lecture.notes = "Original notes"
        let material = Courseware(name: "Course.pdf", byteCount: 1, pages: [.init(number: 1, text: "Source")])
        lecture.courseware = material
        let note = CombinedNote(markdown: "Combined [课堂 00:12] [课件 p.1]", source: material.source, transcript: lecture.transcript)
        lecture.combinedNote = note
        checkFalse(note.isStale(for: lecture)); checkTrue(lecture.markdown().contains("Original notes"))
        checkFalse(lecture.markdown().contains("Combined"))
        checkTrue(lecture.markdown(combined: true).contains("Combined")); checkTrue(lecture.markdown(combined: true).contains(lecture.segments[0].english))
        lecture.title = "Renamed"; checkFalse(note.isStale(for: lecture))
        lecture.segments[0].english += " New fact"; checkTrue(note.isStale(for: lecture))
        checkTrue(lecture.markdown(combined: true).contains("已变化"))
        lecture = fixtureLecture(); lecture.courseware = Courseware(name: "Course.pdf", byteCount: 1, pages: material.pages)
        checkTrue(note.isStale(for: lecture))
        let decoded = try JSONDecoder().decode(CombinedNote.self, from: JSONEncoder().encode(note))
        checkEqual(decoded, note)
    }
    func testSourceReferencesRejectInventedPagesAndTimes() throws {
        var lecture = fixtureLecture()
        let material = Courseware(name: "Test.pdf", byteCount: 1, pages: [.init(number: 1, text: "Text"), .init(number: 2, text: "")])
        try SourceReferences.validate("Fact [课堂 00:12] [课件 p.1]", lecture: lecture, courseware: material)
        for text in ["Bad [课堂 00:13] [课件 p.1]", "Bad [课堂 00:12] [课件 p.2]", "No references", "Only [课件 p.1]"] {
            do { try SourceReferences.validate(text, lecture: lecture, courseware: material); checkTrue(false) } catch {}
        }
        lecture.segments[0].offset = 3723
        try SourceReferences.validate("Fact [课堂 1:02:03] [课件 p.1]", lecture: lecture, courseware: material)
        let linked = SourceReferences.linkedMarkdown("[课件 p.1] and [课件 p.1]", source: material.source)
        checkEqual(linked.components(separatedBy: "classnote://material/").count, 3)
    }
    func testLongSourceChunksPreserveEveryPageAndTimestamp() {
        var lecture = fixtureLecture(); lecture.segments[0].english = String(repeating: "abc中", count: 8000)
        let material = Courseware(name: "Long.pdf", byteCount: 1, pages: [.init(number: 1, text: String(repeating: "XYZ", count: 9000)), .init(number: 2, text: "LAST_PAGE_SENTINEL")])
        let chunks = CombinedNotesEngine.sourceChunks(lecture: lecture, courseware: material)
        checkTrue(chunks.allSatisfy { $0.count <= CombinedNotesEngine.chunkLimit })
        checkTrue(chunks.joined().contains("LAST_PAGE_SENTINEL"))
        let joined = chunks.joined().replacingOccurrences(of: "[课堂 00:12]", with: "").replacingOccurrences(of: "[课件 p.1]", with: "").replacingOccurrences(of: "[课件 p.2]", with: "").replacingOccurrences(of: "\n", with: "")
        checkEqual(joined, lecture.segments[0].english + material.pages.map(\.text).joined())
    }
    func bindingJSON(page: Int = 1, quote: String = "Opportunity cost", unmatched: Bool = false) throws -> String {
        let slide: [String: Any] = ["page": page, "quote": quote, "explanation": "课件给出机会成本定义，与老师介绍的概念对应。"]
        let point: [String: Any] = ["title": "机会成本", "teaching": "老师介绍了次优选择。", "transcript": [["time": "00:12", "quote": "Opportunity cost is the next best alternative."]], "slides": unmatched ? [] : [slide], "unmatchedReason": unmatched ? "课件未讨论此概念。" : ""]
        let json: [String: Any] = ["summary": "机会成本课堂", "points": [point], "supplements": [], "reviewQuestions": ["什么是次优选择？"]]
        return String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    }
    func testBoundNotesRequireExactSourceExcerptsAndAllowUnmatched() throws {
        let lecture = fixtureLecture()
        let material = Courseware(name: "Test.pdf", byteCount: 1, pages: [.init(number: 1, text: "Opportunity cost"), .init(number: 2, text: "Different topic")])
        let note = try BoundNotes.decode(bindingJSON(), lecture: lecture, courseware: material)
        checkEqual(note.points[0].slides[0].verification, .verified)
        checkEqual(try JSONDecoder().decode(BoundNotes.self, from: JSONEncoder().encode(note)), note)
        for page in [2, 999] {
            let repaired = try BoundNotes.decode(bindingJSON(page: page), lecture: lecture, courseware: material)
            checkEqual(repaired.points[0].slides[0].page, 1)
            checkEqual(repaired.points[0].slides[0].verification, .corrected)
        }
        let uncertain = try BoundNotes.decode(bindingJSON(quote: "A paraphrased possible connection"), lecture: lecture, courseware: material)
        checkEqual(uncertain.points.count, 1); checkEqual(uncertain.points[0].slides[0].verification, .needsReview)
        let markdown = uncertain.markdown(source: material.source)
        checkTrue(markdown.contains("非已核实引文")); checkFalse(markdown.contains("> A paraphrased"))
        checkTrue(markdown.contains("[课件 p.1]"))
        let missing = try BoundNotes.decode(bindingJSON(page: 999, quote: "Unknown content"), lecture: lecture, courseware: material)
        checkFalse(missing.points[0].slides[0].canOpenPage)
        checkFalse(missing.markdown(source: material.source).contains("[课件 p.999]"))
        let corrected = try BoundNotes.decode(bindingJSON().replacingOccurrences(of: "00:12", with: "00:15"), lecture: lecture, courseware: material)
        checkEqual(corrected.points[0].transcript[0].time, "00:12")
        let loose = try BoundNotes.decode(bindingJSON().replacingOccurrences(of: "next best alternative.", with: "invented alternative."), lecture: lecture, courseware: material)
        checkEqual(loose.points[0].transcript[0].verification, .needsReview)
        checkEqual(loose.reviewCount, 1)
        let unrelated = try BoundNotes.decode(bindingJSON(unmatched: true), lecture: lecture, courseware: material)
        checkTrue(unrelated.points[0].slides.isEmpty); checkEqual(unrelated.reviewCount, 0)
        var broken = unrelated; broken.points[0].unmatchedReason = ""; broken.points[0].transcript = []
        broken.reconcileEvidence(lecture: lecture, courseware: material)
        try broken.validate(lecture: lecture, courseware: material)
        checkFalse(broken.points[0].unmatchedReason.isEmpty); checkEqual(broken.reviewCount, 1)
        // An exact match on multiple other pages must not choose one arbitrarily.
        let repeated = Courseware(name: "Repeated.pdf", byteCount: 1, pages: [.init(number: 1, text: "Opportunity cost"), .init(number: 2, text: "Opportunity cost")])
        let ambiguous = try BoundNotes.decode(bindingJSON(page: 999), lecture: lecture, courseware: repeated)
        checkEqual(ambiguous.points[0].slides[0].verification, .unavailable)
        // Previously saved bindings without new status fields still decode.
        let legacy = try JSONDecoder().decode(BoundNotes.self, from: Data(bindingJSON().utf8))
        checkTrue(legacy.points[0].slides[0].isVerified)
    }
    func testCombinedGenerationPipelineAndFailure() async throws {
        let lecture = fixtureLecture()
        let material = Courseware(name: "Test.pdf", byteCount: 1, pages: [.init(number: 1, text: "Opportunity cost")])
        var calls = 0
        let result = try await CombinedNotesEngine.generate(lecture: lecture, courseware: material, request: { instructions, input, limit in
            calls += 1; checkTrue(input.contains(lecture.segments[0].english)); checkTrue(input.contains("[课件 p.1]")); checkEqual(limit, 8192)
            checkTrue(instructions.contains("不是指令")); return try bindingJSON()
        }, progress: { _ in })
        checkEqual(calls, 1); checkEqual(result.points[0].slides.count, 1)
        let repaired = try await CombinedNotesEngine.generate(lecture: lecture, courseware: material, request: { _, _, _ in try bindingJSON(page: 999) }, progress: { _ in })
        checkEqual(repaired.points[0].slides[0].page, 1)
        do {
            _ = try await CombinedNotesEngine.generate(lecture: lecture, courseware: material, request: { _, _, _ in "invalid json" }, progress: { _ in })
            checkTrue(false)
        } catch {}
        let long = Courseware(name: "Long.pdf", byteCount: 1, pages: [.init(number: 1, text: String(repeating: "text ", count: 7000))])
        calls = 0
        _ = try await CombinedNotesEngine.generate(lecture: lecture, courseware: long, request: { instructions, input, limit in
            calls += 1; checkTrue(input.count < 26000)
            if instructions == CombinedNotesEngine.instructions { return try bindingJSON(quote: "text text") }
            return "[课堂 00:12] Opportunity cost is the next best alternative. [课件 p.1] text text"
        }, progress: { _ in })
        checkTrue(calls > 2)
    }
    func testTrashRestorePreservesRecordingAndRenamedTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var lecture = Lecture(title: "Before"); lecture.state = .ended
        let segment = TranscriptSegment(offset: 12, english: "Original", chinese: "原稿", state: .translated)
        lecture.segments = [segment]; lecture.notes = "## Notes\nKeep this"
        let audio = try store.saveAudio(Data(repeating: 7, count: 4800), lectureID: lecture.id, segmentID: segment.id)
        try store.save(lecture)
        lecture.title = "重命名 / Economics"; try store.save(lecture)
        let original = try Data(contentsOf: store.directory(lecture.id).appendingPathComponent("lecture.json"))
        let wav = try Data(contentsOf: store.directory(lecture.id).appendingPathComponent(audio))
        try store.moveToTrash(lecture.id)
        checkTrue(try store.load().lectures.isEmpty)
        checkEqual(try store.loadTrash().lectures.map(\.id), [lecture.id])
        checkEqual(try Data(contentsOf: store.trashRoot.appendingPathComponent(lecture.id.uuidString).appendingPathComponent(audio)), wav)
        // A fresh store simulates relaunch while the record is in Recently Deleted.
        let reopened = try LectureStore(root: root); try reopened.restore(lecture.id)
        checkTrue(try reopened.loadTrash().lectures.isEmpty)
        checkEqual(try reopened.load().lectures.first?.title, lecture.title)
        checkEqual(try Data(contentsOf: reopened.directory(lecture.id).appendingPathComponent("lecture.json")), original)
        checkEqual(try Data(contentsOf: reopened.directory(lecture.id).appendingPathComponent(audio)), wav)
    }
    func testRestoreCollisionNeverOverwritesEitherRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var lecture = Lecture(title: "Deleted version"); lecture.state = .ended
        try store.save(lecture); try store.moveToTrash(lecture.id)
        lecture.title = "Existing version"; try store.save(lecture)
        do { try store.restore(lecture.id); checkTrue(false) } catch {}
        checkEqual(try store.load().lectures.first?.title, "Existing version")
        checkEqual(try store.loadTrash().lectures.first?.title, "Deleted version")
        do { try store.moveToTrash(lecture.id); checkTrue(false) } catch {}
        checkEqual(try store.load().lectures.first?.title, "Existing version")
        checkEqual(try store.loadTrash().lectures.first?.title, "Deleted version")
    }
    func testPlayerExpansionKeepsSameEdgeAndTop() {
        let bounds = CGRect(x: 14, y: 14, width: 1400, height: 850)
        for left in [false, true] {
            let compact = CGRect(x: left ? bounds.minX : bounds.maxX - 278, y: 700, width: 278, height: 66)
            let expanded = PlayerGeometry.frame(current: compact, size: CGSize(width: 480, height: 400), bounds: bounds, leftEdge: left)
            checkEqual(expanded.maxY, compact.maxY)
            if left { checkEqual(expanded.minX, compact.minX) } else { checkEqual(expanded.maxX, compact.maxX) }
            checkEqual(PlayerGeometry.frame(current: expanded, size: PlayerGeometry.compactSize, bounds: bounds, leftEdge: left), compact)
            checkTrue(bounds.contains(PlayerGeometry.frame(current: compact, size: CGSize(width: 4000, height: 2000), bounds: bounds, leftEdge: left)))
            let low = PlayerGeometry.frame(current: CGRect(x: 0, y: -200, width: 278, height: 66), size: CGSize(width: 480, height: 400), bounds: bounds, leftEdge: left)
            checkTrue(bounds.contains(low))
        }
    }
    func testPersistenceAndCrashRecoveryPreservesOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var lecture = Lecture(title: "Economics / 微观经济学")
        lecture.state = .recording
        lecture.segments = [TranscriptSegment(offset: 3, english: "Do not replace the original.", chinese: "保留原稿。", state: .translated)]
        try store.save(lecture)
        let loaded = try store.load()
        checkEqual(loaded.lectures.count, 1)
        checkEqual(loaded.lectures[0].state, .interrupted)
        checkEqual(loaded.lectures[0].segments, lecture.segments)
        checkEqual(loaded.lectures[0].id, lecture.id)
        checkTrue(loaded.unreadable.isEmpty)
    }
    func testCorruptRecordReportedWithoutHidingGoodRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root); let good = Lecture(title: "good")
        try store.save(good)
        let bad = root.appendingPathComponent("broken"); try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: bad.appendingPathComponent("lecture.json"))
        let loaded = try store.load()
        checkEqual(loaded.lectures.map(\.id), [good.id]); checkEqual(loaded.unreadable, ["broken"])
    }
    func testOrderedTranscriptsKeepBothLanguagesAndMarkMissingAudio() {
        var l = Lecture(title: "Lecture")
        l.segments = [TranscriptSegment(offset: 20, english: "Later", chinese: "后文", state: .translated), TranscriptSegment(offset: 5, english: "Earlier", chinese: "前文", state: .translated), TranscriptSegment(offset: 35)]
        checkEqual(l.orderedSegments.map(\.offset), [5, 20, 35])
        checkTrue(l.transcript.hasPrefix("[00:05] Earlier"))
        checkEqual(l.unfinishedCount, 1)
        let md = l.markdown()
        checkTrue(md.contains("前文")); checkTrue(md.contains("待转录"))
        checkFalse(l.markdown(includeTranslation: false).contains("前文"))
    }
    func testWavHasValidHeaderAndExactPayload() {
        let pcm = Data([0, 0, 0xff, 0x7f, 0, 0x80]); let wav = PCM.wav(pcm)
        checkEqual(wav.count, 44 + pcm.count)
        checkEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
        checkEqual(Array(wav[24..<28]), [0xc0, 0x5d, 0, 0]) // 24,000 Hz
        checkEqual(Array(wav[28..<32]), [0x80, 0xbb, 0, 0]) // 48,000 bytes/s
        checkEqual(wav.suffix(pcm.count), pcm)
        checkEqual(wav[40], UInt8(pcm.count))
    }
    func testSilenceDoesNotCreateBillableTurn() {
        var d = TurnDetector()
        for _ in 0..<100 { let r = d.push(Data(repeating: 0, count: 4800), rms: 0); checkTrue(r.append.isEmpty); checkNil(r.commit) }
        checkNil(d.flush())
    }
    func testTurnContainsPrerollAndClosesAfterSilenceWithoutDuplication() {
        var d = TurnDetector(); var sent = Data(); var saved: Data?
        for _ in 0..<5 { _ = d.push(Data(repeating: 1, count: 4800), rms: 0) }
        let voice = d.push(Data(repeating: 2, count: 4800), rms: 0.1); sent.append(voice.append)
        checkEqual(sent.count, 14400)
        for _ in 0..<9 { let r = d.push(Data(repeating: 0, count: 4800), rms: 0); sent.append(r.append); if let c = r.commit { saved = c } }
        checkEqual(saved, sent); checkFalse(d.active); checkNil(d.flush())
    }
    func testLongSpeechBoundedAndPauseFlushesRemainder() {
        var d = TurnDetector(); var count = 0
        for _ in 0..<125 { if d.push(Data(repeating: 2, count: 4800), rms: 0.1).commit != nil { count += 1 } }
        checkEqual(count, 1)
        checkEqual(d.flush()?.count, 24000)
        checkNil(d.flush())
    }
    func testRouterHandlesOutOfOrderFinalsAndEarlyFinal() {
        var router = TranscriptRouter(); let a = UUID(), b = UUID(), c = UUID()
        router.enqueue(a); router.enqueue(b); router.enqueue(c)
        checkEqual(router.acknowledge(item: "a")?.0, a)
        checkNil(router.complete(item: "c", text: "third"))
        checkEqual(router.acknowledge(item: "b")?.0, b)
        checkEqual(router.complete(item: "b", text: "second")?.0, b)
        checkEqual(router.complete(item: "a", text: "first")?.1, "first")
        let early = router.acknowledge(item: "c")
        checkEqual(early?.0, c); checkEqual(early?.1, "third")
        checkNil(router.acknowledge(item: "c"))
    }
    func testUnicodeChunkingNeverDropsWordsOrExceedsLimit() {
        let lines = ["first", String(repeating: "中🙂", count: 45), "last"]
        let chunks = TextChunks.split(lines.joined(separator: "\n"), limit: 20)
        checkTrue(chunks.allSatisfy { $0.count <= 20 })
        checkEqual(chunks.joined().replacingOccurrences(of: "\n", with: ""), lines.joined())
    }
    func testAudioRecoveryFileIsWrittenInsideLecture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root); let l = UUID(), s = UUID(); let pcm = Data(repeating: 7, count: 9600)
        let filename = try store.saveAudio(pcm, lectureID: l, segmentID: s)
        checkEqual(try Data(contentsOf: store.directory(l).appendingPathComponent(filename)), PCM.wav(pcm))
    }
    func testInterruptedPendingTurnBecomesRetryable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var l = Lecture(title: "Interrupted"); l.state = .recording
        l.segments = [TranscriptSegment(offset: 12, state: .pending, audioFile: "saved.wav")]
        try store.save(l)
        let recovered = try store.load().lectures[0]
        checkEqual(recovered.state, .interrupted)
        checkEqual(recovered.segments[0].state, .failed)
        checkEqual(recovered.segments[0].audioFile, "saved.wav")
        checkEqual(recovered.unfinishedCount, 1)
        checkFalse(recovered.segments[0].error?.isEmpty ?? true)
    }
    func testClipboardHTMLPreservesStructureAndEscapesSource() {
        let html = MarkdownExport.html("# 课堂\n\n## Concepts\n- **机会成本**\n- <script>alert(1)</script>\n\n1. Explain\n\n> Demo\n\n### 00:12\nEnglish & 中文")
        checkTrue(html.contains("<h1>课堂</h1>"))
        checkTrue(html.contains("<h2>Concepts</h2>"))
        checkTrue(html.contains("<strong>机会成本</strong>"))
        checkTrue(html.contains("</ul>\n<ol>"))
        checkTrue(html.contains("<h3>00:12</h3>"))
        checkTrue(html.contains("&lt;script&gt;"))
        checkFalse(html.contains("<script>"))
        checkTrue(html.contains("English &amp; 中文"))
    }
}

// A dependency-free regression runner also works on Macs with Command Line Tools only.
var failures = 0
func checkTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !value { failures += 1; print("FAIL \(file):\(line)") }
}
func checkFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { checkTrue(!value, file: file, line: line) }
func checkNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { checkTrue(value == nil, file: file, line: line) }
func checkEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { checkTrue(a == b, file: file, line: line) }
@main struct ChecksRunner {
static func main() async {
let suite = ClassnoteCoreTests()
let checks: [(String, () async throws -> Void)] = [
    ("testNotionStudyBodyFoldsEvidenceAndKeepsCitations", { try suite.testNotionStudyBodyFoldsEvidenceAndKeepsCitations() }),
    ("testNotionRichTextUnicodeAndLegacyFingerprint", { try suite.testNotionRichTextUnicodeAndLegacyFingerprint() }),
    ("testNotionNestedSourcesResumeAndReadBack", { try await suite.testNotionNestedSourcesResumeAndReadBack() }),
    ("testNotionNestedEditsAndReplacedContainersArePreserved", { try await suite.testNotionNestedEditsAndReplacedContainersArePreserved() }),
    ("testNotionNativeRichTextHTTPReadback", { try await suite.testNotionNativeRichTextHTTPReadback() }),
    ("testNotionDeletedArchiveRebuildUsesLatestNotesAndDestination", { try await suite.testNotionDeletedArchiveRebuildUsesLatestNotesAndDestination() }),
    ("testNotionRebuildRejectsHealthyDeniedAndUnknownPages", { try await suite.testNotionRebuildRejectsHealthyDeniedAndUnknownPages() }),
    ("testNotionRebuildLostResponsesResumeSameAttempt", { try await suite.testNotionRebuildLostResponsesResumeSameAttempt() }),
    ("testNotionPageUnavailableHTTPClassification", { try await suite.testNotionPageUnavailableHTTPClassification() }),
    ("testNotionLegacyRecordAndFailedCurrentState", { try suite.testNotionLegacyRecordAndFailedCurrentState() }),
    ("testNotionMeetingCreateAndMoveRecoverWithoutDuplicates", { try await suite.testNotionMeetingCreateAndMoveRecoverWithoutDuplicates() }),
    ("testNotionMeetingSchemaAndHTTPDestination", { try await suite.testNotionMeetingSchemaAndHTTPDestination() }),
    ("testNotionPageLinksAndStableCourseMappings", { try suite.testNotionPageLinksAndStableCourseMappings() }),
    ("testNotionPayloadKeepsSourcesAndBoundsUnicode", { try suite.testNotionPayloadKeepsSourcesAndBoundsUnicode() }),
    ("testNotionLongSyncAndVersionPreservesAnnotations", { try await suite.testNotionLongSyncAndVersionPreservesAnnotations() }),
    ("testNotionLostResponsesRecoverWithoutDuplicateWrites", { try await suite.testNotionLostResponsesRecoverWithoutDuplicateWrites() }),
    ("testNotionUnknownWritesAndManualEditsNeverOverwrite", { try await suite.testNotionUnknownWritesAndManualEditsNeverOverwrite() }),
    ("testNotionDelayedReadbackDoesNotRepeatSuccessfulBatch", { try await suite.testNotionDelayedReadbackDoesNotRepeatSuccessfulBatch() }),
    ("testNotionRejectedWriteRetryAndPersistenceProtection", { try await suite.testNotionRejectedWriteRetryAndPersistenceProtection() }),
    ("testNotionHTTPPaginationRetryAndCredentialBoundaries", { try await suite.testNotionHTTPPaginationRetryAndCredentialBoundaries() }),
    ("testEmptyTrashDeletesConfirmedAssetsAndPreservesEverythingElse", { try suite.testEmptyTrashDeletesConfirmedAssetsAndPreservesEverythingElse() }),
    ("testEmptyTrashReportsPartialFailureWithoutFollowingSymlinks", { try suite.testEmptyTrashReportsPartialFailureWithoutFollowingSymlinks() }),
    ("testEmptyTrashRejectsRedirectedTrashRoot", { try suite.testEmptyTrashRejectsRedirectedTrashRoot() }),
    ("testCompleteCaptureKeepsQuietSpeechAndSilenceByteForByte", { suite.testCompleteCaptureKeepsQuietSpeechAndSilenceByteForByte() }),
    ("testCompleteCaptureWaitsForPhraseAndKeepsShortTail", { suite.testCompleteCaptureWaitsForPhraseAndKeepsShortTail() }),
    ("testCompleteCaptureBoundsLongSpeechWithoutGaps", { suite.testCompleteCaptureBoundsLongSpeechWithoutGaps() }),
    ("testFreePlayerPositionAndOptionalEdgeSnap", { suite.testFreePlayerPositionAndOptionalEdgeSnap() }),
    ("testFreePlayerClampsAcrossNegativeScreenCoordinates", { suite.testFreePlayerClampsAcrossNegativeScreenCoordinates() }),
    ("testTranscriptionModelSpecificFieldsAndTerminology", { suite.testTranscriptionModelSpecificFieldsAndTerminology() }),
    ("testTuitionScheduleDurationsDuplicatesAndSemesterBounds", { suite.testTuitionScheduleDurationsDuplicatesAndSemesterBounds() }),
    ("testTuitionManualRateAndInvalidInputs", { suite.testTuitionManualRateAndInvalidInputs() }),
    ("testTuitionUsesActiveTimeAndExcludesDemoOutsideTerm", { suite.testTuitionUsesActiveTimeAndExcludesDemoOutsideTerm() }),
    ("testTuitionConfigurationRoundTrip", { try suite.testTuitionConfigurationRoundTrip() }),
    ("testTuitionUsageStartWeekExcludesEarlierLessonsAndLegacyDefaults", { try suite.testTuitionUsageStartWeekExcludesEarlierLessonsAndLegacyDefaults() }),
    ("testDateOnlyDefaultsPreserveCustomAndLegacyData", { try suite.testDateOnlyDefaultsPreserveCustomAndLegacyData() }),
    ("testScheduleICSRepeatsDSTAndExceptions", { try suite.testScheduleICSRepeatsDSTAndExceptions() }),
    ("testScheduleUTCIntervalUntilAndRejectedRules", { try suite.testScheduleUTCIntervalUntilAndRejectedRules() }),
    ("testScheduleCSVEscapingZonesAndValidation", { try suite.testScheduleCSVEscapingZonesAndValidation() }),
    ("testScheduleMatchingAmbiguityBoundaryAndDisable", { suite.testScheduleMatchingAmbiguityBoundaryAndDisable() }),
    ("testAutomaticCourseGroupingAndStableIdentity", { try suite.testAutomaticCourseGroupingAndStableIdentity() }),
    ("testScheduleGroupingJournalPreservesLectureFiles", { try suite.testScheduleGroupingJournalPreservesLectureFiles() }),
    ("testScheduleRefreshAndStoragePreserveRecords", { try suite.testScheduleRefreshAndStoragePreserveRecords() }),

    ("testCourseCatalogRenameAndLegacyPreservation", { try suite.testCourseCatalogRenameAndLegacyPreservation() }),
    ("testCourseMaterialIsOptionalAndSnapshotsPerLecture", { try suite.testCourseMaterialIsOptionalAndSnapshotsPerLecture() }),
    ("testCourseGroupingUsesIdentityAndUnfiledFallback", { suite.testCourseGroupingUsesIdentityAndUnfiledFallback() }),
    ("testCourseBatchExportNoOverwriteAndNoCrossCourseLeak", { try suite.testCourseBatchExportNoOverwriteAndNoCrossCourseLeak() }),
    ("testCourseExportCombinedPrecedenceAndIncompleteLabels", { try suite.testCourseExportCombinedPrecedenceAndIncompleteLabels() }),
    ("testOldSessionDecodesWithoutCoursewareFields", { try suite.testOldSessionDecodesWithoutCoursewareFields() }),
    ("testPDFExtractionPreservesPhysicalPageNumbersAndEmptyPages", { try suite.testPDFExtractionPreservesPhysicalPageNumbersAndEmptyPages() }),
    ("testPDFRejectsCorruptOversizeAndLockedFiles", { try suite.testPDFRejectsCorruptOversizeAndLockedFiles() }),
    ("testPDFCopySurvivesTrashAndRestoreAndRejectsTraversal", { try suite.testPDFCopySurvivesTrashAndRestoreAndRejectsTraversal() }),
    ("testCombinedNoteKeepsOriginalAndDetectsChangedSources", { try suite.testCombinedNoteKeepsOriginalAndDetectsChangedSources() }),
    ("testSourceReferencesRejectInventedPagesAndTimes", { try suite.testSourceReferencesRejectInventedPagesAndTimes() }),
    ("testLongSourceChunksPreserveEveryPageAndTimestamp", {  suite.testLongSourceChunksPreserveEveryPageAndTimestamp() }),
    ("testBoundNotesRequireExactSourceExcerptsAndAllowUnmatched", { try suite.testBoundNotesRequireExactSourceExcerptsAndAllowUnmatched() }),
    ("testCombinedGenerationPipelineAndFailure", { try await suite.testCombinedGenerationPipelineAndFailure() }),

    ("testTrashRestorePreservesRecordingAndRenamedTitle", { try suite.testTrashRestorePreservesRecordingAndRenamedTitle() }),
    ("testRestoreCollisionNeverOverwritesEitherRecord", { try suite.testRestoreCollisionNeverOverwritesEitherRecord() }),
    ("testPlayerExpansionKeepsSameEdgeAndTop", { suite.testPlayerExpansionKeepsSameEdgeAndTop() }),
    ("testPersistenceAndCrashRecoveryPreservesOriginal", { try suite.testPersistenceAndCrashRecoveryPreservesOriginal() }),
    ("testCorruptRecordReportedWithoutHidingGoodRecord", { try suite.testCorruptRecordReportedWithoutHidingGoodRecord() }),
    ("testOrderedTranscriptsKeepBothLanguagesAndMarkMissingAudio", { suite.testOrderedTranscriptsKeepBothLanguagesAndMarkMissingAudio() }),
    ("testWavHasValidHeaderAndExactPayload", { suite.testWavHasValidHeaderAndExactPayload() }),
    ("testSilenceDoesNotCreateBillableTurn", { suite.testSilenceDoesNotCreateBillableTurn() }),
    ("testTurnContainsPrerollAndClosesAfterSilenceWithoutDuplication", { suite.testTurnContainsPrerollAndClosesAfterSilenceWithoutDuplication() }),
    ("testLongSpeechBoundedAndPauseFlushesRemainder", { suite.testLongSpeechBoundedAndPauseFlushesRemainder() }),
    ("testRouterHandlesOutOfOrderFinalsAndEarlyFinal", { suite.testRouterHandlesOutOfOrderFinalsAndEarlyFinal() }),
    ("testUnicodeChunkingNeverDropsWordsOrExceedsLimit", { suite.testUnicodeChunkingNeverDropsWordsOrExceedsLimit() }),
    ("testAudioRecoveryFileIsWrittenInsideLecture", { try suite.testAudioRecoveryFileIsWrittenInsideLecture() }),
    ("testInterruptedPendingTurnBecomesRetryable", { try suite.testInterruptedPendingTurnBecomesRetryable() }),
    ("testClipboardHTMLPreservesStructureAndEscapesSource", { suite.testClipboardHTMLPreservesStructureAndEscapesSource() }),
 ]
for (name, body) in checks {
    let before = failures
    do { try await body() } catch { failures += 1; print("FAIL \(name): \(error)") }
    if failures == before { print("PASS \(name)") }
}
print("\(checks.count) checks; \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)

}
}
