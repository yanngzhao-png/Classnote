import Foundation

public struct NotionTextRun: Codable, Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var code = false
    public var strikethrough = false
    public var underline = false
    public var link: String?
    public var color = "default"
    public init(_ text: String, bold: Bool = false, code: Bool = false) {
        self.text = text; self.bold = bold; self.code = code
    }
    public var isPlain: Bool { !bold && !italic && !code && !strikethrough && !underline && link == nil && color == "default" }
    public var json: [String: Any] {
        var content: [String: Any] = ["content": text]
        if let link { content["link"] = ["url": link] }
        return ["type": "text", "text": content, "annotations": ["bold": bold, "italic": italic, "code": code,
            "strikethrough": strikethrough, "underline": underline, "color": color]]
    }
    public static func normalized(_ runs: [Self]) -> [Self]? {
        guard runs.contains(where: { !$0.isPlain }) else { return nil }
        var result: [Self] = []
        for run in runs where !run.text.isEmpty {
            if var last = result.last {
                let text = last.text; last.text = run.text
                if last == run { result[result.count - 1].text = text + run.text; continue }
            }
            result.append(run)
        }
        return result
    }
}

/// Study prose is always visible; source quotations are kept in native closed toggles.
/// This reads saved structured notes, so existing classrooms need no new AI request.
public enum NotionStudyNotes {
    public static func render(_ notes: BoundNotes, source: CoursewareSource) -> [NotionBlockText] {
        var blocks: [NotionBlockText] = [.init("heading_2", "本节要点")]
        blocks += markdown(notes.summary)
        blocks += literal("课件：\(source.name) · \(source.pageCount) 页")
        for (index, point) in notes.points.enumerated() {
            blocks += literal("\(index + 1). \(point.title)", type: "heading_2")
            blocks += markdown(point.teaching)
            let references = slideLocations(point.slides)
            blocks += literal(references.isEmpty ? "课件：未找到明确对应" : "课件：\(source.name) · \(references)")
            var evidence: [NotionBlockText] = [.init("heading_3", "教授原话")]
            if point.transcript.isEmpty { evidence += literal("原稿来源待核对，暂未定位具体段落。") }
            for item in point.transcript {
                evidence += literal(item.verification == .unavailable ? "课堂时间未定位 · 待核对" : "课堂 \(item.time)" + (item.isVerified ? "" : " · 待核对"))
                if let note = item.verificationNote { evidence += literal(note) }
                if !item.isVerified { evidence += literal("AI 提供的文字线索，非已核实引文") }
                evidence += literal(item.quote, type: "quote")
            }
            if point.slides.isEmpty {
                evidence += literal(point.unmatchedReason)
            } else {
                evidence.append(.init("heading_3", "课件依据与对应关系"))
                for item in point.slides { evidence += slideEvidence(item, source: source) }
            }
            let uncertain = point.transcript.contains { !$0.isVerified } || point.transcript.isEmpty || point.slides.contains { !$0.isVerified }
            blocks.append(.toggle("原话与来源" + (uncertain ? " · 含待核对引用" : ""), children: evidence))
        }
        if !notes.supplements.isEmpty {
            var supplements: [NotionBlockText] = []
            for item in notes.supplements { supplements += slideEvidence(item, source: source) }
            blocks.append(.toggle("课件补充 · 本次原稿未讲到", children: supplements))
        }
        if !notes.reviewQuestions.isEmpty {
            blocks.append(.init("heading_2", "复习自测 · AI 整理"))
            for question in notes.reviewQuestions { blocks += formatted(question, type: "numbered_list_item") }
        }
        return blocks
    }
    private static func slideLocations(_ slides: [SlideEvidence]) -> String {
        var seen = Set<String>()
        return slides.compactMap { slide in
            let label = slide.canOpenPage ? "p.\(slide.page)" + (slide.isVerified ? "" : "（待核对）") : "来源页未定位"
            return seen.insert(label).inserted ? label : nil
        }.joined(separator: "、")
    }
    private static func slideEvidence(_ item: SlideEvidence, source: CoursewareSource) -> [NotionBlockText] {
        var result = literal("\(source.name) · \(slideLocations([item]))", type: "heading_3")
        if let note = item.verificationNote { result += literal(note) }
        if !item.isVerified { result += literal("AI 提供的课件线索，非已核实引文") }
        result += literal(item.quote, type: "quote")
        result += markdown("**对应说明（AI 整理）**\n\n" + item.explanation)
        return result
    }
    public static func literal(_ text: String, type: String = "paragraph") -> [NotionBlockText] {
        chunk([.init(text)], type: type)
    }
    public static func markdown(_ text: String) -> [NotionBlockText] {
        var output: [NotionBlockText] = []
        for line in text.components(separatedBy: .newlines) {
            var value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            var type = "paragraph"
            if value.hasPrefix("### ") { type = "heading_3"; value.removeFirst(4) }
            else if value.hasPrefix("## ") { type = "heading_2"; value.removeFirst(3) }
            else if value.hasPrefix("# ") { type = "heading_1"; value.removeFirst(2) }
            else if value.hasPrefix("- ") || value.hasPrefix("* ") { type = "bulleted_list_item"; value.removeFirst(2) }
            else if value.hasPrefix("> ") { type = "quote"; value.removeFirst(2) }
            else if let prefix = value.range(of: "^[0-9]+[.)] +", options: .regularExpression) {
                type = "numbered_list_item"; value.removeSubrange(prefix)
            }
            output += formatted(value, type: type)
        }
        return output
    }
    public static func formatted(_ text: String, type: String = "paragraph") -> [NotionBlockText] {
        // Only consume paired markup. Unmatched markers and literal quotations stay intact.
        let regex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*|`([^`]+)`")
        var runs: [NotionTextRun] = [], cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound { runs.append(.init(String(text[cursor..<range.lowerBound]))) }
            if let bold = Range(match.range(at: 1), in: text) { runs.append(.init(String(text[bold]), bold: true)) }
            else if let code = Range(match.range(at: 2), in: text) { runs.append(.init(String(text[code]), code: true)) }
            cursor = range.upperBound
        }
        if cursor < text.endIndex { runs.append(.init(String(text[cursor...]))) }
        return chunk(runs, type: type)
    }
    private static func chunk(_ runs: [NotionTextRun], type: String) -> [NotionBlockText] {
        var result: [NotionBlockText] = [], current: [NotionTextRun] = [], units = 0
        func flush() {
            guard !current.isEmpty else { return }
            var block = NotionBlockText(type, current.map(\.text).joined())
            block.richText = NotionTextRun.normalized(current)
            result.append(block); current = []; units = 0
        }
        for run in runs {
            var part = run; part.text = ""
            for scalar in run.text.unicodeScalars {
                if units + scalar.utf16.count > 1500 || (current.count >= 80 && !part.text.isEmpty) {
                    if !part.text.isEmpty { current.append(part); part.text = "" }
                    flush()
                }
                part.text.unicodeScalars.append(scalar); units += scalar.utf16.count
            }
            if !part.text.isEmpty { current.append(part) }
        }
        flush(); return result
    }
}
