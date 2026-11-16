import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func testEmptyTrashDeletesConfirmedAssetsAndPreservesEverythingElse() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try LectureStore(root: root)
        var deleted = fixtureLecture(); deleted.title = "Discarded fixture"
        let other = fixtureLecture()
        try store.save(deleted); try store.save(other)
        _ = try store.saveAudio(Data(repeating: 4, count: 4800), lectureID: deleted.id, segmentID: UUID())
        let materials = store.directory(deleted.id).appendingPathComponent("Materials")
        try fm.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data("synthetic PDF".utf8).write(to: materials.appendingPathComponent("sample.pdf"))
        try store.moveToTrash(deleted.id); try store.moveToTrash(other.id)
        // A live session with the same UUID must never be removed by trash cleanup.
        deleted.title = "Keep live version"; try store.save(deleted)
        let liveData = try Data(contentsOf: store.directory(deleted.id).appendingPathComponent("lecture.json"))
        let metadata = root.appendingPathComponent(".schedule.json")
        try Data("private schedule fixture".utf8).write(to: metadata)
        let result = try store.emptyTrash(confirmedIDs: [deleted.id, deleted.id])
        checkEqual(Set(result.removed), [deleted.id]); checkTrue(result.failed.isEmpty)
        checkFalse(fm.fileExists(atPath: store.trashRoot.appendingPathComponent(deleted.id.uuidString).path))
        checkEqual(try store.loadTrash().lectures.map(\.id), [other.id])
        checkEqual(try Data(contentsOf: store.directory(deleted.id).appendingPathComponent("lecture.json")), liveData)
        checkEqual(try String(contentsOf: metadata, encoding: .utf8), "private schedule fixture")
        let repeated = try store.emptyTrash(confirmedIDs: [deleted.id])
        checkEqual(repeated.removed, [deleted.id]); checkTrue(repeated.failed.isEmpty)
    }

    func testEmptyTrashReportsPartialFailureWithoutFollowingSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try LectureStore(root: root)
        let keep = fixtureLecture(), remove = fixtureLecture()
        try store.save(keep); try store.save(remove); try store.moveToTrash(remove.id)
        let original = try Data(contentsOf: store.directory(keep.id).appendingPathComponent("lecture.json"))
        try fm.createSymbolicLink(at: store.trashRoot.appendingPathComponent(keep.id.uuidString), withDestinationURL: store.directory(keep.id))
        let result = try store.emptyTrash(confirmedIDs: [keep.id, remove.id])
        checkEqual(result.removed, [remove.id]); checkEqual(result.failed, [keep.id])
        checkEqual(try Data(contentsOf: store.directory(keep.id).appendingPathComponent("lecture.json")), original)
    }

    func testEmptyTrashRejectsRedirectedTrashRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let store = try LectureStore(root: root)
        let keep = fixtureLecture(); try store.save(keep)
        try fm.createSymbolicLink(at: store.trashRoot, withDestinationURL: root)
        do { _ = try store.emptyTrash(confirmedIDs: [keep.id]); checkTrue(false) } catch {}
        checkEqual(try store.load().lectures.map(\.id), [keep.id])
    }
}
