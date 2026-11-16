import AppKit
import ClassnoteCore

extension AppModel {
    var courseGroups: [Course] {
        let sorted = courses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return sorted + [Course.unfiled]
    }
    var selectedCourse: Course? { courseGroups.first { $0.id == selectedCourseID } }
    func records(in course: Course) -> [Lecture] { Course.records(in: course, courses: courses, lectures: lectures) }
    func selectCourse(_ course: Course) {
        selectedID = nil; selectedCourseID = course.id; isPreparingLecture = false
        if expandedCourseIDs.contains(course.id) { expandedCourseIDs.remove(course.id) }
        else { expandedCourseIDs = [course.id] }
    }
    func prepareLecture(in course: Course? = nil) {
        let explicit = course != nil
        let course = course ?? selectedCourse
        draftCourseID = course?.id ?? Course.unfiled.id
        courseTitle = ""; selectedID = nil; isPreparingLecture = true
        draftUsesSchedule = false; draftCourseWasChosen = explicit
        if !explicit { matchScheduleNow() }
    }
    @discardableResult func saveCourse(_ course: Course?, name: String) -> Bool {
        guard courseCatalogAvailable, let store else { return false }
        do {
            let clean = try Course.validatedName(name)
            guard !courses.contains(where: { $0.id != course?.id && $0.name.compare(clean, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) else {
                throw CoursewareFailure("已有同名课程，请直接使用它或换一个名称。")
            }
            var updated = courses
            let value = Course(id: course?.id ?? UUID(), name: clean, createdAt: course?.createdAt ?? Date(), courseware: course?.courseware)
            if let index = updated.firstIndex(where: { $0.id == value.id }) { updated[index] = value }
            else { updated.append(value) }
            try store.saveCourses(updated); courses = updated
            selectedCourseID = value.id; selectedID = nil; isPreparingLecture = false; expandedCourseIDs.insert(value.id)
            draftCourseID = value.id; status = course == nil ? "课程已创建" : "课程名称已更新"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func moveLecture(_ id: UUID, to course: Course) {
        guard courseCatalogAvailable, var lecture = lectures.first(where: { $0.id == id }), let store else { return }
        lecture.courseID = course.id == Course.unfiled.id ? nil : course.id
        do {
            try store.save(lecture); mutate(id) { $0.courseID = lecture.courseID }
            selectedID = id; status = "课堂已移到「\(course.name)」"
        } catch { self.error = "移动未保存，课堂仍在原课程：\(error.localizedDescription)" }
    }
    func canRemoveCourse(_ course: Course) -> Bool {
        course.id != Course.unfiled.id && courseCatalogAvailable && scheduleAvailable && !isStarting && !exportingCourseIDs.contains(course.id)
            && !schedule.events.contains { $0.courseID == course.id }
            && !(lectures + deletedLectures).contains { $0.courseID == course.id }
    }
    func removeEmptyCourse(_ course: Course) {
        guard canRemoveCourse(course), let store else { return }
        do {
            let remaining = courses.filter { $0.id != course.id }
            try store.saveCourses(remaining); courses = remaining
            if selectedCourseID == course.id { selectedCourseID = nil; isPreparingLecture = true }
            if draftCourseID == course.id { draftCourseID = Course.unfiled.id }
            status = "空课程已移除"
        } catch { self.error = "课程未移除：\(error.localizedDescription)" }
    }
    func canExportCourse(_ course: Course) -> Bool {
        let records = records(in: course)
        return !records.isEmpty && !exportingCourseIDs.contains(course.id) && records.allSatisfy { canDelete($0.id) }
    }
    func exportCourse(_ course: Course, includeOriginal: Bool) {
        guard canExportCourse(course) else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "导出到此处"; panel.message = "选择保存位置。将新建课程笔记文件夹，不覆盖已有文件。"
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let parent = panel.url, self.canExportCourse(course) else { return }
            let records = self.records(in: course); let courses = self.courses
            self.exportingCourseIDs.insert(course.id); self.status = "正在导出「\(course.name)」…"
            Task {
                defer { self.exportingCourseIDs.remove(course.id) }
                let granted = parent.startAccessingSecurityScopedResource()
                defer { if granted { parent.stopAccessingSecurityScopedResource() } }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try CourseNotesExport.write(course: course, courses: courses, lectures: records, parent: parent, includeOriginal: includeOriginal)
                    }.value
                    self.status = "已导出 \(result.count) 次课堂笔记\(result.missingNotes > 0 ? " · \(result.missingNotes) 次尚未生成，已标注" : "")"
                    NSWorkspace.shared.activateFileViewerSelecting([result.directory])
                } catch { self.error = "课程导出失败：\(error.localizedDescription)" }
            }
        }
        if let window = NSApp.mainWindow ?? NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: complete) }
        else { panel.begin(completionHandler: complete) }
    }
}
