import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func testCourseCatalogRenameAndLegacyPreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var old = fixtureLecture(); try store.save(old)
        let file = store.directory(old.id).appendingPathComponent("lecture.json")
        let bytes = try Data(contentsOf: file)
        checkTrue(try store.loadCourses().isEmpty)
        var course = Course(name: "Economics")
        try store.saveCourses([course]); course.name = "Economics II"; try store.saveCourses([course])
        checkEqual(try store.loadCourses(), [course]); checkEqual(try Data(contentsOf: file), bytes)
        checkNil(try store.load().lectures.first?.courseID)
        old.courseID = course.id; try store.save(old); try store.moveToTrash(old.id); try store.restore(old.id)
        checkEqual(try store.load().lectures.first?.courseID, course.id)
        checkEqual(try store.load().lectures.first?.segments, old.segments)
        do { try store.saveCourses([course, course]); checkTrue(false) } catch {}
        checkEqual(try store.loadCourses(), [course])
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(".courses.json"))
        do { _ = try store.loadCourses(); checkTrue(false) } catch {}
        checkEqual(try String(contentsOf: root.appendingPathComponent(".courses.json"), encoding: .utf8), "corrupt")
        checkEqual(try store.load().lectures.count, 1)
    }
    func testCourseMaterialIsOptionalAndSnapshotsPerLecture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var course = Course(name: "Media")
        let imported = try PDFCoursewareImporter.extract(pdfFixture(["before class"]), name: "Slides.pdf")
        try store.saveCourseMaterial(imported, courseID: course.id)
        course.courseware = imported.courseware
        try store.saveCourses([course])
        let lecture = Lecture(title: "Session")
        try store.copyCourseMaterial(imported.courseware, courseID: course.id, lectureID: lecture.id)
        checkTrue(FileManager.default.fileExists(atPath: try store.materialURL(imported.courseware.source, lectureID: lecture.id).path))
        let legacy = try JSONSerialization.data(withJSONObject: ["id": course.id.uuidString, "name": course.name, "createdAt": course.createdAt.timeIntervalSince1970])
        let decoded = try JSONDecoder().decode(Course.self, from: legacy)
        checkNil(decoded.courseware)
    }
    func testCourseGroupingUsesIdentityAndUnfiledFallback() {
        let course = Course(name: "Same"), other = Course(name: "Same")
        var a = fixtureLecture(), b = fixtureLecture(), orphan = fixtureLecture()
        a.courseID = course.id; b.courseID = other.id; orphan.courseID = UUID()
        let legacy = fixtureLecture(); let all = [a,b,orphan,legacy]
        checkEqual(Course.records(in: course, courses: [course,other], lectures: all).map(\.id), [a.id])
        checkEqual(Set(Course.records(in: .unfiled, courses: [course,other], lectures: all).map(\.id)), Set([orphan.id, legacy.id]))
        b.courseID = course.id
        checkEqual(Course.records(in: course, courses: [course,other], lectures: [a,b]).count, 2)
    }
    func testCourseBatchExportNoOverwriteAndNoCrossCourseLeak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let course = Course(name: "../经济学/🙂"), other = Course(name: "Other")
        var a = fixtureLecture(), b = fixtureLecture(), foreign = fixtureLecture()
        a.courseID = course.id; a.title = String(repeating: "📚中", count: 100); a.notes = "A_NOTE"; a.startedAt = Date(timeIntervalSince1970: 50)
        b.courseID = course.id; b.title = a.title; b.notes = "B_NOTE"; b.startedAt = Date(timeIntervalSince1970: 60)
        foreign.courseID = other.id; foreign.notes = "PRIVATE_OTHER_COURSE"
        let all = [foreign,b,a]
        let first = try CourseNotesExport.write(course: course, courses: [course,other], lectures: all, parent: root, includeOriginal: false)
        let second = try CourseNotesExport.write(course: course, courses: [course,other], lectures: all, parent: root, includeOriginal: true)
        checkEqual(first.count, 2); checkEqual(first.missingNotes, 0); checkFalse(first.directory == second.directory)
        let files = try FileManager.default.contentsOfDirectory(at: first.directory, includingPropertiesForKeys: nil)
        checkEqual(files.count, 4); checkTrue(files.allSatisfy { $0.lastPathComponent.utf8.count < 255 })
        let combined = try String(contentsOf: first.directory.appendingPathComponent("全部笔记.md"), encoding: .utf8)
        checkTrue(combined.contains("A_NOTE")); checkTrue(combined.contains("B_NOTE")); checkFalse(combined.contains("PRIVATE_OTHER_COURSE"))
        checkFalse(combined.contains(a.segments[0].english))
        let withOriginal = try String(contentsOf: second.directory.appendingPathComponent("全部笔记.md"), encoding: .utf8)
        checkTrue(withOriginal.contains(a.segments[0].english)); checkTrue(withOriginal.contains(a.segments[0].chinese))
        checkTrue(combined.range(of: "A_NOTE")!.lowerBound < combined.range(of: "B_NOTE")!.lowerBound)
        let index = try String(contentsOf: first.directory.appendingPathComponent("课程索引.md"), encoding: .utf8)
        for file in files where file.lastPathComponent.hasPrefix("00") {
            checkTrue(index.contains(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        }
        checkEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".classnote") }.count, 0)
    }
    func testCourseExportCombinedPrecedenceAndIncompleteLabels() throws {
        var lecture = fixtureLecture(); lecture.notes = "Plain note"
        let material = Courseware(name: "Slides.pdf", byteCount: 1, pages: [.init(number: 1, text: "Source text")]); lecture.courseware = material
        lecture.combinedNote = CombinedNote(markdown: "Bound note [课件 p.1]", source: material.source, transcript: lecture.transcript)
        let md = CourseNotesExport.content(lecture, includeOriginal: false)
        checkTrue(md.contains("Bound note")); checkTrue(md.contains("Slides.pdf")); checkFalse(md.contains("Plain note"))
        lecture.segments[0].english += " changed"
        checkTrue(CourseNotesExport.content(lecture, includeOriginal: false).contains("已变化"))
        lecture.combinedNote?.isPreview = true
        checkTrue(CourseNotesExport.content(lecture, includeOriginal: false).contains("Plain note"))
        checkFalse(CourseNotesExport.content(lecture, includeOriginal: false).contains("Bound note"))
        lecture.notes = ""; lecture.state = .interrupted; lecture.segments.append(TranscriptSegment(offset: 30))
        checkFalse(CourseNotesExport.hasNotes(lecture))
        let incomplete = CourseNotesExport.content(lecture, includeOriginal: false)
        checkTrue(incomplete.contains("尚未生成笔记")); checkTrue(incomplete.contains("1 段英文原稿尚未完成")); checkTrue(incomplete.contains("未正常结束"))
    }
}
