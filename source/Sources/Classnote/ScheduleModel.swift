import AppKit
import UniformTypeIdentifiers
import Vision
import ImageIO
import ClassnoteCore

struct ScheduleDraft: Identifiable {
    let id = UUID()
    var source: ScheduleSource
    var events: [ScheduleEvent]
    var warnings: [String]
    var baseline: ScheduleBook
}
extension AppModel {
    func scheduleCandidates(at date: Date = Date()) -> [ScheduleEvent] { schedule.candidates(at: date, courses: courses) }
    func matchScheduleNow() {
        guard !isStarting else { return }
        let suggestion = schedule.suggestedCourse(at: Date(), courses: courses)
        if let suggestion { draftCourseID = suggestion; draftUsesSchedule = true; status = "已按课表预选课程，可手动更改" }
        else { draftUsesSchedule = false; if !draftCourseWasChosen && !scheduleCandidates().isEmpty { draftCourseID = Course.unfiled.id }; status = scheduleCandidates().isEmpty ? "当前没有匹配课表，可手动选择课程" : "课表存在重叠或未绑定课程，请手动选择" }
    }
    func saveScheduleBook(_ value: ScheduleBook) -> Bool {
        guard scheduleAvailable, let store else { return false }
        do { try store.saveSchedule(value); schedule = value; return true }
        catch { self.error = "课表保存失败，原数据保留：\(error.localizedDescription)"; return false }
    }
    func toggleScheduleSource(_ id: UUID) {
        var value = schedule
        guard let index = value.sources.firstIndex(where: { $0.id == id }) else { return }
        value.sources[index].enabled.toggle()
        if saveScheduleBook(value) { status = value.sources[index].enabled ? "已启用该课表" : "已停用该课表，历史课堂保留" }
    }
    func applyScheduleGrouping(_ value: ScheduleBook, overrides: [String: UUID] = [:]) -> Bool {
        guard scheduleAvailable, courseCatalogAvailable, let store else { return false }
        var protected = Set((lectures + deletedLectures).compactMap(\.courseID))
        // Unreadable session files can still reference any existing course.
        if preserveAllScheduleCourses { protected.formUnion(courses.map(\.id)) }
        let result = value.groupingCourses(courses, protectedIDs: protected, overrides: overrides)
        guard result.book != schedule || result.courses != courses else { return true }
        do {
            try store.saveScheduleGrouping(result)
            courses = result.courses; schedule = result.book
            if let id = selectedCourseID, let target = result.redirects[id] { selectedCourseID = target }
            if let target = result.redirects[draftCourseID] { draftCourseID = target }
            expandedCourseIDs = Set(expandedCourseIDs.map { result.redirects[$0] ?? $0 })
            return true
        } catch {
            scheduleAvailable = false; courseCatalogAvailable = false
            self.error = "课程归组保存未完成，恢复文件已保留。请重新打开 App 继续恢复；课堂记录不受影响。"
            return false
        }
    }
    func commitSchedule(_ draft: ScheduleDraft, overrides: [String: UUID] = [:]) -> Bool {
        guard draft.baseline == schedule else { error = "课表在预览期间已变化，请重新读取后导入。"; return false }
        var value = schedule
        value.events.removeAll { $0.sourceID == draft.source.id }
        value.sources.removeAll { $0.id == draft.source.id }; value.sources.append(draft.source)
        value.events += draft.events
        guard applyScheduleGrouping(value, overrides: overrides) else { return false }
        let count = Set(schedule.events.filter { $0.sourceID == draft.source.id }.compactMap(\.courseID)).count
        status = "已自动归入 \(count) 门课程 · 记住 \(draft.events.count) 个时段"
        if isPreparingLecture && !draftCourseWasChosen { matchScheduleNow() }
        return true
    }
    func makeScheduleDraft(data: Data, kind: String, source: ScheduleSource, zone: TimeZone) async throws -> ScheduleDraft {
        let baseline = schedule
        let result = try await Task.detached(priority: .userInitiated) {
            if kind == "CSV" { return try ScheduleImporter.csv(data, source: source, defaultZone: zone) }
            return try ScheduleImporter.ics(data, source: source, defaultZone: zone)
        }.value
        var merged = baseline; merged.replace(source, with: result.events)
        return .init(source: source, events: merged.events.filter { $0.sourceID == source.id }, warnings: result.warnings, baseline: baseline)
    }
    func readSubscription(_ text: String) async throws -> Data {
        let url = try ScheduleImporter.subscriptionURL(text)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 35
        config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url?.scheme == "https" else {
                throw CoursewareFailure("订阅没有返回可用日历。请使用学校提供的直接 ICS 订阅链接。")
            }
            guard response.expectedContentLength <= ScheduleImporter.maximumBytes else { throw CoursewareFailure("订阅文件超过 5 MB。") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > ScheduleImporter.maximumBytes { throw CoursewareFailure("订阅文件超过 5 MB。") }
                try Task.checkCancellation()
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as CoursewareFailure { throw error }
        catch { throw CoursewareFailure("读取订阅失败。请检查网络、订阅有效性或改用 ICS 文件；已有课表未改变。") }
    }
    func chooseScheduleFile(types: [UTType], completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let done: (NSApplication.ModalResponse) -> Void = { response in if response == .OK, let url = panel.url { completion(url) } }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }
    func scheduleImageText(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary) else {
                throw CoursewareFailure("请选择 20 MB 内的 PNG、JPEG 或 HEIC 图片。")
            }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-GB", "zh-Hans"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
