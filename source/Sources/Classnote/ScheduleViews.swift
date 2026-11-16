import SwiftUI
import UniformTypeIdentifiers
import ClassnoteCore

struct ScheduleSuggestionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let matches = model.scheduleCandidates(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(model.draftUsesSchedule ? "课表已匹配" : (matches.isEmpty ? "暂无课表匹配" : "课表"), systemImage: "calendar.badge.clock")
                        .help("匹配正在进行或 10 分钟内开始的课堂；可在上方手动选择所属课程。")
                    Spacer()
                    Button { model.draftCourseWasChosen = false; model.matchScheduleNow() } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                        .buttonStyle(.plain).foregroundStyle(Palette.dim).disabled(model.isStarting)
                        .help("重新匹配当前课表").accessibilityLabel("重新匹配当前课表")
                    if model.schedule.sources.isEmpty {
                        Button { model.openSchedulePreferences() } label: { Image(systemName: "calendar.badge.plus").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).foregroundStyle(Palette.dim).help("导入日历订阅、文件或课表截图").accessibilityLabel("导入课表")
                    }
                }
                if !matches.isEmpty {
                    ForEach(matches.prefix(5)) { event in
                        let name = model.courses.first { $0.id == event.courseID }?.name
                        HStack {
                            Text(event.title).lineLimit(1)
                            Spacer()
                            Text(event.start.formatted(.dateTime.hour().minute()) + "–" + event.end.formatted(.dateTime.hour().minute()))
                            if let courseID = event.courseID, let name {
                                Button(name) { model.draftCourseID = courseID; model.draftUsesSchedule = false; model.draftCourseWasChosen = true }.buttonStyle(.plain).foregroundStyle(Palette.mint).disabled(model.isStarting)
                            } else { Text("尚未绑定课程").foregroundStyle(.orange) }
                        }
                    }
                    if model.schedule.suggestedCourse(at: context.date, courses: model.courses) == nil {
                        Label("请选择课程", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            .help("课表存在重叠时段或尚未绑定的课程，请在上方选择本次所属课程。")
                    }
                }
            }.font(.system(size: 11)).foregroundStyle(Palette.dim).padding(.horizontal, 4)
        }
    }
}
enum ScheduleEntry: String, CaseIterable, Identifiable {
    case subscription = "日历订阅", ics = "ICS 文件", csv = "CSV 表格", image = "截图识别", manual = "手动添加"
    var id: String { rawValue }
}
struct ScheduleRequest: Identifiable { let id = UUID(); var entry: ScheduleEntry; var source: ScheduleSource? }
struct ScheduleHub: View {
    @ObservedObject var model: AppModel
    @State private var request: ScheduleRequest?
    @State private var showPast = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(ScheduleEntry.allCases) { entry in Button(entry.rawValue) { request = .init(entry: entry) }.buttonStyle(QuietButton()).disabled(!model.scheduleAvailable || !model.courseCatalogAvailable) }
            }
            if !model.scheduleAvailable { Text("课表文件无法读取，原文件保留。修复后重新打开 App；当前不能改写课表。").font(.system(size: 12)).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if model.schedule.sources.isEmpty { Text("暂无课表").font(.system(size: 14)).foregroundStyle(Palette.dim).padding(.vertical, 25) }
                    ForEach(model.schedule.sources) { source in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.name).font(.system(size: 14, weight: .medium))
                                    Text("\(source.kind) · \(model.schedule.events.filter { $0.sourceID == source.id }.count) 次课 · \(source.enabled ? "启用" : "停用")")
                                    Text("范围 \(source.from.formatted(date: .abbreviated, time: .omitted)) – \(source.through.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)) · 更新 \(source.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                }
                                Spacer()
                                Button("查看课程") { request = .init(entry: source.kind == "CSV" ? .csv : .ics, source: source) }.buttonStyle(QuietButton())
                                if source.link != nil { Button("刷新订阅") { request = .init(entry: .subscription, source: source) }.buttonStyle(QuietButton()) }
                                Button(source.enabled ? "停用" : "启用") { model.toggleScheduleSource(source.id) }.buttonStyle(QuietButton()).disabled(!model.scheduleAvailable)
                            }.font(.system(size: 10)).foregroundStyle(Palette.dim)
                        }.padding(16).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack { Text("课堂时段 · 按 Mac 当前时区显示").font(.system(size: 12, weight: .medium)); Spacer(); Toggle("包括历史", isOn: $showPast).toggleStyle(.checkbox).font(.system(size: 11)) }
                    let events = model.schedule.events.filter { showPast || $0.end >= Date() }.sorted { $0.start < $1.start }
                    ForEach(events.prefix(200)) { event in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(event.title).font(.system(size: 13))
                                Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))\(event.location.isEmpty ? "" : " · " + event.location)").font(.system(size: 11)).foregroundStyle(Palette.dim)
                            }
                            Spacer()
                            Text(model.courses.first { $0.id == event.courseID }?.name ?? "尚未绑定").font(.system(size: 11)).foregroundStyle(event.courseID == nil ? .orange : Palette.mint)
                        }.padding(.vertical, 8)
                        Divider().overlay(Palette.line)
                    }
                    if events.count > 200 { Text("显示前 200 次课，全部时段均参与匹配。请在来源中查看课程。").font(.system(size: 11)).foregroundStyle(Palette.dim) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).foregroundStyle(.white)
            .sheet(item: $request) { req in ScheduleImportView(model: model, request: req) }
    }
}

