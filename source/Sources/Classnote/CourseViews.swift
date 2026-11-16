import SwiftUI
import ClassnoteCore

struct CourseEditorRequest: Identifiable {
    let id = UUID()
    var course: Course?
}
struct CourseTree: View {
    @ObservedObject var model: AppModel
    let renameLecture: (Lecture) -> Void
    let editCourse: (Course?) -> Void
    let exportCourse: (Course) -> Void
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.courseGroups) { course in
                let records = model.records(in: course)
                let expanded = model.expandedCourseIDs.contains(course.id)
                VStack(alignment: .leading, spacing: 4) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { model.selectCourse(course) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 10)
                            Image(systemName: course.id == Course.unfiled.id ? "tray" : (course.courseware == nil ? "folder" : "folder.badge.plus")).foregroundStyle(Palette.mint)
                            Text(course.name).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 2)
                            Text("\(records.count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.dim)
                        }.padding(.horizontal, 10).padding(.vertical, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .background(model.selectedCourseID == course.id ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel("课程 \(course.name)，\(records.count) 次课堂，\(expanded ? "已展开" : "已收起")")
                        .contextMenu {
                            Button("在此课程新建课堂") { model.prepareLecture(in: course) }
                            Button("批量导出课程笔记…") { exportCourse(course) }.disabled(!model.canExportCourse(course))
                            if course.id != Course.unfiled.id {
                                Divider()
                                Button("重命名课程…") { editCourse(course) }.disabled(!model.courseCatalogAvailable)
                                Button("移除空课程", role: .destructive) { model.removeEmptyCourse(course) }.disabled(!model.canRemoveCourse(course))
                            }
                        }
                    if expanded {
                        if records.isEmpty { Text("暂无课堂记录").font(.system(size: 10)).foregroundStyle(Palette.dim).padding(.leading, 37).padding(.vertical, 8) }
                        ForEach(records) { lecture in
                            Button { model.selectedID = lecture.id } label: {
                                HStack(alignment: .top, spacing: 7) {
                                    Circle().fill(model.activeID == lecture.id ? Palette.mint : .white.opacity(0.2)).frame(width: 4, height: 4).padding(.top, 5)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.lectureTitle(lecture)).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text("\(lecture.startedAt.formatted(.dateTime.month().day().hour().minute())) · \(formatTime(lecture.activeSeconds))\(lecture.isDemo ? " · DEMO" : "")")
                                            .font(.system(size: 9)).foregroundStyle(Palette.dim)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).padding(.leading, 20)
                                .background(model.selectedID == lecture.id ? Color.white.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                .contextMenu {
                                    Button("重命名课堂…") { renameLecture(lecture) }
                                    Menu("移动到课程") {
                                        ForEach(model.courseGroups) { target in
                                            Button(target.name) { model.moveLecture(lecture.id, to: target) }
                                                .disabled(target.id == course.id || !model.courseCatalogAvailable)
                                        }
                                    }
                                    Divider()
                                    Button("删除课堂记录", role: .destructive) { model.deleteLecture(lecture.id) }.disabled(!model.canDelete(lecture.id))
                                }
                        }
                    }
                }
            }
        }.padding(.horizontal, 12)
    }
}

