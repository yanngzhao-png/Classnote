import Foundation

public enum TranscriptionOptions {
    public static let accurateModel = "gpt-transcribe"
    public static func usesLanguageList(_ model: String) -> Bool {
        model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-") || model == "gpt-live-transcribe" || model.hasPrefix("gpt-live-transcribe-")
    }
    public static func keywords(_ vocabulary: String) -> [String] {
        let parts = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",，;；\n\r"))
        var seen = Set<String>()
        return parts.compactMap { part in
            let clean = String(part.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            return !clean.isEmpty && seen.insert(clean.lowercased()).inserted ? clean : nil
        }.prefix(32).map { $0 }
    }
    public static func prompt(_ vocabulary: String, context: String = "") -> String {
        let terms = keywords(vocabulary).joined(separator: ", ")
        var value = "An English university lecture, including speakers with non-native accents."
        if !terms.isEmpty { value += " Course terminology: " + String(terms.prefix(1500)) }
        if !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value += " Use this optional course handout only to disambiguate spelling and terminology. Transcribe only words actually spoken; do not add unspoken handout text.\n" + String(context.prefix(7_500))
        }
        return value
    }
    public static func realtime(model: String, vocabulary: String, context: String = "") -> [String: Any] {
        var value: [String: Any] = ["model": model, "prompt": prompt(vocabulary, context: context)]
        if usesLanguageList(model) {
            value["languages"] = ["en"]
            let terms = keywords(vocabulary)
            if !terms.isEmpty { value["keywords"] = terms }
        }
        // The committed-turn model has no live delay setting.
        if model == "gpt-live-transcribe" || model.hasPrefix("gpt-live-transcribe-") { value["delay"] = "high" }
        return value
    }
    public static func fileFields(model: String, vocabulary: String) -> [(String, String)] {
        guard model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-") else { return [] }
        return [("languages[]", "en"), ("prompt", prompt(vocabulary))] + keywords(vocabulary).map { ("keywords[]", $0) }
    }
}
