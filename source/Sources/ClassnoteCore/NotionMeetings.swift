import Foundation

/// A verified database schema. Property IDs survive column renames.
public struct NotionMeetingTarget: Codable, Equatable, Sendable {
    public var dataSourceID: String
    public var title: String
    public var titleProperty: String
    public var courseProperty: String?
    public var dateProperty: String?
    public var typeProperty: String?
    public var classroomOption: String?
    public init(dataSourceID: String, title: String, titleProperty: String, courseProperty: String? = nil, dateProperty: String? = nil,
                typeProperty: String? = nil, classroomOption: String? = nil) {
        self.dataSourceID = dataSourceID; self.title = title; self.titleProperty = titleProperty
        self.courseProperty = courseProperty; self.dateProperty = dateProperty
        self.typeProperty = typeProperty; self.classroomOption = classroomOption
    }
}

extension NotionClient {
    public func meetingTargets(databaseLink: String, courseID: String) async throws -> [NotionMeetingTarget] {
        let course = try await page(courseID)
        let courseSource = course.parentDataSourceID
        let databaseID = try NotionPageTarget.pageID(databaseLink)
        // Notion exposes both database links and data-source links. Accept either so a
        // copied view/data-source URL does not prevent placing the page in the list.
        let database: [String: Any]
        do {
            database = try await request("GET", path: "databases/" + databaseID)
        } catch {
            let source = try await request("GET", path: "data_sources/" + databaseID)
            database = ["data_sources": [["id": source["id"] as? String ?? databaseID]]]
        }
        guard let sources = database["data_sources"] as? [[String: Any]], !sources.isEmpty else {
            throw NotionFailure("未找到会议数据源，请复制原始会议数据库链接，而不是课程里的视图链接。")
        }
        var targets: [NotionMeetingTarget] = []
        for source in sources {
            guard let id = source["id"] as? String else { continue }
            let schema = try await request("GET", path: "data_sources/" + normalized(id))
            if let target = try? Self.meetingSchema(schema, courseSource: courseSource) { targets.append(target) }
        }
        guard !targets.isEmpty else { throw NotionFailure("会议数据源至少需要一个标题字段；课程关联、日期和类型字段会尽量自动填写。") }
        return targets
    }
    public static func meetingSchema(_ schema: [String: Any], courseSource: String? = nil) throws -> NotionMeetingTarget {
        guard schema["object"] as? String == "data_source", schema["in_trash"] as? Bool != true,
              schema["archived"] as? Bool != true, let id = schema["id"] as? String, let uuid = UUID(uuidString: id),
              let properties = schema["properties"] as? [String: [String: Any]] else { throw NotionFailure("会议数据库格式无效。") }
        func candidates(_ type: String) -> [(String, [String: Any])] { properties.filter { $0.value["type"] as? String == type }.map { ($0.key, $0.value) } }
        func unique(_ values: [(String, [String: Any])], names: [String]) throws -> String {
            let preferred = values.filter { names.contains($0.0.lowercased()) }
            let selected = preferred.isEmpty ? values : preferred
            guard selected.count == 1, let property = selected.first?.1["id"] as? String else { throw NotionFailure("会议字段存在歧义，请使用明确的课程和日期字段。") }
            return property
        }
        let matchingRelations: [(String, [String: Any])] = {
            guard let courseSource, let sourceUUID = UUID(uuidString: courseSource) else { return [] }
            return candidates("relation").filter {
                let value = $0.1["relation"] as? [String: Any]
                let relationSource = value?["data_source_id"] as? String ?? value?["database_id"] as? String
                return relationSource.flatMap(UUID.init(uuidString:)) == sourceUUID
            }
        }()
        let titleProperty = try unique(candidates("title"), names: [])
        // These properties are useful metadata, but they are not required for page
        // placement. A user may have a simple meeting list, a relation to another
        // database, or a renamed/ambiguous date column.
        let courseProperty: String? = matchingRelations.count == 1 ? (matchingRelations.first?.1["id"] as? String) : nil
        let dateCandidates = candidates("date")
        let preferredDates = dateCandidates.filter { ["上课或会议日期", "日期", "date", "class date"].contains($0.0.lowercased()) }
        let dateProperty: String?
        if preferredDates.count == 1 { dateProperty = preferredDates.first?.1["id"] as? String }
        else if preferredDates.isEmpty && dateCandidates.count == 1 { dateProperty = dateCandidates.first?.1["id"] as? String }
        else { dateProperty = nil }
        let type = candidates("select").first { ["类型", "type"].contains($0.0.lowercased()) }
        let options = (type?.1["select"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
        let option = options.first { ["课堂", "lecture", "class"].contains(($0["name"] as? String ?? "").lowercased()) }?["id"] as? String
        let title = (schema["title"] as? [[String: Any]] ?? []).map { $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String ?? "" }.joined()
        return .init(dataSourceID: uuid.uuidString.lowercased(), title: title.isEmpty ? "会议列表" : title,
                     titleProperty: titleProperty, courseProperty: courseProperty, dateProperty: dateProperty,
                     typeProperty: option == nil ? nil : type?.1["id"] as? String, classroomOption: option)
    }
    public func validateDestination(_ parent: NotionPageTarget) async throws {
        let course = try await page(parent.id)
        guard let meetings = parent.meetings else { return }
        let schema = try await request("GET", path: "data_sources/" + normalized(meetings.dataSourceID))
        guard schema["object"] as? String == "data_source", schema["in_trash"] as? Bool != true,
              schema["archived"] as? Bool != true,
              let properties = schema["properties"] as? [String: [String: Any]],
              properties.values.contains(where: { $0["id"] as? String == meetings.titleProperty && $0["type"] as? String == "title" }) else {
            throw NotionFailure("会议数据源不可访问或没有标题字段；课堂内容仍保留在本机。")
        }
        // Optional fields are checked during the best-effort metadata write. Their
        // absence does not block creating/moving the actual classroom page.
        _ = course
    }
    public func pendingPages(parent: NotionPageTarget, title: String) async throws -> [NotionPageTarget] {
        guard let meetings = parent.meetings else {
            return try await children(parent.id).filter { $0.content.type == "child_page" && $0.content.text == title }.map { .init(id: $0.id, title: title) }
        }
        var result: [NotionPageTarget] = [], cursor: String?, seen = Set<String>()
        repeat {
            var body: [String: Any] = ["page_size": 100, "filter": ["property": meetings.titleProperty, "title": ["equals": title]]]
            if let cursor { body["start_cursor"] = cursor }
            let response = try await request("POST", path: "data_sources/" + normalized(meetings.dataSourceID) + "/query", body: body)
            guard let pages = response["results"] as? [[String: Any]] else { throw NotionFailure("会议列表回读不完整。") }
            result.append(contentsOf: try pages.map(decodePage))
            if response["has_more"] as? Bool == true {
                guard let next = response["next_cursor"] as? String, !next.isEmpty, seen.insert(next).inserted else { throw NotionFailure("会议列表分页异常。") }
                cursor = next
            } else { cursor = nil }
        } while cursor != nil
        return result
    }
    public func createArchivePage(parent: NotionPageTarget, title: String, date: Date?) async throws -> NotionPageTarget {
        guard let meetings = parent.meetings else { return try await createPage(parent: parent.id, title: title) }
        var properties = meetingProperties(target: parent, date: date)
        properties[meetings.titleProperty] = ["title": [["text": ["content": String(title.prefix(500))]]]]
        let body: [String: Any] = ["parent": ["type": "data_source_id", "data_source_id": meetings.dataSourceID], "properties": properties, "notifications": ["mode": "silent"]]
        do {
            let response = try await request("POST", path: "pages", body: body)
            return try decodePage(response)
        } catch {
            // A bad optional field must not prevent the page itself from landing in
            // the meeting data source. A definite 4xx rejection is safe to retry with
            // the required title only; an ambiguous network result is left pending.
            guard let rejection = error as? NotionRequestFailure, rejection.definiteRejection, !properties.isEmpty else { throw error }
            let titleOnly: [String: Any] = ["parent": ["type": "data_source_id", "data_source_id": meetings.dataSourceID],
                                             "properties": [meetings.titleProperty: properties[meetings.titleProperty]!],
                                             "notifications": ["mode": "silent"]]
            let response = try await request("POST", path: "pages", body: titleOnly)
            return try decodePage(response)
        }
    }
    public func movePage(_ id: String, dataSourceID: String) async throws {
        _ = try await request("POST", path: "pages/" + normalized(id) + "/move", body: ["parent": ["type": "data_source_id", "data_source_id": normalized(dataSourceID)]])
    }
    private func meetingProperties(target: NotionPageTarget, date: Date?) -> [String: Any] {
        guard let meetings = target.meetings else { return [:] }
        var properties: [String: Any] = [:]
        if let courseProperty = meetings.courseProperty { properties[courseProperty] = ["relation": [["id": target.id]]] }
        if let dateProperty = meetings.dateProperty, let date { properties[dateProperty] = ["date": ["start": ISO8601DateFormatter().string(from: date)]] }
        if let type = meetings.typeProperty, let option = meetings.classroomOption { properties[type] = ["select": ["id": option]] }
        return properties
    }
    public func fillMeetingProperties(_ id: String, target: NotionPageTarget, date: Date?) async throws -> [String] {
        guard let meetings = target.meetings else { throw NotionFailure("没有会议绑定。") }
        let live = try await request("GET", path: "pages/" + normalized(id))
        guard try decodePage(live).parentDataSourceID == meetings.dataSourceID else { throw NotionFailure("页面已移到其他位置，未修改属性。") }
        let existing = live["properties"] as? [String: [String: Any]] ?? [:]
        func property(_ id: String) -> [String: Any]? { existing.values.first { $0["id"] as? String == id } }
        var warnings: [String] = []
        var properties = meetingProperties(target: target, date: date)
        if let courseProperty = meetings.courseProperty {
            let relation = property(courseProperty)
            if relation?["has_more"] as? Bool == true {
                warnings.append("课程关联较多，未覆盖原有关联")
                properties.removeValue(forKey: courseProperty)
                // Continue with date/type if those fields are available.
                if let dateProperty = meetings.dateProperty, property(dateProperty)?["date"] is [String: Any] { properties.removeValue(forKey: dateProperty) }
            }
            if relation?["has_more"] as? Bool != true {
                var ids = (relation?["relation"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                if !ids.contains(where: { UUID(uuidString: $0) == UUID(uuidString: target.id) }) { ids.append(target.id) }
                properties[courseProperty] = ["relation": ids.map { ["id": $0] }]
            }
        }
        // Fill only missing metadata; preserve an existing date/type selected in Notion.
        if let dateProperty = meetings.dateProperty, property(dateProperty)?["date"] is [String: Any] { properties.removeValue(forKey: dateProperty) }
        if let type = meetings.typeProperty, property(type)?["select"] is [String: Any] { properties.removeValue(forKey: type) }
        if !properties.isEmpty {
            do {
                _ = try await request("PATCH", path: "pages/" + normalized(id), body: ["properties": properties, "notifications": ["mode": "silent"]])
            } catch {
                // A single locked/renamed property should not invalidate the page
                // placement. Retry each field independently to salvage what is writable.
                for (key, value) in properties {
                    do { _ = try await request("PATCH", path: "pages/" + normalized(id), body: ["properties": [key: value], "notifications": ["mode": "silent"]]) }
                    catch { warnings.append("字段 \(key) 未能写入") }
                }
            }
        }
        let check = try await request("GET", path: "pages/" + normalized(id))
        let checked = check["properties"] as? [String: [String: Any]] ?? [:]
        guard try decodePage(check).parentDataSourceID == meetings.dataSourceID else {
            throw NotionFailure("会议位置尚未回读确认，请稍后重试。")
        }
        if let courseProperty = meetings.courseProperty {
            let linked = checked.values.first { $0["id"] as? String == courseProperty }?["relation"] as? [[String: Any]] ?? []
            if !linked.contains(where: { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: target.id) }) {
                warnings.append("课程关联待核对")
            }
        } else { warnings.append("未找到可用的课程关联字段") }
        if meetings.dateProperty == nil { warnings.append("未找到唯一的日期字段") }
        return warnings
    }
}
