import Foundation

/// A small, escaped HTML clipboard representation for editors such as Notion.
/// Keeps a plain Markdown flavor alongside it; never executes or embeds source HTML.
public enum MarkdownExport {
    public static func html(_ markdown: String) -> String {
        func inline(_ text: String) -> String {
            let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            return escaped.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        }
        var body = ""; var list: String?
        func closeList() { if let kind = list { body += "</\(kind)>\n"; list = nil } }
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { closeList(); continue }
            let orderedRange = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression)
            if trimmed.hasPrefix("- ") || orderedRange != nil {
                let kind = orderedRange == nil ? "ul" : "ol"
                if list != kind { closeList(); body += "<\(kind)>\n"; list = kind }
                let content = orderedRange.map { String(trimmed[$0.upperBound...]) } ?? String(trimmed.dropFirst(2))
                body += "<li>\(inline(content))</li>\n"; continue
            }
            closeList()
            if trimmed == "---" { body += "<hr>\n" }
            else if trimmed.hasPrefix("### ") { body += "<h3>\(inline(String(trimmed.dropFirst(4))))</h3>\n" }
            else if trimmed.hasPrefix("## ") { body += "<h2>\(inline(String(trimmed.dropFirst(3))))</h2>\n" }
            else if trimmed.hasPrefix("# ") { body += "<h1>\(inline(String(trimmed.dropFirst(2))))</h1>\n" }
            else if trimmed.hasPrefix("> ") { body += "<blockquote>\(inline(String(trimmed.dropFirst(2))))</blockquote>\n" }
            else { body += "<p>\(inline(trimmed))</p>\n" }
        }
        closeList()
        return "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>" + body + "</body></html>"
    }
}
