import SwiftUI
import ClassnoteCore

struct BoundNotesView: View {
    let notes: BoundNotes
    let source: CoursewareSource
    let openPage: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("本节摘要").font(.system(size: 18, weight: .semibold))
            Text(notes.summary).font(.system(size: 14)).lineSpacing(6)
            if notes.reviewCount > 0 {
                Label("\(notes.reviewCount) 处来源待核对，笔记和关联建议已保留", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            ForEach(Array(notes.points.enumerated()), id: \.offset) { index, point in
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(index + 1). \(point.title)").font(.system(size: 19, weight: .semibold))
                    label("课堂讲解整理", icon: "text.bubble")
                    Text(point.teaching).font(.system(size: 14)).lineSpacing(6)
                    ForEach(Array(point.transcript.enumerated()), id: \.offset) { _, evidence in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(evidence.verification == .unavailable ? "原稿来源待定位" : "原稿 · \(evidence.time)").font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Palette.mint)
                            if let note = evidence.verificationNote { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
                            if !evidence.isVerified { Text("AI 提供的文字线索 · 非已核实引文").font(.system(size: 10)).foregroundStyle(Palette.dim) }
                            Text(evidence.quote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineSpacing(4)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if point.transcript.isEmpty { Text("原稿来源待核对；暂未定位具体段落。").font(.system(size: 11)).foregroundStyle(.orange) }
                    if point.slides.isEmpty {
                        Label("课件：暂无关联，课堂内容已保留", systemImage: "text.alignleft").font(.system(size: 12)).foregroundStyle(Palette.dim)
                        Text(point.unmatchedReason).font(.system(size: 12)).foregroundStyle(Palette.dim).lineSpacing(4)
                    } else {
                        ForEach(Array(point.slides.enumerated()), id: \.offset) { _, evidence in
                            slide(evidence, heading: "与这段讲解的关联（AI 整理）")
                        }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
            }
            if !notes.supplements.isEmpty {
                Text("课件补充 · 当前原稿未讲到").font(.system(size: 17, weight: .semibold))
                ForEach(Array(notes.supplements.enumerated()), id: \.offset) { _, evidence in
                    slide(evidence, heading: "课件补充（AI 整理）").padding(18).background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            if !notes.reviewQuestions.isEmpty {
                Text("AI 生成的复习题").font(.system(size: 17, weight: .semibold))
                ForEach(Array(notes.reviewQuestions.enumerated()), id: \.offset) { index, question in
                    Text("\(index + 1). \(question)").font(.system(size: 13)).lineSpacing(5)
                }
            }
        }.textSelection(.enabled)
    }
    private func label(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.mint)
    }
    private func slide(_ evidence: SlideEvidence, heading: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                label("课件来源", icon: "doc.text")
                Text(source.name).font(.system(size: 11)).foregroundStyle(Palette.dim).lineLimit(2)
                Spacer(minLength: 8)
                if evidence.canOpenPage {
                    Button("第 \(evidence.page) 页 ↗") { openPage(evidence.page) }.buttonStyle(QuietButton()).help("打开课件的第 \(evidence.page) 页")
                } else { Text("来源页待定位").font(.system(size: 11)).foregroundStyle(.orange) }
            }
            if let note = evidence.verificationNote { Text(note).font(.system(size: 11)).foregroundStyle(.orange) }
            if !evidence.isVerified { Text("AI 提供的内容线索 · 非已核实引文").font(.system(size: 10)).foregroundStyle(Palette.dim) }
            Text(evidence.quote).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineSpacing(4)
                .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Palette.mint.opacity(0.4)).frame(width: 2) }
            Text(heading).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.mint)
            Text(evidence.explanation).font(.system(size: 13)).lineSpacing(5)
        }
    }
}
