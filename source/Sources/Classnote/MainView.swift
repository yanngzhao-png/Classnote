import SwiftUI
import ClassnoteCore

enum Palette {
    static let bg = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let panel = Color(red: 0.075, green: 0.080, blue: 0.094)
    static let dim = Color.white.opacity(0.42)
    static let line = Color.white.opacity(0.09)
    static let mint = Color(red: 0.66, green: 0.91, blue: 0.81)
}
struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    @State private var renaming: Lecture?
    @State private var courseEditor: CourseEditorRequest?
    @State private var exportingCourse: Course?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 0) {
            if !model.sidebarCollapsed {
                sidebar.frame(width: 238).transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(Palette.line).frame(width: 1)
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                if let message = model.error {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(message).font(.system(size: 12)).textSelection(.enabled)
                        Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(14).background(Color.orange.opacity(0.09))
                }
                if let l = model.selected {
                    lecture(l)
                } else if !model.isPreparingLecture, let course = model.selectedCourse {
                    CourseOverview(model: model, course: course, editCourse: { courseEditor = .init(course: course) }, exportCourse: { exportingCourse = course })
                } else { welcome }
                footer
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.sidebarCollapsed)
        .background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(item: $renaming) { lecture in RenameLectureView(model: model, lecture: lecture) }
        .sheet(item: $courseEditor) { request in CourseEditorView(model: model, course: request.course) }
        .sheet(item: $exportingCourse) { course in CourseExportView(model: model, course: course) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 29, weight: .light))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Classnote").font(.system(size: 19, weight: .semibold, design: .rounded))
                }
            }.padding(.top, 42).padding(.horizontal, 23).padding(.bottom, 32)
            Button { model.prepareLecture() } label: {
                HStack { Image(systemName: "plus"); Text("新课堂"); Spacer(); Text("⌘N").foregroundStyle(Palette.dim) }.padding(12)
            }.buttonStyle(.plain).background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 15).keyboardShortcut("n")
            HStack {
                Text("课程 / 课堂记录").tracking(0.7)
                Spacer()
                Button { courseEditor = .init(course: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.plain).help("新建课程").accessibilityLabel("新建课程").disabled(!model.courseCatalogAvailable)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.dim).padding(.horizontal, 23).padding(.top, 28).padding(.bottom, 12)
            ScrollView {
                CourseTree(model: model, renameLecture: { renaming = $0 }, editCourse: { courseEditor = .init(course: $0) }, exportCourse: { exportingCourse = $0 })
            }
            Button { model.showSettings = true } label: {
                HStack { Label("设置", systemImage: "gearshape"); Spacer(); Text("⌘,").foregroundStyle(Palette.dim) }
                    .contentShape(Rectangle())
            }.keyboardShortcut(",").buttonStyle(.plain).font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6)).padding(.horizontal, 23).padding(.vertical, 16)
        }.background(Color.black.opacity(0.15))
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showsWorkspace: true)
            headerRow(showsWorkspace: false)
        }.padding(.horizontal, 30).padding(.top, 32).padding(.bottom, 20)
    }
    private func headerRow(showsWorkspace: Bool) -> some View {
        HStack(spacing: 12) {
            Button { model.sidebarCollapsed.toggle() } label: { Image(systemName: "sidebar.left").font(.system(size: 14)).foregroundStyle(Palette.dim) }
                .buttonStyle(.plain).help(model.sidebarCollapsed ? "展开侧栏（⌃⌘S）" : "收起侧栏（⌃⌘S）")
                .accessibilityLabel(model.sidebarCollapsed ? "展开侧栏" : "收起侧栏")
            Spacer()
            TuitionIndicator(model: model).fixedSize()
            if model.activeID != nil {
                HStack(spacing: 7) { Circle().fill(model.isRecording ? Palette.mint : .orange).frame(width: 5, height: 5); Text(model.isRecording ? "LIVE" : "PAUSED") }
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
                Text(model.elapsed).font(.system(size: 12, design: .monospaced)).fixedSize()
            }
            Button { model.showMini?() } label: { Image(systemName: "pip") }.buttonStyle(QuietButton()).help("打开边缘播放器").accessibilityLabel("打开边缘播放器")
        }
    }
    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    OrbitView(level: model.level, active: false).frame(width: 130, height: 130)
                    Text("Stay in the moment.")
                        .font(.system(size: 36, weight: .light, design: .rounded))
                        .multilineTextAlignment(.center)
                    if let active = model.active {
                        Button { model.selectedID = active.id } label: {
                            Label("回到正在进行的课堂", systemImage: "arrow.right")
                        }.buttonStyle(SilverButton())
                    } else {
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(model.courseGroups) { course in
                                    Button {
                                        model.draftCourseID = course.id
                                        model.draftUsesSchedule = false
                                        model.draftCourseWasChosen = true
                                    } label: {
                                        if model.draftCourseID == course.id {
                                            Label(course.name, systemImage: "checkmark")
                                        } else { Text(course.name) }
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(Palette.mint)
                                    Text(model.courseGroups.first { $0.id == model.draftCourseID }?.name ?? "选择课程")
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.dim)
                                }.padding(.horizontal, 14).padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
                                    .contentShape(Rectangle())
                            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true)
                                .disabled(model.isStarting).help("选择本次课堂所属课程；日历匹配后也可手动更改。")
                                .accessibilityLabel("所属课程")
                            Button { courseEditor = .init(course: nil) } label: {
                                Image(systemName: "folder.badge.plus").frame(width: 20, height: 20)
                            }.buttonStyle(QuietButton()).help("新建课程").accessibilityLabel("新建课程")
                                .disabled(model.isStarting || !model.courseCatalogAvailable)
                        }
                        ScheduleSuggestionView(model: model)
                        HStack(spacing: 12) {
                            Button { model.start() } label: { Label(model.isStarting ? "正在连接…" : "开始听课", systemImage: "mic.fill") }.buttonStyle(SilverButton()).disabled(model.isStarting)
                                .help("开始麦克风收音；课堂名称默认为日期，点击课堂页顶部标题可修改。")
                            Button { model.start(demo: true) } label: { Label("体验演示", systemImage: "play.circle") }.buttonStyle(QuietButton()).disabled(model.isStarting)
                                .help("使用合成课堂内容体验字幕，不录音、不调用 API。")
                        }
                        Button("体验原稿与课件关联 →") { model.openBindingDemo(); tab = 1 }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.mint).disabled(model.isStarting)
                            .help("查看合成课堂原稿与 PDF 页码的关联示例。")
                    }
                }.frame(maxWidth: 620).padding(.horizontal, 32).padding(.vertical, 32)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
    private func lecture(_ l: Lecture) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text((model.selectedCourse?.name ?? "未分类课堂") + (l.isDemo ? " / DEMO SESSION" : " / CLASS SESSION")).font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(Palette.dim)
                    EditableLectureTitle(model: model, lecture: l).id(l.id)
                    Text(l.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                Spacer()
                if model.activeID == l.id {
                    Button { model.togglePause() } label: { Image(systemName: model.isRecording ? "pause.fill" : "play.fill").frame(width: 20) }.buttonStyle(QuietButton()).disabled(model.ending || model.isStarting).help("暂停或继续收音")
                    Button { model.end(); tab = 1 } label: { Label(model.ending ? "整理中…" : "结束课堂", systemImage: "stop.fill") }.buttonStyle(SilverButton()).disabled(model.ending || model.isStarting)
                }
            }.padding(.horizontal, 30).padding(.top, 12).padding(.bottom, 25)
            if model.activeID != l.id { NotionArchiveStatus(model: model, lecture: l).padding(.horizontal, 30).padding(.bottom, 8) }
            HStack(spacing: 22) {
                tabButton("实时原稿", index: 0); tabButton("课堂笔记", index: 1); tabButton("课件", index: 2)
                Spacer()
                if l.segments.contains(where: { $0.state == .failed || $0.state == .transcribed }) && !l.isDemo {
                    Button(model.retrying.contains(l.id) ? "正在重试…" : "重试未完成段落") { model.retry(l.id) }.buttonStyle(.plain).font(.system(size: 11)).disabled(model.retrying.contains(l.id))
                }
                Button { model.copyNotes(combined: tab != 0 && (l.courseware != nil || l.combinedNote != nil)) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help(tab != 0 && (l.courseware != nil || l.combinedNote != nil) ? "复制关联笔记、课件来源与双语原稿" : "复制笔记与双语原稿（Markdown）").disabled(tab != 0 && l.courseware != nil && l.combinedNote == nil)
                Button { model.export(combined: tab != 0 && (l.courseware != nil || l.combinedNote != nil)) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain).help("导出 Markdown 文件").disabled(tab != 0 && l.courseware != nil && l.combinedNote == nil)
            }.padding(.horizontal, 30).padding(.bottom, 14)
            Rectangle().fill(Palette.line).frame(height: 1)
            if tab == 0 {
                TranscriptView(segments: l.orderedSegments, draft: model.activeID == l.id ? model.draft : "", fontSize: 18, bilingual: true, compact: false)
            } else if tab == 2 {
                CoursewareView(model: model, lecture: l, showsNotes: false, openNotes: { tab = 1 }).id(l.id)
            } else if l.courseware != nil || l.combinedNote != nil {
                CoursewareView(model: model, lecture: l).id(l.id)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            if model.busyNotes.contains(l.id) { ProgressView().controlSize(.small); Text("正在整理概念、例子和复习要点…").font(.system(size: 12)).foregroundStyle(Palette.dim) }
                            else if model.activeID != l.id { Button(l.notes.isEmpty ? "生成课堂笔记" : "重新整理") { model.generateNotes(l.id) }.buttonStyle(QuietButton()) }
                            Spacer()
                        }
                        if let error = l.noteError { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
                        if l.notes.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "text.book.closed").font(.system(size: 34, weight: .ultraLight))
                                Text("暂无课堂笔记") .font(.system(size: 18, weight: .light))
                            }.padding(.top, 35)
                        } else { MarkdownNotes(text: l.notes) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
                }
            }
        }
    }
    private func tabButton(_ title: String, index: Int) -> some View {
        Button { tab = index } label: { Text(title).font(.system(size: 12, weight: tab == index ? .semibold : .regular)).foregroundStyle(tab == index ? .white : .white.opacity(0.4)) }.buttonStyle(.plain)
    }
    private var footer: some View {
        Group {
            if model.activeID != nil || model.error != nil || model.lastDeletedID != nil {
                HStack(spacing: 8) {
                    Circle().fill(model.isRecording ? Palette.mint : Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    if !model.status.isEmpty { Text(model.status).font(.system(size: 10)).lineLimit(2) }
                    if let id = model.lastDeletedID {
                        Button("撤销删除") { model.restoreLecture(id) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.mint)
                    }
                    Spacer()
                }.foregroundStyle(Palette.dim).padding(.horizontal, 30).padding(.vertical, 10).background(Color.black.opacity(0.12))
            }
        }
    }
}
struct EditableLectureTitle: View {
    @ObservedObject var model: AppModel
    let lecture: Lecture
    @State private var editing = false
    @State private var title = ""
    @FocusState private var focused: Bool
    private var valid: Bool {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !clean.isEmpty && clean.count <= 120 && !clean.contains("\n") && !clean.contains("\r")
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if editing {
                TextField("课堂名称", text: $title).textFieldStyle(.plain).focused($focused)
                    .onSubmit(save).onExitCommand { editing = false }
                    .accessibilityLabel("课堂名称")
                    .task { focused = true }
                Button(action: save) { Image(systemName: "checkmark").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.mint)
                    .disabled(!valid).help("保存名称（回车）").accessibilityLabel("保存课堂名称")
                Button { editing = false } label: { Image(systemName: "xmark").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Palette.dim)
                    .help("取消编辑（Esc）").accessibilityLabel("取消编辑课堂名称")
            } else {
                Button {
                    title = model.lectureTitle(lecture)
                    editing = true
                } label: {
                    Text(model.lectureTitle(lecture)).lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("点击编辑课堂名称").accessibilityLabel("编辑课堂名称：\(model.lectureTitle(lecture))")
            }
        }.font(.system(size: 27, weight: .medium)).frame(minHeight: 33, alignment: .leading)
    }
    private func save() {
        guard valid else { return }
        if model.renameLecture(lecture.id, title: title) { editing = false }
    }
}
struct RenameLectureView: View {
    @ObservedObject var model: AppModel
    let lecture: Lecture
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var failed = false
    @FocusState private var focused: Bool
    private var valid: Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 120 && !value.contains("\n") && !value.contains("\r")
    }
    private func save() {
        guard valid else { return }
        if model.renameLecture(lecture.id, title: title) { dismiss() } else { failed = true }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名课堂").font(.system(size: 22, weight: .medium))
            TextField("课堂名称", text: $title).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            if failed { Text(model.error ?? "保存失败，请重试。").font(.system(size: 11)).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(QuietButton()); Button("保存", action: save).keyboardShortcut(.defaultAction).buttonStyle(SilverButton()).disabled(!valid) }
        }.padding(28).frame(width: 450).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear { title = model.lectureTitle(lecture); focused = true }
    }
}
struct DeletedLecturesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    @State private var confirmedIDs: [UUID] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("最近删除").font(.system(size: 22, weight: .medium)); Spacer()
                Button(model.isEmptyingTrash ? "清空中…" : "清空…", role: .destructive) {
                    confirmedIDs = model.deletedLectures.map(\.id); confirmEmpty = true
                }.buttonStyle(QuietButton()).foregroundStyle(.red)
                    .disabled(model.deletedLectures.isEmpty || model.isEmptyingTrash)
                Button("完成") { dismiss() }.buttonStyle(SilverButton()).keyboardShortcut(.cancelAction).disabled(model.isEmptyingTrash)
            }
            if model.unreadableTrashCount > 0 {
                Text("有 \(model.unreadableTrashCount) 份记录无法读取，不包含在本次清空中；可从本地记录文件夹检查。").font(.system(size: 11)).foregroundStyle(.orange)
            }
            if model.deletedLectures.isEmpty {
                Spacer(); Text("没有已删除的课堂").font(.system(size: 14)).foregroundStyle(Palette.dim).frame(maxWidth: .infinity); Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.deletedLectures) { lecture in
                            HStack {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(lecture.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text("\(lecture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(lecture.segments.count) 段原稿\(lecture.isDemo ? " · DEMO" : "")").font(.system(size: 10)).foregroundStyle(Palette.dim)
                                }; Spacer()
                                Button("恢复") { model.restoreLecture(lecture.id) }.buttonStyle(QuietButton()).disabled(model.isEmptyingTrash)
                            }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if let error = model.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(28).frame(width: 540, height: 430).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
            .interactiveDismissDisabled(model.isEmptyingTrash)
            .alert("清空最近删除？", isPresented: $confirmEmpty) {
                Button("取消", role: .cancel) { confirmedIDs = [] }
                Button("永久删除 \(confirmedIDs.count) 条记录", role: .destructive) { model.emptyDeletedLectures(confirmedIDs: confirmedIDs) }
            } message: {
                Text("将永久删除这 \(confirmedIDs.count) 条课堂的原稿、译文、笔记、音频及课件副本，无法恢复。正常课堂、课程目录与课表不受影响。")
            }
    }
}
struct Feature: View {
    let icon: String; let title: String; let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).font(.system(size: 18, weight: .light)); Text(title).font(.system(size: 12, weight: .medium)); Text(text).font(.system(size: 10)).foregroundStyle(Palette.dim).lineSpacing(5) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct SilverButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(Color.black.opacity(0.85)).background(LinearGradient(colors: [.white, Color(white: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.055), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
    }
}
struct OrbitView: View {
    var level: Float; var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.05), lineWidth: 1).padding(2)
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).padding(15)
            Circle().trim(from: 0.04, to: 0.76).stroke(AngularGradient(colors: [.clear, .white.opacity(0.7), .clear], center: .center), style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).padding(15)
                .rotationEffect(.degrees(rotation && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : .linear(duration: 16).repeatForever(autoreverses: false), value: rotation)
            Image(systemName: "waveform").font(.system(size: 31, weight: .ultraLight)).scaleEffect(active ? 1 + Double(level) * 0.15 : 1).animation(.easeOut(duration: 0.2), value: level)
        }.onAppear { rotation = true }.accessibilityHidden(true)
    }
}
struct TranscriptView: View {
    let segments: [TranscriptSegment]; var draft: String; var fontSize: Double; var bilingual: Bool; var compact: Bool
    @State private var following = true
    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: compact ? 20 : 26) {
                        if segments.isEmpty && draft.isEmpty {
                            VStack(alignment: .leading, spacing: 12) { Image(systemName: "waveform").font(.system(size: 26, weight: .ultraLight)); Text("等待课堂的第一个词…").font(.system(size: fontSize)) }.padding(.top, 25)
                        }
                        ForEach(segments) { s in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 7) {
                                    Text(formatTime(s.offset)).font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.dim)
                                    if s.state == .pending { Text("转录中").font(.system(size: 9)).foregroundStyle(Palette.dim) }
                                    if s.state == .transcribed { Text("翻译中").font(.system(size: 9)).foregroundStyle(Palette.dim) }
                                }
                                if !s.english.isEmpty { Text(s.english).font(.system(size: bilingual ? fontSize * 0.77 : fontSize)).foregroundStyle(.white.opacity(bilingual ? 0.55 : 0.92)).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }
                                if bilingual && !s.chinese.isEmpty { Text(s.chinese).font(.system(size: fontSize, weight: .medium)).foregroundStyle(.white.opacity(0.94)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) }
                                if let error = s.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange.opacity(0.85)) }
                            }.id(s.id)
                        }
                        if !draft.isEmpty { Text(draft).font(.system(size: fontSize * 0.77)).foregroundStyle(.white.opacity(0.35)).lineSpacing(5) }
                        Color.clear.frame(height: 1).id("latest")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 20 : 30).textSelection(.enabled)
                }
                .background(ScrollIntentMonitor { following = false })
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size) { _, _ in
                        if following { Task { @MainActor in await Task.yield(); proxy.scrollTo("latest", anchor: .bottom) } }
                    }
                })
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: segments) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: draft) { _, _ in if following { proxy.scrollTo("latest", anchor: .bottom) } }
                .onChange(of: fontSize) { _, _ in if following { Task { @MainActor in await Task.yield(); proxy.scrollTo("latest", anchor: .bottom) } } }
                if !following {
                    Button { following = true; proxy.scrollTo("latest", anchor: .bottom) } label: { Label("回到最新", systemImage: "arrow.down") }
                        .buttonStyle(QuietButton()).background(Palette.panel, in: Capsule()).padding(12)
                }
            }
        }
    }
}
/// Observe only scroll events within this view. Never consumes scrolling from the reader.
struct ScrollIntentMonitor: NSViewRepresentable {
    var onScroll: () -> Void
    func makeNSView(context: Context) -> ScrollMonitorView { let v = ScrollMonitorView(); v.onScroll = onScroll; return v }
    func updateNSView(_ view: ScrollMonitorView, context: Context) { view.onScroll = onScroll }
}
final class ScrollMonitorView: NSView {
    var onScroll: (() -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] e in
            guard let self, let window = self.window, e.window === window else { return e }
            if e.type == .scrollWheel, self.bounds.contains(self.convert(e.locationInWindow, from: nil)), e.scrollingDeltaY > 0 { self.onScroll?() }
            if e.type == .keyDown, [116, 126].contains(e.keyCode) { self.onScroll?() }
            return e
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
struct MarkdownNotes: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") { Text(String(line.dropFirst(3))).font(.system(size: 18, weight: .semibold)).padding(.top, 14) }
                else if line.hasPrefix("# ") { Text(String(line.dropFirst(2))).font(.system(size: 24, weight: .semibold)).padding(.top, 14) }
                else if !line.isEmpty { Text(.init(line)).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineSpacing(6) }
            }
        }.textSelection(.enabled)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var feedback = ""
    @State private var testing = false
    @State private var testingTranscription = false
    @State private var showDeleted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("偏好设置").font(.system(size: 23, weight: .medium)); Spacer(); Button("完成") { model.saveSettings(); dismiss() }.buttonStyle(SilverButton()) }
            Picker("偏好设置分类", selection: $model.settingsSection) {
                Text("模型配置").tag(0)
                Text("自定义偏好").tag(1)
                Text("课表与导入").tag(2)
                Text("Notion").tag(3)
            }.pickerStyle(.segmented)
            if model.settingsSection == 2 {
                ScheduleHub(model: model)
            } else if model.settingsSection == 3 {
                NotionPreferences(model: model)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    if model.settingsSection == 0 {
                    section("OPENAI API")
                    SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder).help("Key 仅保存在这台 Mac 的系统钥匙串")
                    HStack {
                        Button("保存 Key") {
                            do { try Keychain.save(key); feedback = "Key 已保存到系统钥匙串。" } catch { feedback = error.localizedDescription }
                        }.buttonStyle(QuietButton())
                        Button(testing ? "检查中…" : "检查文本模型") {
                            testing = true
                            Task {
                                defer { testing = false }
                                do {
                                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !value.isEmpty else { throw AppFailure("请先填写 API Key。") }
                                    try await OpenAIService(key: value).test(model: model.settings.textModel)
                                    feedback = "API 与文本模型可访问；实际音频转录需开始课堂验证。"
                                } catch { feedback = error.localizedDescription }
                            }
                        }.buttonStyle(QuietButton()).disabled(testing)
                        Button(testingTranscription ? "连接转录中…" : "检查转录连接") {
                            testingTranscription = true
                            Task {
                                let client = RealtimeTranscriber()
                                defer { client.close(); testingTranscription = false }
                                do {
                                    let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !value.isEmpty else { throw AppFailure("请先填写 API Key。") }
                                    try await client.connect(key: value, model: model.settings.realtimeModel, vocabulary: model.settings.vocabulary)
                                    feedback = "\(model.settings.realtimeModel) 转录连接成功。未录音；口音准确率需用实际课堂验证。"
                                } catch { feedback = error.localizedDescription }
                            }
                        }.buttonStyle(QuietButton()).disabled(testingTranscription || model.activeID != nil)
                    }
                    if !feedback.isEmpty { Text(feedback).font(.system(size: 11)).foregroundStyle(Palette.mint).textSelection(.enabled) }
                    section("模型与术语")
                    HStack(spacing: 12) {
                        Button("使用高精度转录") {
                            model.settings.realtimeModel = TranscriptionOptions.accurateModel
                            model.settings.fileModel = TranscriptionOptions.accurateModel
                            model.saveSettings(); feedback = "已设为 gpt-transcribe；下次开始课堂时生效。"
                        }.buttonStyle(QuietButton())
                        EmptyView()
                    }
                    field("实时转录", text: $model.settings.realtimeModel)
                    field("音频重试", text: $model.settings.fileModel)
                    field("翻译 / 笔记", text: $model.settings.textModel)
                    TextField("课程术语，例如 elasticity, opportunity cost", text: $model.settings.vocabulary, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                    } else {
                    section("数据管理")
                    HStack {
                        Button("最近删除 · \(model.deletedLectures.count)") { showDeleted = true }.buttonStyle(QuietButton())
                        Button("本地记录") { model.revealData() }.buttonStyle(QuietButton())
                    }
                    Divider().overlay(Palette.line)
                    TuitionPreferences(model: model)
                    Divider().overlay(Palette.line)
                    section("字幕与收音")
                    HStack { Text("字幕字号"); Spacer(); Button("A−") { model.setFont(-1) }; Text("\(Int(model.settings.fontSize))").monospacedDigit().frame(width: 25); Button("A＋") { model.setFont(1) } }
                    Toggle("显示英文与中文", isOn: $model.settings.bilingual)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("完整收音 · 轻声不丢弃").font(.system(size: 12))
                    }
                    section("本地数据")
                    Text(model.dataDirectory.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.dim).textSelection(.enabled)
                    }
                }
            }
            }
        }.padding(28).frame(width: model.settingsSection >= 2 ? 820 : 590, height: 660).background(Palette.bg).preferredColorScheme(.dark)
            .sheet(isPresented: $showDeleted) { DeletedLecturesView(model: model) }
            .onAppear { do { key = try Keychain.read() } catch { feedback = error.localizedDescription } }
            .onDisappear { model.saveSettings() }
    }
    private func section(_ text: String) -> some View { Text(text).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.white.opacity(0.65)).padding(.top, 4) }
    private func field(_ title: String, text: Binding<String>) -> some View { HStack { Text(title).font(.system(size: 12)).frame(width: 85, alignment: .leading); TextField(title, text: text).textFieldStyle(.roundedBorder) } }
}
