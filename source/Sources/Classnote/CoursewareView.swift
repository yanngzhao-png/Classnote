import SwiftUI
import PDFKit
import ClassnoteCore

private struct PDFPreviewRequest: Identifiable {
    let id = UUID()
    let source: CoursewareSource
    let url: URL
    let page: Int
}
struct CoursewareView: View {
    @ObservedObject var model: AppModel
    let lecture: Lecture
    var showsNotes = true
    var openNotes: (() -> Void)?
    @State private var preview: PDFPreviewRequest?
    private var importing: Bool { model.importingCourseware.contains(lecture.id) }
    private var generating: Bool { model.busyCombinedNotes.contains(lecture.id) }
    private func open(_ source: CoursewareSource, page: Int = 1) {
        do {
            guard let url = try model.store?.materialURL(source, lectureID: lecture.id) else { return }
            preview = .init(source: source, url: url, page: page)
        } catch { model.error = error.localizedDescription }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(showsNotes ? "课堂笔记 · 关联课件" : "这堂课的课件").font(.system(size: 22, weight: .medium))
                    }
                    Spacer()
                    Button { model.importCourseware(lecture.id) } label: {
                        Label(importing ? "读取课件…" : (lecture.courseware == nil ? "导入 PDF" : "更换 PDF"), systemImage: "doc.badge.plus")
                    }.buttonStyle(QuietButton()).disabled(importing || generating)
                }
                if importing { HStack { ProgressView().controlSize(.small); Text("正在本地提取逐页文字…").font(.system(size: 12)).foregroundStyle(Palette.dim) } }
                if let material = lecture.courseware {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "doc.richtext").font(.system(size: 25, weight: .light)).foregroundStyle(Palette.mint)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(material.source.name).font(.system(size: 14, weight: .medium)).lineLimit(2)
                                Text("\(material.source.pageCount) 页 · \(material.textPages.count) 页可提取文字 · 已保存本地副本").font(.system(size: 10)).foregroundStyle(Palette.dim)
                            }
                            Spacer()
                            Button("查看课件") { open(material.source) }.buttonStyle(QuietButton())
                        }
                        if !material.emptyPageNumbers.isEmpty {
                            Text("第 \(material.emptyPageNumbers.prefix(20).map(String.init).joined(separator: "、"))\(material.emptyPageNumbers.count > 20 ? " 等" : "") 页未提取到文字。这些页不会用于生成笔记。").font(.system(size: 11)).foregroundStyle(.orange.opacity(0.9))
                        }
                        HStack {
                            Text("PDF 文字层").font(.system(size: 10)).foregroundStyle(Palette.dim).help("图片、图表和扫描页暂不识别")
                            Spacer()
                            Button("取消选用") { model.removeCourseware(lecture.id) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.dim).disabled(importing || generating)
                        }
                    }.padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Palette.dim)
                        Text("添加这堂课的 PDF 课件").font(.system(size: 15))
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                if showsNotes {
                HStack {
                    if generating {
                        ProgressView().controlSize(.small)
                        Text(model.combinedProgress[lecture.id] ?? "正在整理…").font(.system(size: 12)).foregroundStyle(Palette.dim)
                        Spacer()
                        Button("取消生成") { model.cancelCombinedNotes(lecture.id) }.buttonStyle(QuietButton())
                    } else {
                        Button { model.generateCombinedNotes(lecture.id) } label: {
                            Label(lecture.combinedNote?.bindings == nil ? "AI 整理并关联课件" : "重新整理并关联", systemImage: "sparkles")
                        }.buttonStyle(SilverButton()).disabled(!model.canGenerateCombined(lecture.id))
                        Spacer()
                    }
                }
                if lecture.isDemo {
                    Text("演示课堂").font(.system(size: 11)).foregroundStyle(Palette.mint)
                } else {
                    EmptyView()
                }
                if model.activeID == lecture.id {
                    Text(lecture.isDemo ? "结束演示后可手动整理" : "课堂结束后可整理").font(.system(size: 11)).foregroundStyle(Palette.dim)
                } else if lecture.unfinishedCount > 0 {
                    Text("还有 \(lecture.unfinishedCount) 段原稿未完成，请先重试转录。").font(.system(size: 11)).foregroundStyle(.orange)
                } else if lecture.transcript.isEmpty {
                    Text("需要课堂英文原稿，才能结合课件整理。").font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                if let error = lecture.combinedNoteError { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
                if let note = lecture.combinedNote {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    if note.isStale(for: lecture) {
                        Label("原稿或课件已变化，以下是上次结果。请重新生成。", systemImage: "arrow.clockwise").font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    HStack {
                        Text(note.isPreview ? "离线资料预览 · 未调用 AI" : "课件综合笔记").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("查看引用课件") { open(note.source) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Palette.mint)
                    }
                    Text("\(note.source.name) · \(note.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Palette.dim)
                    if let bindings = note.bindings {
                        BoundNotesView(notes: bindings, source: note.source, openPage: { open(note.source, page: $0) })
                    } else {
                    Text("旧版结果").font(.system(size: 11)).foregroundStyle(.orange)
                    MarkdownNotes(text: SourceReferences.linkedMarkdown(note.markdown, source: note.source))
                        .environment(\.openURL, OpenURLAction { url in
                            let parts = url.pathComponents.filter { $0 != "/" }
                            guard url.scheme == "classnote", url.host == "material", parts.count == 2,
                                  UUID(uuidString: parts[0]) == note.source.id, let page = Int(parts[1]), page > 0, page <= note.source.pageCount else { return .discarded }
                            open(note.source, page: page); return .handled
                        })
                    }
                }
                if !lecture.notes.isEmpty {
                    DisclosureGroup("此前仅根据原稿生成的笔记") { MarkdownNotes(text: lecture.notes).padding(.top, 12) }.font(.system(size: 11)).foregroundStyle(Palette.dim)
                }
                } else {
                    Button("到课堂笔记整理并关联 →") { openNotes?() }.buttonStyle(SilverButton())
                }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.sheet(item: $preview) { request in PDFPreviewSheet(source: request.source, url: request.url, initialPage: request.page) }
    }
}
private struct PDFPreviewSheet: View {
    let source: CoursewareSource
    let url: URL
    let initialPage: Int
    @Environment(\.dismiss) private var dismiss
    @State private var page = 1
    @State private var showText = false
    @State private var document: PDFDocument?
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(source.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text("PDF · \(source.pageCount) 页").font(.system(size: 10)).foregroundStyle(Palette.dim)
                }
                Spacer(); Button("完成") { dismiss() }.buttonStyle(SilverButton()).keyboardShortcut(.cancelAction)
            }
            if let document {
                HStack {
                    Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page <= 1).help("上一页")
                    Picker("页码", selection: $page) { ForEach(1...max(1, document.pageCount), id: \.self) { Text("第 \($0) / \(document.pageCount) 页").tag($0) } }.frame(width: 190)
                    Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page >= document.pageCount).help("下一页")
                    Spacer(); Toggle("查看提取文字", isOn: $showText).toggleStyle(.switch).font(.system(size: 11))
                }
                if showText {
                    ScrollView {
                        Text(document.page(at: page - 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "此页没有可提取文字，未用于生成综合笔记。")
                            .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                } else { PDFPageView(document: document, page: page).clipShape(RoundedRectangle(cornerRadius: 10)) }
            } else { Spacer(); Text("无法读取保存的 PDF 副本，请检查本地文件是否被移动。").foregroundStyle(.orange); Spacer() }
        }.padding(22).frame(width: 780, height: 650).background(Palette.bg).foregroundStyle(.white).preferredColorScheme(.dark)
            .onAppear { document = PDFDocument(url: url); page = min(max(1, initialPage), max(1, document?.pageCount ?? 1)) }
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private struct PDFPageView: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.displayMode = .singlePage; view.autoScales = true; view.backgroundColor = NSColor(white: 0.08, alpha: 1)
        view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let target = document.page(at: page - 1), view.currentPage !== target { view.go(to: target) }
    }
}
