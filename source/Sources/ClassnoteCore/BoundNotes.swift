import Foundation

public enum EvidenceVerification: String, Codable, Sendable {
    case verified, corrected, needsReview, unavailable
}
public struct TranscriptEvidence: Codable, Equatable, Sendable {
    public var time: String
    public var quote: String
    public var verification: EvidenceVerification?
    public var verificationNote: String?
    public var isVerified: Bool { verification == nil || verification == .verified || verification == .corrected }
}
public struct SlideEvidence: Codable, Equatable, Sendable {
    public var page: Int
    public var quote: String
    public var explanation: String
    public var verification: EvidenceVerification?
    public var verificationNote: String?
    public var isVerified: Bool { verification == nil || verification == .verified || verification == .corrected }
    public var canOpenPage: Bool { verification != .unavailable }
}
public struct TeachingPoint: Codable, Equatable, Sendable {
    public var title: String
    public var teaching: String
    public var transcript: [TranscriptEvidence]
    public var slides: [SlideEvidence]
    public var unmatchedReason: String
}
/// A teaching point owns both sides of its association; a list of unrelated citations is insufficient.
public struct BoundNotes: Codable, Equatable, Sendable {
    public var summary: String
    public var points: [TeachingPoint]
    public var supplements: [SlideEvidence]
    public var reviewQuestions: [String]

