import AppKit
import UniformTypeIdentifiers
import ClassnoteCore

extension AppModel {
    func importCourseMaterial(_ courseID: UUID) {
        guard !importingCourseMaterial.contains(courseID), courseCatalogAvailable, store != nil,
              courses.contains(where: { $0.id == courseID }) else { return }
        importingCourseMaterial.insert(courseID); error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择课前准备的 PDF 课件。下次从这门课开始课堂时会自动带入。"
        panel.prompt = "准备课件"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.importingCourseMaterial.remove(courseID); return }
            Task {
                defer { self.importingCourseMaterial.remove(courseID) }
                do {
                    let imported = try await Task.detached(priority: .userInitiated) { try PDFCoursewareImporter.read(url) }.value
                    guard let store = self.store, var course = self.courses.first(where: { $0.id == courseID }) else { return }
                    try store.saveCourseMaterial(imported, courseID: courseID)
                    course.courseware = imported.courseware
                    var updated = self.courses
                    guard let index = updated.firstIndex(where: { $0.id == courseID }) else { return }
                    updated[index] = course
                    try store.saveCourses(updated)
                    self.courses = updated
                    self.status = imported.courseware.textPages.isEmpty ? "课前课件已准备，但没有可提取文字" : "课前课件已准备 · 下次开始课堂时自动带入"
                } catch { self.error = "课前课件未保存：\(error.localizedDescription)" }
            }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func removeCourseMaterial(_ courseID: UUID) {
        guard !importingCourseMaterial.contains(courseID), let store,
              var course = courses.first(where: { $0.id == courseID }), course.courseware != nil else { return }
        course.courseware = nil
        var updated = courses
        guard let index = updated.firstIndex(where: { $0.id == courseID }) else { return }
        updated[index] = course
        do { try store.saveCourses(updated); courses = updated; status = "已取消下次课堂的课前课件" }
        catch { self.error = "课前课件未取消：\(error.localizedDescription)" }
    }
    func openBindingDemo() {
        let title = "原稿与课件关联 · 演示"
        if let existing = lectures.first(where: { $0.isDemo && $0.title == title && $0.courseware != nil }) {
            selectedID = existing.id; return
        }
        do {
            guard let store, let url = Bundle.main.url(forResource: "Classnote-Economics-Demo", withExtension: "pdf") else {
                throw CoursewareFailure("演示课件未找到，请使用完整 App 安装包。")
            }
            var lecture = Lecture(title: title, isDemo: true)
            lecture.state = .ended; lecture.activeSeconds = 24
            lecture.segments = Self.demoLines.prefix(4).enumerated().map { index, pair in
                TranscriptSegment(offset: Double(index * 6), duration: 6, english: pair.0, chinese: pair.1, state: .translated)
            }
            let material = try PDFCoursewareImporter.read(url)
            try store.saveMaterial(material, lectureID: lecture.id); lecture.courseware = material.courseware
            try store.save(lecture); lectures.insert(lecture, at: 0); selectedID = lecture.id
            status = "演示原稿与课件已准备 · 点击 AI 整理并关联课件开始生成"
        } catch { self.error = error.localizedDescription }
    }
    func importCourseware(_ id: UUID) {
        guard !importingCourseware.contains(id), !busyCombinedNotes.contains(id), lectures.contains(where: { $0.id == id }), store != nil else { return }
        importingCourseware.insert(id); error = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择这堂课的 PDF 课件。文件会复制到本地课堂目录。"
        panel.prompt = "导入课件"
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { self.importingCourseware.remove(id); return }
            Task {
                defer { self.importingCourseware.remove(id) }
                do {
                    let imported = try await Task.detached(priority: .userInitiated) { try PDFCoursewareImporter.read(url) }.value
                    guard var lecture = self.lectures.first(where: { $0.id == id }), let store = self.store else { return }
                    try store.saveMaterial(imported, lectureID: id)
                    lecture.courseware = imported.courseware; lecture.combinedNoteError = nil
                    try store.save(lecture)
                    self.mutate(id) { $0.courseware = imported.courseware; $0.combinedNoteError = nil }
                    self.status = imported.courseware.textPages.isEmpty ? "已保存 PDF，但没有可提取文字；暂不支持扫描页 OCR" : "课件已导入 · \(imported.courseware.textPages.count)/\(imported.courseware.source.pageCount) 页可提取文字"
                } catch { self.error = "导入未完成：\(error.localizedDescription)" }
            }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }
    func removeCourseware(_ id: UUID) {
        guard !importingCourseware.contains(id), !busyCombinedNotes.contains(id), var lecture = lectures.first(where: { $0.id == id }), let store else { return }
        lecture.courseware = nil
        do {
            try store.save(lecture); mutate(id) { $0.courseware = nil }
            status = "已取消选用课件；上次笔记及其 PDF 副本仍保留"
        } catch { self.error = "课件变更未保存：\(error.localizedDescription)" }
    }
    func canGenerateCombined(_ id: UUID) -> Bool {
        guard let lecture = lectures.first(where: { $0.id == id }) else { return false }
        return activeID != id && !busyCombinedNotes.contains(id) && !importingCourseware.contains(id) && !retrying.contains(id)
            && lecture.unfinishedCount == 0 && !lecture.transcript.isEmpty && lecture.courseware?.textPages.isEmpty == false
    }
    func generateCombinedNotes(_ id: UUID) {
        guard canGenerateCombined(id), let lecture = lectures.first(where: { $0.id == id }), let courseware = lecture.courseware else { return }
        busyCombinedNotes.insert(id); combinedProgress[id] = "准备课堂原稿与课件…"
        mutate(id) { $0.combinedNoteError = nil }
        combinedTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.busyCombinedNotes.remove(id); self.combinedProgress[id] = nil; self.combinedTasks[id] = nil; self.enqueueNotionIfReady(id) }
            do {
                let service = try OpenAIService(key: self.requiredKey()); let textModel = self.settings.textModel
                let bindings = try await CombinedNotesEngine.generate(lecture: lecture, courseware: courseware, request: { instructions, input, limit in
                    let schema = instructions == CombinedNotesEngine.instructions ? BoundNotes.schema : nil
                    let result = try await service.text(model: textModel, instructions: instructions, input: input, maxTokens: limit, jsonSchema: schema)
                    self.addUsage(id, result); self.persist(id)
                    return result.text
                }, progress: { self.combinedProgress[id] = $0 })
                try Task.checkCancellation()
                let note = CombinedNote(markdown: bindings.markdown(source: courseware.source), source: courseware.source, transcript: lecture.transcript, bindings: bindings)
                guard var current = self.lectures.first(where: { $0.id == id }), let store = self.store else { return }
                current.combinedNote = note; current.combinedNoteError = nil
                try store.save(current)
                self.mutate(id) { $0.combinedNote = note; $0.combinedNoteError = nil }
                self.status = bindings.reviewCount > 0 ? "课堂笔记已保存 · \(bindings.reviewCount) 处来源待核对" : "AI 关联课堂笔记已保存"
            } catch {
                let message = Task.isCancelled ? "已取消生成；上次结果仍保留。" : error.localizedDescription
                self.mutate(id) { $0.combinedNoteError = message }; self.persist(id)
            }
        }
    }
    func cancelCombinedNotes(_ id: UUID) { combinedTasks[id]?.cancel() }
}
