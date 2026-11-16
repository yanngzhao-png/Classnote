import Foundation

public struct TrashDeletionResult: Sendable {
    public var removed: [UUID] = []
    public var failed: [UUID] = []
}

extension LectureStore {
    /// Delete only the confirmed session IDs inside this store's trash, never live sessions.
    public func emptyTrash(confirmedIDs: [UUID]) throws -> TrashDeletionResult {
        let fm = FileManager.default
        var result = TrashDeletionResult()
        let ids = Set(confirmedIDs)
        guard !ids.isEmpty else { return result }
        if !fm.fileExists(atPath: trashRoot.path) {
            // A dangling symlink must not be treated as an empty trash directory.
            if (try? fm.destinationOfSymbolicLink(atPath: trashRoot.path)) != nil {
                throw CocoaError(.fileWriteNoPermission)
            }
            result.removed = Array(ids); return result
        }
        let values = try trashRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        for id in ids {
            let folder = trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            do {
                if (try? fm.destinationOfSymbolicLink(atPath: folder.path)) != nil {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if fm.fileExists(atPath: folder.path) {
                    let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                    try fm.removeItem(at: folder)
                }
                result.removed.append(id)
            } catch { result.failed.append(id) }
        }
        return result
    }
}