struct ScheduleImportView: View {
    private static let automaticCourseID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    @ObservedObject var model: AppModel
    let request: ScheduleRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""
    @State private var zoneID = TimeZone.current.identifier
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
    @State private var through = Calendar.current.date(byAdding: .day, value: 180, to: Date())!
    @State private var file: URL?
    @State private var draft: ScheduleDraft?
    @State private var overrides: [String: UUID] = [:]
    @State private var message: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?
    @State private var ocr = ""
    @State private var title = ""
    @State private var location = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var weekly = false
    @State private var existingOnly = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(draft == nil ? request.entry.rawValue : "自动识别课程").font(.system(size: 23, weight: .medium))
                Spacer(); if working { ProgressView().controlSize(.small) }
                Button(working ? "取消读取" : "取消") { task?.cancel(); dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let draft { preview(draft) } else { input }
        }.padding(26).frame(width: 760, height: 590).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear(perform: initialize).onDisappear { task?.cancel() }
    }
    @ViewBuilder private var input: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("课表来源名称，例如 秋季学期", text: $name).textFieldStyle(.roundedBorder)
                HStack { DatePicker("开始日期", selection: $from, displayedComponents: .date); DatePicker("截止日期（含）", selection: $through, displayedComponents: .date) }
                HStack {
                    TextField("默认时区，例如 Europe/London", text: $zoneID).textFieldStyle(.roundedBorder)
                    Button("使用本机时区") { zoneID = TimeZone.current.identifier }.buttonStyle(QuietButton())
                }
                Text("ICS 的明确时区优先；CSV 和无时区的日历时间使用此时区。导入范围最多 370 天。").font(.system(size: 11)).foregroundStyle(Palette.dim)
                if request.entry == .subscription {
                    SecureField("粘贴 HTTPS / webcal 日历订阅链接", text: $link).textFieldStyle(.roundedBorder)
                    Text("使用日历的订阅地址，不是网页登录页。链接仅保存在本机供手动刷新；每次刷新先预览再替换这个来源的时段。").font(.system(size: 12)).foregroundStyle(Palette.dim).lineSpacing(4)
                } else if request.entry == .ics || request.entry == .csv {
                    Button(file == nil ? "选择 \(request.entry == .ics ? "ICS" : "CSV") 文件…" : file!.lastPathComponent) {
                        model.chooseScheduleFile(types: request.entry == .ics ? [UTType(filenameExtension: "ics") ?? .data] : [.commaSeparatedText]) { file = $0 }
                    }.buttonStyle(QuietButton())
                    if request.entry == .csv {
                        Text("CSV 列名：title,start,end,timezone,location\n例如：Economics,2026-11-12 09:00,2026-11-12 10:00,Europe/London,Room A\n每行一次课堂；日期为 YYYY-MM-DD HH:mm；UTF-8，可省略后两列。").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.dim).textSelection(.enabled)
                    }
                } else {
                    if request.entry == .image {
                        Button("选择课表截图并识别文字…") { model.chooseScheduleFile(types: [.png,.jpeg,.heic]) { url in readImage(url) } }.buttonStyle(QuietButton())
                        if !ocr.isEmpty { Text(ocr).font(.system(size: 12)).foregroundStyle(Palette.dim).textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 8)) }
                        Text("本机识别，不上传截图。当前需根据文字逐项确认日期和时间；不会自动猜测二维周表位置。每次添加一项，可开启每周重复。").font(.system(size: 11)).foregroundStyle(Palette.dim)
                    }
                    TextField("课程／日历事件名称", text: $title).textFieldStyle(.roundedBorder)
                    DatePicker("开始", selection: $start, displayedComponents: [.date,.hourAndMinute])
                    DatePicker("结束", selection: $end, displayedComponents: [.date,.hourAndMinute])
                    Text("手动日期选择器按 Mac 当前时区显示；保存为绝对时刻。").font(.system(size: 10)).foregroundStyle(Palette.dim)
                    Toggle("每周同一时间重复，到上方截止日期", isOn: $weekly)
                    TextField("地点（可选）", text: $location).textFieldStyle(.roundedBorder)
                }
            }.disabled(working)
        }
        HStack { Spacer(); Button(request.entry == .subscription ? "读取订阅并预览" : "预览课程归组") { read() }.buttonStyle(SilverButton()).disabled(working || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    }
    private func preview(_ draft: ScheduleDraft) -> some View {
        let groups = ScheduleBook.courseGroups(draft.events)
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(draft.source.name) · 自动识别 \(groups.count) 门课程、\(draft.events.count) 个时段 · 按 Mac 当前时区显示").font(.system(size: 12)).foregroundStyle(Palette.dim)
            if request.source != nil && !existingOnly {
                let before = model.schedule.events.filter { $0.sourceID == draft.source.id }
                let old = Set(before.map(\.id)), new = Set(draft.events.map(\.id))
                Text("此来源原有 \(before.count) 次；新增 \(new.subtracting(old).count) 次，移除／移出范围 \(old.subtracting(new).count) 次。确认后替换时段；已有课堂记录保留。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if draft.events.isEmpty { Text("范围内没有课堂。若这是刷新，确认会清除此来源原有时段；可返回调整日期。").font(.system(size: 12)).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 9) {
                            Text(group.identity.name).font(.system(size: 14, weight: .medium))
                            Text("\(group.events.count) 个上课时段 · 自动建立为一个一级课程菜单").font(.system(size: 10)).foregroundStyle(Palette.mint)
                            let eventTitles = Array(Set(group.events.map(\.title))).sorted()
                            ForEach(eventTitles, id: \.self) { eventTitle in
                                Text(eventTitle).font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(2)
                            }
                            if !model.courses.isEmpty {
                                Picker("需要时更改归属", selection: Binding(get: { overrides[group.id] ?? Self.automaticCourseID }, set: { value in
                                    if value == Self.automaticCourseID { overrides.removeValue(forKey: group.id) } else { overrides[group.id] = value }
                                })) {
                                    Text("自动归组").tag(Self.automaticCourseID)
                                    ForEach(model.courses) { Text($0.name).tag($0.id) }
                                }
                            }
                            ForEach(group.events.prefix(4)) { e in
                                Text("\(e.start.formatted(date: .abbreviated, time: .shortened)) – \(e.end.formatted(date: .omitted, time: .shortened))\(e.location.isEmpty ? "" : " · " + e.location) · 源时区 \(e.timeZoneID)").font(.system(size: 11)).foregroundStyle(Palette.dim)
                            }
                        }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                    }
                    ForEach(Array(draft.warnings.prefix(30).enumerated()), id: \.offset) { _,warning in Text(warning).font(.system(size: 11)).foregroundStyle(.orange) }
                }
            }
            Text("确认后课程名称显示为侧栏一级菜单；不同 Lecture／Seminar 和日期都归入同一课程。停课／调课只更新课表，不移动已录制的课堂。").font(.system(size: 11)).foregroundStyle(Palette.dim)
            HStack {
                if !existingOnly { Button("返回调整") { self.draft = nil }.buttonStyle(QuietButton()) }
                Spacer()
                Button(existingOnly ? "保存自动归组" : "确认并建立课程菜单") { if model.commitSchedule(draft, overrides: overrides) { dismiss() } else { message = model.error } }.buttonStyle(SilverButton()).disabled(!model.scheduleAvailable)
            }
        }
    }
    private func initialize() {
        name = request.source?.name ?? request.entry.rawValue
        if let source = request.source {
            link = source.link ?? ""; zoneID = source.defaultTimeZoneID ?? TimeZone.current.identifier; from = source.from; through = source.through.addingTimeInterval(-1)
            if request.entry != .subscription {
                existingOnly = true
                display(.init(source: source, events: model.schedule.events.filter { $0.sourceID == source.id }, warnings: [], baseline: model.schedule))
            }
        }
    }
    private func display(_ value: ScheduleDraft) {
        draft = value; overrides = [:]
    }
    private func readImage(_ url: URL) {
        working = true; message = nil
        task = Task { defer { working = false }; do { let text = try await model.scheduleImageText(url); try Task.checkCancellation(); ocr = text; if text.isEmpty { message = "没有识别出文字，可换清晰截图或手动添加。" } } catch is CancellationError {} catch { message = "截图识别失败，可改用手动添加。" } }
    }
    private func read() {
        message = nil; working = true
        task = Task {
            defer { working = false }
            do {
                guard let zone = TimeZone(identifier: zoneID) else { throw CoursewareFailure("时区无效，例如 Europe/London 或 Asia/Shanghai。") }
                let begin = Calendar.current.startOfDay(for: from), finish = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: through))!
                try ScheduleImporter.range(from: begin, through: finish)
                var source = ScheduleSource(id: request.source?.id ?? UUID(), name: try Course.validatedName(name), kind: request.entry == .csv ? "CSV" : request.entry.rawValue, from: begin, through: finish)
                source.enabled = request.source?.enabled ?? true; source.defaultTimeZoneID = zone.identifier
                if request.entry == .subscription {
                    source.link = try ScheduleImporter.subscriptionURL(link).absoluteString
                    let data = try await model.readSubscription(link); try Task.checkCancellation()
                    let result = try await model.makeScheduleDraft(data: data, kind: "ICS", source: source, zone: zone); try Task.checkCancellation(); display(result)
                } else if request.entry == .csv || request.entry == .ics {
                    guard let file else { throw CoursewareFailure("请先选择文件。") }
                    let granted = file.startAccessingSecurityScopedResource(); defer { if granted { file.stopAccessingSecurityScopedResource() } }
                    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= ScheduleImporter.maximumBytes else { throw CoursewareFailure("文件超过 5 MB。") }
                    let data = try Data(contentsOf: file)
                    let result = try await model.makeScheduleDraft(data: data, kind: request.entry == .csv ? "CSV" : "ICS", source: source, zone: zone); try Task.checkCancellation(); display(result)
                } else {
                    guard start < end, end.timeIntervalSince(start) <= 86400 else { throw CoursewareFailure("结束时间需晚于开始，且课长不超过 24 小时。") }
                    guard start >= begin, start < finish else { throw CoursewareFailure("首次上课日期需在上方导入范围内。") }
                    let clean = try Course.validatedName(title)
                    var values: [ScheduleEvent] = [], a = start, b = end
                    while a < finish {
                        if b > begin { values.append(.init(id: source.id.uuidString + "|" + String(Int(a.timeIntervalSince1970)), sourceID: source.id, title: clean, start: a, end: b, timeZoneID: TimeZone.current.identifier, location: location)) }
                        if !weekly { break }; a = Calendar.current.date(byAdding: .day, value: 7, to: a)!; b = Calendar.current.date(byAdding: .day, value: 7, to: b)!
                    }
                    display(.init(source: source, events: values, warnings: [], baseline: model.schedule))
                }
            } catch is CancellationError {} catch { message = error.localizedDescription }
        }
    }
}