struct CourseOverview: View {
    @ObservedObject var model: AppModel
    let course: Course
    let editCourse: () -> Void
    let exportCourse: () -> Void
    var body: some View {
        let records = model.records(in: course)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("COURSE / SESSIONS").font(.system(size: 9, weight: .medium)).tracking(2).foregroundStyle(Palette.dim)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(course.name).font(.system(size: 29, weight: .medium))
                        Text("\(records.count) 次课堂 · \(records.filter { CourseNotesExport.hasNotes($0) }.count) 份已生成笔记").font(.system(size: 12)).foregroundStyle(Palette.dim)
                    }
                    Spacer()
                    if course.id != Course.unfiled.id { Button("重命名") { editCourse() }.buttonStyle(QuietButton()) }
                }
                HStack(spacing: 12) {
                    Button { model.prepareLecture(in: course) } label: { Label("新建本课程课堂", systemImage: "plus") }.buttonStyle(SilverButton())
                    Button { exportCourse() } label: { Label(model.exportingCourseIDs.contains(course.id) ? "正在导出…" : "批量导出笔记", systemImage: "square.and.arrow.up") }
                        .buttonStyle(QuietButton()).disabled(!model.canExportCourse(course))
                }
                if course.id != Course.unfiled.id {
                    HStack(spacing: 12) {
                        Image(systemName: course.courseware == nil ? "doc" : "doc.richtext").foregroundStyle(Palette.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(course.courseware.map { "课前课件 · \($0.source.name)" } ?? "课前课件 · 未准备").font(.system(size: 12, weight: .medium))
                        }
                        Spacer()
                        Button { model.importCourseMaterial(course.id) } label: {
                            Label(model.importingCourseMaterial.contains(course.id) ? "读取中…" : (course.courseware == nil ? "准备 PDF" : "更换 PDF"), systemImage: "arrow.up.doc")
                        }.buttonStyle(QuietButton()).disabled(model.importingCourseMaterial.contains(course.id))
                        if course.courseware != nil {
                            Button { model.removeCourseMaterial(course.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Palette.dim).help("取消课前课件")
                        }
                    }.padding(14).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                if !records.isEmpty && !model.canExportCourse(course) && !model.exportingCourseIDs.contains(course.id) {
                    Text("课堂处理中").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                if records.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "text.book.closed").font(.system(size: 32, weight: .ultraLight))
                        Text("暂无课堂记录").font(.system(size: 18, weight: .light))
                    }.padding(.vertical, 35)
                }
                ForEach(records) { lecture in
                    Button { model.selectedID = lecture.id } label: {
                        HStack(spacing: 16) {
                            Image(systemName: model.activeID == lecture.id ? "waveform" : "doc.text").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.mint)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.lectureTitle(lecture)).font(.system(size: 15, weight: .medium))
                                Text("\(lecture.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(formatTime(lecture.activeSeconds))\(lecture.isDemo ? " · DEMO" : "")")
                                    .font(.system(size: 11)).foregroundStyle(Palette.dim)
                            }
                            Spacer()
                            Text(CourseNotesExport.hasNotes(lecture) ? "查看笔记与原稿" : "尚未生成笔记").font(.system(size: 10)).foregroundStyle(Palette.dim)
                            Image(systemName: "chevron.right").font(.system(size: 11))
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CourseEditorView: View {
    @ObservedObject var model: AppModel
    let course: Course?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var failed = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(course == nil ? "新建课程" : "重命名课程").font(.system(size: 23, weight: .medium))
            TextField("例如 Economics 101", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            if failed { Text(model.error ?? "保存失败").font(.system(size: 11)).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("保存", action: save).buttonStyle(SilverButton()).keyboardShortcut(.defaultAction).disabled((try? Course.validatedName(name)) == nil)
            }
        }.padding(28).frame(width: 460).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear { name = course?.name ?? ""; focused = true }
    }
    private func save() { if model.saveCourse(course, name: name) { dismiss() } else { failed = true } }
}

struct CourseExportView: View {
    @ObservedObject var model: AppModel
    let course: Course
    @Environment(\.dismiss) private var dismiss
    @State private var includeOriginal = false
    var body: some View {
        let records = model.records(in: course)
        let missing = records.filter { !CourseNotesExport.hasNotes($0) }.count
        VStack(alignment: .leading, spacing: 18) {
            Text("导出「\(course.name)」").font(.system(size: 22, weight: .medium)).lineLimit(2)
            Text("\(records.count) 次课堂").font(.system(size: 13)).foregroundStyle(Palette.dim)
            Toggle("同时附带完整双语原稿", isOn: $includeOriginal).font(.system(size: 13))
            if missing > 0 { Text("\(missing) 次课堂尚未生成笔记，会保留文件并标注；本次导出不会调用 AI。").font(.system(size: 11)).foregroundStyle(.orange) }
            HStack { Spacer(); Button("取消") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("选择保存位置…") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.exportCourse(course, includeOriginal: includeOriginal) }
                }.buttonStyle(SilverButton()).disabled(!model.canExportCourse(course))
            }
        }.padding(28).frame(width: 530).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
