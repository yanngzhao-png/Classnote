import Foundation

private final class NotionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
@MainActor public final class NotionClient: NotionAPI {
    private let token: String
    private let session: URLSession
    private var nextRequest = Date.distantPast
    private let pause: (Double) async throws -> Void
    public init(token: String, session: URLSession? = nil, pause: @escaping (Double) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 90
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: NotionRedirectGuard(), delegateQueue: nil)
        self.pause = pause
    }
    public func checkConnection() async throws -> String {
        let user = try await request("GET", path: "users/me")
        return user["name"] as? String ?? "Notion 连接"
    }
    public func page(_ id: String) async throws -> NotionPageTarget {
        do {
            let json = try await request("GET", path: "pages/" + normalized(id))
            return try decodePage(json)
        } catch let error as NotionRequestFailure where error.statusCode == 404 {
            throw NotionPageUnavailable(pageID: normalized(id), reason: .notFound)
        }
    }
    public func children(_ id: String) async throws -> [NotionRemoteBlock] {
        var result: [NotionRemoteBlock] = [], cursor: String?
        var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { query.append(.init(name: "start_cursor", value: cursor)) }
            let response = try await request("GET", path: "blocks/" + normalized(id) + "/children", query: query)
            guard let blocks = response["results"] as? [[String: Any]] else { throw NotionFailure("Notion 未返回完整列表，请重试。") }
            result.append(contentsOf: try blocks.map(decodeBlock))
            if response["has_more"] as? Bool == true {
                guard let next = response["next_cursor"] as? String, !next.isEmpty, seen.insert(next).inserted else { throw NotionFailure("Notion 分页响应异常，已停止同步。") }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return result
    }
    public func createPage(parent: String, title: String) async throws -> NotionPageTarget {
        let response = try await request("POST", path: "pages", body: ["parent": ["page_id": normalized(parent)], "properties": titleProperty(title), "notifications": ["mode": "silent"]])
        return try decodePage(response)
    }
    public func append(parent: String, blocks: [NotionBlockText], atStart: Bool) async throws -> [NotionRemoteBlock] {
        guard !blocks.isEmpty, blocks.count <= 100 else { throw NotionFailure("上传批次不符合 Notion 限制。") }
        let response = try await request("PATCH", path: "blocks/" + normalized(parent) + "/children", body: ["children": blocks.map(\.json), "position": ["type": atStart ? "start" : "end"], "notifications": ["mode": "silent"]])
        guard let values = response["results"] as? [[String: Any]] else { throw NotionFailure("上传结果未完整返回，请重试核对云端。") }
        return try values.map(decodeBlock)
    }
    public func renamePage(_ id: String, title: String) async throws {
        _ = try await request("PATCH", path: "pages/" + normalized(id), body: ["properties": titleProperty(title), "notifications": ["mode": "silent"]])
    }
    public func renameToggle(_ id: String, title: String) async throws {
        _ = try await request("PATCH", path: "blocks/" + normalized(id), body: ["toggle": ["rich_text": [["type": "text", "text": ["content": title]]]]])
    }
    func normalized(_ id: String) -> String { UUID(uuidString: id)?.uuidString.lowercased() ?? "invalid-id" }
    private func titleProperty(_ title: String) -> [String: Any] { ["title": ["type": "title", "title": [["type": "text", "text": ["content": String(title.prefix(500))]]]]] }
    func decodePage(_ value: [String: Any]) throws -> NotionPageTarget {
        guard value["object"] as? String == "page", let id = value["id"] as? String, UUID(uuidString: id) != nil else { throw NotionFailure("目标不是有效的 Notion 页面；请选择课程页面，而不是数据库视图。") }
        guard value["in_trash"] as? Bool != true, value["archived"] as? Bool != true, value["is_archived"] as? Bool != true else { throw NotionPageUnavailable(pageID: normalized(id), reason: .deleted) }
        var title = "未命名页面"
        for property in (value["properties"] as? [String: [String: Any]] ?? [:]).values {
            if let values = property["title"] as? [[String: Any]] { title = plainText(values); break }
        }
        let url = (value["url"] as? String).flatMap { raw -> String? in
            guard let u = URL(string: raw), u.scheme == "https", let host = u.host,
                  host == "notion.so" || host.hasSuffix(".notion.so") || host == "notion.com" || host.hasSuffix(".notion.com") else { return nil }
            return raw
        }
        var result = NotionPageTarget(id: normalized(id), title: title, url: url)
        let parent = value["parent"] as? [String: Any] ?? [:]
        result.parentPageID = (parent["page_id"] as? String).map(normalized)
        result.parentDataSourceID = (parent["data_source_id"] as? String ?? parent["database_id"] as? String).map(normalized)
        return result
    }
    private func decodeBlock(_ value: [String: Any]) throws -> NotionRemoteBlock {
        guard let id = value["id"] as? String, UUID(uuidString: id) != nil, let type = value["type"] as? String else { throw NotionFailure("Notion 返回的资料块不完整，请重试。") }
        let content = value[type] as? [String: Any] ?? [:]
        let text = type == "child_page" ? (content["title"] as? String ?? "") : plainText(content["rich_text"] as? [[String: Any]] ?? [])
        let runs = (content["rich_text"] as? [[String: Any]] ?? []).map { value -> NotionTextRun in
            var run = NotionTextRun(plainText([value]))
            let style = value["annotations"] as? [String: Any] ?? [:]
            run.bold = style["bold"] as? Bool ?? false; run.italic = style["italic"] as? Bool ?? false
            run.code = style["code"] as? Bool ?? false; run.strikethrough = style["strikethrough"] as? Bool ?? false
            run.underline = style["underline"] as? Bool ?? false; run.color = style["color"] as? String ?? "default"
            run.link = ((value["text"] as? [String: Any])?["link"] as? [String: Any])?["url"] as? String
            return run
        }
        return .init(id: normalized(id), type: type, text: text, hasChildren: value["has_children"] as? Bool ?? false,
                     richText: NotionTextRun.normalized(runs))
    }
    func plainText(_ values: [[String: Any]]) -> String {
        values.map { $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String ?? "" }.joined()
    }
    func request(_ method: String, path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !token.isEmpty else { throw NotionRequestFailure("请先在设置中保存 Notion 连接凭证。", definiteRejection: true) }
        var components = URLComponents(string: "https://api.notion.com/v1/" + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count < 450_000 else { throw NotionRequestFailure("这批资料超过上传限制，未发送。", definiteRejection: true) }
        }
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let delay = nextRequest.timeIntervalSinceNow
            if delay > 0 { try await pause(delay) }
            nextRequest = Date().addingTimeInterval(0.36)
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request) }
            catch {
                if error is CancellationError { throw error }
                let code = (error as? URLError)?.code
                let unsent = code == .notConnectedToInternet || code == .cannotFindHost || code == .dnsLookupFailed || code == .cannotConnectToHost
                throw NotionRequestFailure(unsent ? "无法连接 Notion，请检查网络后重试。" : "Notion 请求中断，重试时会先核对云端结果。", definiteRejection: unsent)
            }
            guard let response = response as? HTTPURLResponse else { throw NotionRequestFailure("Notion 响应无效。", definiteRejection: false) }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (200..<300).contains(response.statusCode) { return json }
            let code = json["code"] as? String ?? ""
            let additional = json["additional_data"] as? [String: Any] ?? [:]
            let limited = (response.statusCode == 429 || response.statusCode == 529) && additional["rate_limit_reason"] as? String != "public_api_request_blocked"
            let retryableRead = method == "GET" && [500,502,503,504].contains(response.statusCode)
            if limited || retryableRead {
                let retry = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(additional["retry_after"] as? String ?? "") ?? pow(2, Double(attempt + 1))
                nextRequest = Date().addingTimeInterval(max(1, retry))
                if attempt < 2 { continue }
            }
            let message: String
            switch response.statusCode {
            case 401: message = "Notion 凭证无效或已撤销，请重新保存。"
            case 403: message = "Notion 拒绝访问；请检查连接的读取/插入/更新权限，以及工作区用量限制。"
            case 404: message = "Notion 页面或资料块不存在，或当前连接无法访问；请检查目标是否已删除及页面权限。"
            case 429,529: message = "Notion 暂时限流，请稍后重试。"
            case 400: message = "Notion 未接受资料格式或页面类型（\(code)），本地资料保留。"
            default: message = "Notion 暂时无法完成请求（HTTP \(response.statusCode)），请重试核对云端。"
            }
            let definite = (400..<500).contains(response.statusCode) || response.statusCode == 529
            throw NotionRequestFailure(message, definiteRejection: definite, statusCode: response.statusCode)
        }
        throw NotionFailure("Notion 暂时不可用，请稍后重试。")
    }
}