    public static var schema: [String: Any] {
        func object(_ fields: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": fields, "required": fields.keys.sorted(), "additionalProperties": false]
        }
        func array(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
        let string: [String: Any] = ["type": "string"]
        let transcript = object(["time": string, "quote": string])
        let slide = object(["page": ["type": "integer"], "quote": string, "explanation": string])
        let point = object(["title": string, "teaching": string, "transcript": array(transcript), "slides": array(slide), "unmatchedReason": string])
        return object(["summary": string, "points": array(point), "supplements": array(slide), "reviewQuestions": array(string)])
    }
    public static func decode(_ text: String, lecture: Lecture, courseware: Courseware) throws -> BoundNotes {
        var result: BoundNotes
        do { result = try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
        catch { throw CoursewareFailure("AI 未返回完整的课堂与课件关联结构。上次结果已保留，请重试。") }
        result.reconcileEvidence(lecture: lecture, courseware: courseware)
        try result.validate(lecture: lecture, courseware: courseware)
        return result
    }
    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    private static func contains(_ source: String, _ quote: String) -> Bool {
        let q = normalized(quote)
        return q.count >= 8 && normalized(source).contains(q)
    }
    /// Source checks label individual evidence; they never discard a usable note.
    /// Semantic association remains the model's suggestion, even when a quote matches.
    public mutating func reconcileEvidence(lecture: Lecture, courseware: Courseware) {
        func slide(_ input: SlideEvidence) -> SlideEvidence {
            var evidence = input
            evidence.verificationNote = nil
            let original = courseware.pages.first { $0.number == evidence.page }
            if let original, Self.contains(original.text, evidence.quote) {
                evidence.verification = .verified
            } else {
                let matches = courseware.textPages.filter { Self.contains($0.text, evidence.quote) }
                if matches.count == 1, let match = matches.first {
                    let old = evidence.page; evidence.page = match.number; evidence.verification = .corrected
                    evidence.verificationNote = "原标第 \(old) 页；摘录仅在第 \(match.number) 页找到，已校正页码。"
                } else if original != nil {
                    evidence.verification = .needsReview
                    evidence.verificationNote = "AI 建议参考此页；摘录未逐字核对通过，请结合课件查看。"
                } else {
                    evidence.verification = .unavailable
                    evidence.verificationNote = "AI 标注的第 \(evidence.page) 页不存在，暂未定位来源；关联建议保留待核对。"
                }
            }
            if evidence.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                evidence.explanation = "AI 建议此内容可能有关联，具体对应关系待核对。"
            }
            return evidence
        }
        for index in points.indices {
            for reference in points[index].transcript.indices {
                var evidence = points[index].transcript[reference]; evidence.verificationNote = nil
                let original = lecture.orderedSegments.first { formatTime($0.offset) == evidence.time }
                if let original, Self.contains(original.english, evidence.quote) {
                    evidence.verification = .verified
                } else {
                    let matches = lecture.orderedSegments.filter { Self.contains($0.english, evidence.quote) }
                    if matches.count == 1, let match = matches.first {
                        let old = evidence.time; evidence.time = formatTime(match.offset); evidence.verification = .corrected
                        evidence.verificationNote = "原标 \(old)；已按唯一匹配原稿校正为 \(evidence.time)。"
                    } else {
                        evidence.verification = original == nil ? .unavailable : .needsReview
                        evidence.verificationNote = original == nil ? "时间未能定位，以下为 AI 提供的待核对文字。" : "摘录未逐字核对通过，以下为 AI 提供的待核对文字。"
                    }
                }
                points[index].transcript[reference] = evidence
            }
            points[index].slides = points[index].slides.map(slide)
            if points[index].slides.isEmpty && points[index].unmatchedReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                points[index].unmatchedReason = "本知识点没有找到合适的课件关联，课堂内容已保留。"
            }
        }
        supplements = supplements.map(slide)
    }
    public var reviewCount: Int {
        points.reduce(0) { $0 + $1.transcript.filter { !$0.isVerified }.count + $1.slides.filter { !$0.isVerified }.count + ($1.transcript.isEmpty ? 1 : 0) }
            + supplements.filter { !$0.isVerified }.count
    }
    public func validate(lecture: Lecture, courseware: Courseware) throws {
        guard !points.isEmpty, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              points.allSatisfy({ !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.teaching.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw CoursewareFailure("AI 没有返回完整的授课整理，请重试；上次笔记保留。")
        }
    }
    public func markdown(source: CoursewareSource) -> String {
        var text = "## 本节摘要\n\n\(summary)\n\n## 按授课内容关联课件\n\n"
        if reviewCount > 0 { text += "说明：\(reviewCount) 处来源待核对，关联建议和课堂整理均已保留。标为待核对的文字不是已核实原文。\n\n" }
        func slideText(_ evidence: SlideEvidence) -> String {
            let location = evidence.canOpenPage ? "[课件 p.\(evidence.page)]" : "（来源页未定位）"
            var result = "**课件来源：\(source.name)** \(location)\n\n"
            if let note = evidence.verificationNote { result += note + "\n\n" }
            result += evidence.isVerified ? "> \(evidence.quote.replacingOccurrences(of: "\n", with: " "))\n\n" : "**AI 提供的内容线索（待核对，非已核实引文）**\n\n\(evidence.quote)\n\n"
            return result + "**关联说明（AI 整理）**\n\n\(evidence.explanation)\n\n"
        }
        for (index, point) in points.enumerated() {
            text += "### \(index + 1). \(point.title)\n\n**课堂讲解整理**\n\n\(point.teaching)\n\n**课堂原稿依据**\n\n"
            if point.transcript.isEmpty { text += "原稿来源待核对；本知识点暂未定位具体段落。\n\n" }
            for evidence in point.transcript {
                text += evidence.verification == .unavailable ? "课堂时间未定位\n\n" : "[课堂 \(evidence.time)]\n\n"
                if let note = evidence.verificationNote { text += note + "\n\n" }
                text += evidence.isVerified ? "> \(evidence.quote.replacingOccurrences(of: "\n", with: " "))\n\n" : "**AI 提供的原稿线索（待核对，非已核实引文）**\n\n\(evidence.quote)\n\n"
            }
            if point.slides.isEmpty { text += "**课件对应：未找到明确对应**\n\n\(point.unmatchedReason)\n\n" }
            for evidence in point.slides { text += slideText(evidence) }
        }
        text += "## 课件补充：当前原稿未讲到\n\n"
        if supplements.isEmpty { text += "未单列补充内容。\n\n" }
        for evidence in supplements { text += slideText(evidence) }
        text += "## AI 生成的复习题\n\n" + reviewQuestions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        return text
    }
}
