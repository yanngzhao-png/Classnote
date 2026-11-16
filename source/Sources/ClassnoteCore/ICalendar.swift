import Foundation

extension ScheduleImporter {
    private struct Property {
        var name: String; var params: [String: String]; var value: String
    }
    private struct IEvent {
        var fields: [Property]
        func one(_ key: String) -> Property? { fields.first { $0.name == key } }
        var uid: String { one("UID")?.value ?? "" }
        var cancelled: Bool { one("STATUS")?.value.uppercased() == "CANCELLED" }
        var sequence: Int { Int(one("SEQUENCE")?.value ?? "0") ?? 0 }
    }
    public static func ics(_ data: Data, source: ScheduleSource, defaultZone: TimeZone) throws -> ScheduleImport {
        try range(from: source.from, through: source.through)
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8), text.uppercased().contains("BEGIN:VCALENDAR"), text.uppercased().contains("END:VCALENDAR") else {
            throw CoursewareFailure("不是完整的 UTF-8 ICS 日历，或文件超过 5 MB。")
        }
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count-1] += line.dropFirst() }
            else { lines.append(line) }
        }
        var records: [IEvent] = [], fields: [Property] = [], inside = false, depth = 0
        var zone = defaultZone
        for line in lines {
            if line.uppercased() == "BEGIN:VEVENT" { guard !inside else { throw CoursewareFailure("ICS 事件嵌套无效。") }; inside = true; depth = 0; fields = []; continue }
            if line.uppercased() == "END:VEVENT" { guard inside else { throw CoursewareFailure("ICS 事件结尾无效。") }; records.append(.init(fields: fields)); inside = false; continue }
            guard let p = property(line) else { continue }
            if !inside { if p.name == "X-WR-TIMEZONE", let value = TimeZone(identifier: p.value) { zone = value }; continue }
            if p.name == "BEGIN" { depth += 1; continue }; if p.name == "END" { depth -= 1; continue }
            if depth == 0 { fields.append(p) }
        }
        guard !inside, records.count <= 10000 else { throw CoursewareFailure("ICS 不完整或事件过多。") }
        var masters: [String: IEvent] = [:], overrides: [String: [IEvent]] = [:]
        for event in records {
            guard !event.uid.isEmpty else { throw CoursewareFailure("有日历事件缺少 UID，无法安全更新。") }
            if event.one("RECURRENCE-ID") != nil { overrides[event.uid, default: []].append(event) }
            else if masters[event.uid].map({ $0.sequence <= event.sequence }) ?? true { masters[event.uid] = event }
        }
        var warnings: [String] = [], results: [String: ScheduleEvent] = [:]
        func make(_ event: IEvent, master: IEvent?, original: Date? = nil) throws -> ScheduleEvent? {
            guard let p = event.one("DTSTART") else { throw CoursewareFailure("日历事件缺少开始时间。") }
            if p.params["VALUE"] == "DATE" || !p.value.contains("T") { return nil }
            let (start, tz) = try date(p, defaultZone: zone)
            let title = unescape(event.one("SUMMARY")?.value ?? master?.one("SUMMARY")?.value ?? "未命名课程")
            guard !title.isEmpty else { throw CoursewareFailure("日历事件名称为空。") }
            let end: Date
            if let finish = event.one("DTEND") { end = try date(finish, defaultZone: tz).0 }
            else if let duration = event.one("DURATION") { end = start.addingTimeInterval(try seconds(duration.value)) }
            else if let master, let s = master.one("DTSTART"), let e = master.one("DTEND") {
                end = start.addingTimeInterval(try date(e, defaultZone: tz).0.timeIntervalSince(date(s, defaultZone: tz).0))
            } else { throw CoursewareFailure("「\(title)」缺少结束时间或时长。") }
            guard start < end, end.timeIntervalSince(start) <= 86400 else { throw CoursewareFailure("「\(title)」的课长无效，需在 24 小时内。") }
            return .init(id: eventID(source: source.id, uid: event.uid, original: original ?? start), sourceID: source.id, title: String(title.prefix(300)), start: start, end: end, timeZoneID: tz.identifier, location: unescape(event.one("LOCATION")?.value ?? master?.one("LOCATION")?.value ?? ""))
        }
        for (uid, master) in masters.sorted(by: { $0.key < $1.key }) where !master.cancelled {
            guard let base = try make(master, master: nil) else { warnings.append("已略过全天事件：\(unescape(master.one("SUMMARY")?.value ?? "未命名"))"); continue }
            let tz = TimeZone(identifier: base.timeZoneID)!
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = tz
            var excluded: Set<Date> = []
            for p in master.fields where p.name == "EXDATE" {
                for v in p.value.split(separator: ",") { var single = p; single.value = String(v); excluded.insert(try date(single, defaultZone: tz).0) }
            }
            var dates: [Date] = [base.start]
            if let rule = master.one("RRULE") {
                dates = try recurrence(rule.value, start: base.start, through: source.through, calendar: calendar)
            }
            for p in master.fields where p.name == "RDATE" {
                for v in p.value.split(separator: ",") { var single = p; single.value = String(v); dates.append(try date(single, defaultZone: tz).0) }
            }
            // Preserve wall-clock ending time across daylight-saving transitions.
            let daySpan = calendar.dateComponents([.day], from: calendar.startOfDay(for: base.start), to: calendar.startOfDay(for: base.end)).day ?? 0
            let ending = calendar.dateComponents([.hour,.minute,.second], from: base.end)
            for start in Set(dates) where !excluded.contains(start) {
                var endComponents = calendar.dateComponents([.year,.month,.day], from: calendar.date(byAdding: .day, value: daySpan, to: start)!)
                endComponents.hour = ending.hour; endComponents.minute = ending.minute; endComponents.second = ending.second
                guard let end = calendar.date(from: endComponents), end > start else { throw CoursewareFailure("重复课表遇到无效的夏令时，请调整日历。") }
                if start < source.through && end > source.from {
                    var value = base; value.start = start; value.end = end; value.id = eventID(source: source.id, uid: uid, original: start); results[value.id] = value
                }
            }
            // Changes and cancellations apply by original occurrence, including moved lessons.
            var changes: [Date: IEvent] = [:]
            for change in overrides[uid] ?? [] {
                let p = change.one("RECURRENCE-ID")!
                guard p.params["RANGE"] == nil else { throw CoursewareFailure("暂不支持 THISANDFUTURE 日历例外，请导出单次事件。") }
                let original = try date(p, defaultZone: tz).0
                if changes[original].map({ $0.sequence <= change.sequence }) ?? true { changes[original] = change }
            }
            for (original, change) in changes {
                let key = eventID(source: source.id, uid: uid, original: original); results.removeValue(forKey: key)
                if !change.cancelled, let value = try make(change, master: master, original: original), value.start < source.through, value.end > source.from { results[key] = value }
            }
            guard results.count <= 5000 else { throw CoursewareFailure("范围内超过 5,000 次课，请缩短导入日期。") }
        }
        // Detached exceptions sometimes appear without a recurring master.
        for (uid, changes) in overrides where masters[uid] == nil {
            for change in changes where !change.cancelled {
                let original = try date(change.one("RECURRENCE-ID")!, defaultZone: zone).0
                if let value = try make(change, master: nil, original: original), value.start < source.through, value.end > source.from { results[value.id] = value }
            }
        }
        return .init(events: results.values.sorted { $0.start < $1.start }, warnings: warnings)
    }
    private static func property(_ text: String) -> Property? {
        // Colons inside quoted TZID values do not delimit the property value.
        var quoted = false; var colon: String.Index?
        for index in text.indices { if text[index] == "\"" { quoted.toggle() }; if text[index] == ":" && !quoted { colon = index; break } }
        guard let colon else { return nil }
        let parts = text[..<colon].split(separator: ";").map(String.init)
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return .init(name: parts[0].uppercased(), params: params, value: String(text[text.index(after: colon)...]))
    }
    private static func unescape(_ text: String) -> String {
        var result = "", escape = false
        for c in text {
            if escape { result.append(c == "n" || c == "N" ? "\n" : c); escape = false }
            else if c == "\\" { escape = true } else { result.append(c) }
        }
        return result
    }
    private static func date(_ p: Property, defaultZone: TimeZone) throws -> (Date, TimeZone) {
        let aliases = ["GMT Standard Time":"Europe/London", "China Standard Time":"Asia/Shanghai", "Eastern Standard Time":"America/New_York", "Pacific Standard Time":"America/Los_Angeles", "W. Europe Standard Time":"Europe/Berlin"]
        let identifier = p.params["TZID"].map { aliases[$0] ?? $0 }
        guard let zone = identifier.map({ TimeZone(identifier: $0) }) ?? defaultZone else { throw CoursewareFailure("无法识别日历时区，请改用 IANA 时区名称。") }
        let utc = p.value.hasSuffix("Z"); let value = utc ? String(p.value.dropLast()) : p.value
        let actualZone = utc ? TimeZone(secondsFromGMT: 0)! : zone
        guard let result = localDate(value, zone: actualZone) else { throw CoursewareFailure("日历日期格式或夏令时时间无效：\(value)。") }
        return (result, actualZone)
    }
    private static func seconds(_ value: String) throws -> Double {
        let pattern = "^P(?:(\\d+)W)?(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?$"
        let re = try NSRegularExpression(pattern: pattern); let ns = value as NSString
        guard let match = re.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { throw CoursewareFailure("不支持该日历时长格式。") }
        let units: [Double] = [604800,86400,3600,60,1]
        return units.enumerated().reduce(0) { sum,item in let r = match.range(at: item.offset + 1); return sum + (r.location == NSNotFound ? 0 : (Double(ns.substring(with: r)) ?? 0) * item.element) }
    }
    private static func recurrence(_ rule: String, start: Date, through: Date, calendar: Calendar) throws -> [Date] {
        var parts: [String:String] = [:]
        for part in rule.uppercased().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1); guard pair.count == 2, parts[String(pair[0])] == nil else { throw CoursewareFailure("重复规则格式无效。") }; parts[String(pair[0])] = String(pair[1])
        }
        guard Set(parts.keys).isSubset(of: ["FREQ","INTERVAL","BYDAY","UNTIL","COUNT","WKST"]), let freq = parts["FREQ"], ["WEEKLY","DAILY"].contains(freq), let interval = Int(parts["INTERVAL"] ?? "1"), (1...365).contains(interval), let count = Int(parts["COUNT"] ?? "20000"), (1...20000).contains(count) else {
            throw CoursewareFailure("该日历含暂不支持的重复规则。支持每日／每周及间隔、结束日期、次数、例外日期；本次没有写入课表。")
        }
        let weekdays = ["SU":1,"MO":2,"TU":3,"WE":4,"TH":5,"FR":6,"SA":7]
        let byday = parts["BYDAY"].map { $0.split(separator: ",").map(String.init) } ?? []
        guard byday.allSatisfy({ weekdays[$0] != nil }), let weekStart = weekdays[parts["WKST"] ?? "MO"] else { throw CoursewareFailure("暂不支持带序号的重复星期。") }
        let until: Date
        if let value = parts["UNTIL"] {
            if value.count == 8 {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.dateFormat = "yyyyMMdd"; f.isLenient = false
                guard let date = f.date(from: value), f.string(from: date) == value else { throw CoursewareFailure("重复截止日期无效。") }; until = calendar.date(byAdding: .day, value: 1, to: date)!.addingTimeInterval(-1)
            } else { until = try date(.init(name: "UNTIL", params: [:], value: value), defaultZone: calendar.timeZone).0 }
        } else { until = through }
        let startDay = calendar.startOfDay(for: start), startWeekday = calendar.component(.weekday, from: start)
        let anchor = (startWeekday - weekStart + 7) % 7
        let wanted = Set(byday.isEmpty ? [startWeekday] : byday.compactMap { weekdays[$0] })
        let time = calendar.dateComponents([.hour,.minute,.second], from: start)
        let days = calendar.dateComponents([.day], from: startDay, to: min(through, until)).day ?? 0
        guard days <= 36600 else { throw CoursewareFailure("重复课表跨度过长，请重新导出近期课程。") }
        if days < 0 { return [] }
        var values: [Date] = []; var occurrences = 0
        for offset in 0...days {
            let day = calendar.date(byAdding: .day, value: offset, to: startDay)!
            let weekday = calendar.component(.weekday, from: day)
            let matches = freq == "DAILY" ? offset % interval == 0 && (byday.isEmpty || wanted.contains(weekday)) : ((offset + anchor) / 7) % interval == 0 && wanted.contains(weekday)
            guard matches else { continue }
            var c = calendar.dateComponents([.year,.month,.day], from: day); c.hour = time.hour; c.minute = time.minute; c.second = time.second
            guard let value = calendar.date(from: c), calendar.component(.hour, from: value) == time.hour else { throw CoursewareFailure("重复课程遇到不存在的夏令时时刻。") }
            guard value >= start, value <= until else { continue }
            occurrences += 1; if occurrences > count { break }; values.append(value)
        }
        return values
    }
}
