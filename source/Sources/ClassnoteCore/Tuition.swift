import Foundation

public enum TuitionHoursSource: String, Codable, CaseIterable, Sendable { case timetable, manual }

/// A local estimate of tuition represented by recorded class time, not a payment or API cost.
public struct TuitionConfiguration: Codable, Equatable, Sendable {
    public var fee: Double = 0
    public var currency = "GBP"
    public var semesterStart: Date
    public var semesterEnd: Date
    /// Week 1 means the first week of the configured semester.
    /// Earlier weeks are treated as already completed before Classnote was used.
    public var usageStartWeek: Int = 1
    public var hoursSource: TuitionHoursSource = .timetable
    public var manualHours: Double = 0
    public var showsIndicator = true
    private enum CodingKeys: String, CodingKey {
        case fee, currency, semesterStart, semesterEnd, usageStartWeek, hoursSource, manualHours, showsIndicator
    }
    public init(now: Date = Date(), calendar: Calendar = .current) {
        semesterStart = calendar.startOfDay(for: now)
        semesterEnd = calendar.date(byAdding: .day, value: 119, to: semesterStart) ?? now
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fee = try container.decodeIfPresent(Double.self, forKey: .fee) ?? 0
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "GBP"
        semesterStart = try container.decodeIfPresent(Date.self, forKey: .semesterStart) ?? Date()
        semesterEnd = try container.decodeIfPresent(Date.self, forKey: .semesterEnd) ?? semesterStart
        usageStartWeek = try container.decodeIfPresent(Int.self, forKey: .usageStartWeek) ?? 1
        hoursSource = try container.decodeIfPresent(TuitionHoursSource.self, forKey: .hoursSource) ?? .timetable
        manualHours = try container.decodeIfPresent(Double.self, forKey: .manualHours) ?? 0
        showsIndicator = try container.decodeIfPresent(Bool.self, forKey: .showsIndicator) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fee, forKey: .fee)
        try container.encode(currency, forKey: .currency)
        try container.encode(semesterStart, forKey: .semesterStart)
        try container.encode(semesterEnd, forKey: .semesterEnd)
        try container.encode(usageStartWeek, forKey: .usageStartWeek)
        try container.encode(hoursSource, forKey: .hoursSource)
        try container.encode(manualHours, forKey: .manualHours)
        try container.encode(showsIndicator, forKey: .showsIndicator)
    }
    public func interval(calendar: Calendar = .current) -> DateInterval? {
        let start = calendar.startOfDay(for: semesterStart)
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: semesterEnd)),
              end > start, end.timeIntervalSince(start) <= 371 * 86400 else { return nil }
        return DateInterval(start: start, end: end)
    }
    public func semesterWeekCount(calendar: Calendar = .current) -> Int {
        guard let interval = interval(calendar: calendar) else { return 1 }
        return max(1, Int(ceil(interval.duration / (7 * 86400))))
    }
    public func usageInterval(calendar: Calendar = .current) -> DateInterval? {
        guard let semester = interval(calendar: calendar) else { return nil }
        let week = min(max(usageStartWeek, 1), semesterWeekCount(calendar: calendar))
        guard let start = calendar.date(byAdding: .day, value: (week - 1) * 7, to: semester.start), start < semester.end else { return nil }
        return DateInterval(start: start, end: semester.end)
    }
    public var hasValidFee: Bool { fee.isFinite && fee > 0 && fee <= 100_000_000 && ["GBP", "CNY", "USD", "EUR"].contains(currency) }
    public func money(_ amount: Double) -> String {
        guard amount.isFinite else { return "—" }
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = currency
        f.locale = Locale(identifier: "en_GB"); f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "—"
    }
}

public struct TuitionPlan: Equatable, Sendable {
    public var seconds: Double = 0
    public var classCount: Int = 0
    public var coversSemester = false
    public var hours: Double { seconds / 3600 }

    public init(configuration: TuitionConfiguration, schedule: ScheduleBook, calendar: Calendar = .current) {
        guard let semester = configuration.usageInterval(calendar: calendar),
              let fullSemester = configuration.interval(calendar: calendar) else { return }
        let sources = schedule.sources.filter(\.enabled)
        let enabled = Set(sources.map(\.id))
        let coverage = sources.compactMap { source -> DateInterval? in
            let start = max(source.from, semester.start), end = min(source.through, semester.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var coveredThrough = semester.start
        for range in coverage where range.start <= coveredThrough { coveredThrough = max(coveredThrough, range.end) }
        coversSemester = coveredThrough >= semester.end

        // The same course can appear in multiple imports. Count each overlapping interval once.
        var byCourse: [UUID: [DateInterval]] = [:]
        for event in schedule.events where enabled.contains(event.sourceID) {
            guard let course = event.courseID else { continue }
            let start = max(event.start, semester.start), end = min(event.end, semester.end)
            guard end > start else { continue }
            byCourse[course, default: []].append(DateInterval(start: start, end: end))
        }
        for ranges in byCourse.values {
            var merged: DateInterval?
            for range in ranges.sorted(by: { $0.start < $1.start }) {
                if let previous = merged, range.start < previous.end {
                    merged = DateInterval(start: previous.start, end: max(previous.end, range.end))
                } else {
                    if let previous = merged { seconds += previous.duration; classCount += 1 }
                    merged = range
                }
            }
            if let last = merged { seconds += last.duration; classCount += 1 }
        }
        if configuration.hoursSource == .manual {
            let valid = configuration.manualHours.isFinite && configuration.manualHours > 0 && configuration.manualHours <= 10000
            let remainingRatio = min(1, max(0, semester.duration / fullSemester.duration))
            seconds = valid ? configuration.manualHours * remainingRatio * 3600 : 0
            classCount = 0
        }
    }
    public func amount(seconds activeSeconds: Double, configuration: TuitionConfiguration) -> Double? {
        guard configuration.hasValidFee, seconds.isFinite, seconds > 0, activeSeconds.isFinite, activeSeconds >= 0 else { return nil }
        let result = configuration.fee * (activeSeconds / seconds)
        return result.isFinite ? result : nil
    }
    public static func includes(_ lecture: Lecture, configuration: TuitionConfiguration, calendar: Calendar = .current) -> Bool {
        guard let interval = configuration.usageInterval(calendar: calendar) else { return false }
        return lecture.startedAt >= interval.start && lecture.startedAt < interval.end
    }
    public static func recordedSeconds(_ lectures: [Lecture], configuration: TuitionConfiguration, calendar: Calendar = .current) -> Double {
        lectures.filter { !$0.isDemo && includes($0, configuration: configuration, calendar: calendar) }
            .reduce(0) { $0 + ($1.activeSeconds.isFinite ? max(0, $1.activeSeconds) : 0) }
    }
}

extension Lecture {
    public static func dateTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日"
        return f.string(from: date)
    }
    /// Legacy automatic names are shortened only at presentation; stored content is not migrated.
    public func displayTitle(courseName: String?) -> String {
        if hasAutomaticTitle == true { return Self.dateTitle(startedAt) }
        if hasAutomaticTitle == nil {
            let legacy = courseName.map { $0 + " · " + startedAt.formatted(.dateTime.month().day().hour().minute()) }
            if title == legacy || title == "未命名课堂" { return Self.dateTitle(startedAt) }
        }
        return title
    }
}
