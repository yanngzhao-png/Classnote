import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func tuitionFixture() -> (TuitionConfiguration, Calendar) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/London")!
        var configuration = TuitionConfiguration(now: scheduleDate("2026-11-01 00:00"), calendar: calendar)
        configuration.semesterEnd = scheduleDate("2026-11-30 00:00"); configuration.fee = 12000
        return (configuration, calendar)
    }
    func testTuitionScheduleDurationsDuplicatesAndSemesterBounds() {
        let (configuration, calendar) = tuitionFixture()
        let first = ScheduleSource(name: "Primary", kind: "ics", from: scheduleDate("2026-10-01 00:00"), through: scheduleDate("2026-12-01 00:00"))
        let second = ScheduleSource(name: "Copy", kind: "ics", from: first.from, through: first.through)
        var disabled = ScheduleSource(name: "Disabled", kind: "ics", from: first.from, through: first.through); disabled.enabled = false
        let course = UUID()
        func event(_ id: String, _ source: UUID, _ start: String, _ end: String, assigned: Bool = true) -> ScheduleEvent {
            .init(id: id, sourceID: source, title: "Synthetic course", start: scheduleDate(start), end: scheduleDate(end), timeZoneID: "Europe/London", courseID: assigned ? course : nil)
        }
        var book = ScheduleBook(); book.sources = [first, second, disabled]
        book.events = [
            event("a", first.id, "2026-11-12 09:00", "2026-11-12 09:50"),
            event("duplicate", second.id, "2026-11-12 09:00", "2026-11-12 09:50"),
            event("b", first.id, "2026-11-13 09:00", "2026-11-13 10:40"),
            event("clipped", first.id, "2026-10-31 23:30", "2026-11-01 00:30"),
            event("disabled", disabled.id, "2026-11-14 09:00", "2026-11-14 10:00"),
            event("outside", first.id, "2026-12-01 00:00", "2026-12-01 01:00"),
            event("unassigned", first.id, "2026-11-15 09:00", "2026-11-15 10:00", assigned: false)
        ]
        let plan = TuitionPlan(configuration: configuration, schedule: book, calendar: calendar)
        checkEqual(plan.seconds, 10800); checkEqual(plan.classCount, 3); checkTrue(plan.coversSemester)
        book.sources[0].through = scheduleDate("2026-11-20 00:00"); book.sources[1].through = book.sources[0].through
        checkFalse(TuitionPlan(configuration: configuration, schedule: book, calendar: calendar).coversSemester)
    }
    func testTuitionManualRateAndInvalidInputs() {
        var (configuration, calendar) = tuitionFixture()
        configuration.hoursSource = .manual; configuration.manualHours = 160
        let plan = TuitionPlan(configuration: configuration, schedule: .init(), calendar: calendar)
        checkEqual(plan.amount(seconds: 3000, configuration: configuration), 62.5)
        checkEqual(plan.amount(seconds: 2400, configuration: configuration), 50)
        checkEqual(plan.amount(seconds: 0, configuration: configuration), 0)
        checkNil(plan.amount(seconds: -.infinity, configuration: configuration))
        checkNil(plan.amount(seconds: .nan, configuration: configuration))
        configuration.fee = -1; checkNil(plan.amount(seconds: 3000, configuration: configuration))
        configuration.fee = .infinity; checkNil(plan.amount(seconds: 3000, configuration: configuration))
        configuration.fee = 12000; configuration.manualHours = 0
        checkNil(TuitionPlan(configuration: configuration, schedule: .init(), calendar: calendar).amount(seconds: 3000, configuration: configuration))
        configuration.semesterEnd = scheduleDate("2026-10-01 00:00"); checkNil(configuration.interval(calendar: calendar))
    }
    func testTuitionUsesActiveTimeAndExcludesDemoOutsideTerm() {
        let (configuration, calendar) = tuitionFixture()
        var paused = Lecture(title: "Synthetic paused"); paused.startedAt = scheduleDate("2026-11-12 09:00"); paused.activeSeconds = 3000; paused.state = .paused
        var ended = Lecture(title: "Synthetic ended"); ended.startedAt = scheduleDate("2026-11-13 09:00"); ended.activeSeconds = 120; ended.state = .ended
        var demo = paused; demo.id = UUID(); demo.isDemo = true; demo.activeSeconds = 99999
        var outside = paused; outside.id = UUID(); outside.startedAt = scheduleDate("2026-12-01 00:00")
        var invalid = paused; invalid.id = UUID(); invalid.activeSeconds = .nan
        checkEqual(TuitionPlan.recordedSeconds([paused, ended, demo, outside, invalid], configuration: configuration, calendar: calendar), 3120)
        checkFalse(TuitionPlan.includes(outside, configuration: configuration, calendar: calendar))
        paused.activeSeconds = 3060
        checkEqual(TuitionPlan.recordedSeconds([paused], configuration: configuration, calendar: calendar), 3060)
    }
    func testTuitionConfigurationRoundTrip() throws {
        var (configuration, _) = tuitionFixture(); configuration.currency = "CNY"; configuration.showsIndicator = false
        let data = try JSONEncoder().encode(configuration)
        checkEqual(try JSONDecoder().decode(TuitionConfiguration.self, from: data), configuration)
        checkTrue(configuration.money(62.5).contains("62.50"))
    }
    func testTuitionUsageStartWeekExcludesEarlierLessonsAndLegacyDefaults() throws {
        var (configuration, calendar) = tuitionFixture()
        let source = ScheduleSource(name: "Primary", kind: "ics", from: scheduleDate("2026-11-01 00:00"), through: scheduleDate("2026-12-01 00:00"))
        let course = UUID()
        func event(_ id: String, _ day: String) -> ScheduleEvent {
            .init(id: id, sourceID: source.id, title: "Economics", start: scheduleDate(day + " 09:00"), end: scheduleDate(day + " 10:00"), timeZoneID: "Europe/London", courseID: course)
        }
        var book = ScheduleBook(); book.sources = [source]
        book.events = [event("week1", "2026-11-02"), event("week2", "2026-11-09"), event("week3", "2026-11-16")]
        configuration.usageStartWeek = 2
        let plan = TuitionPlan(configuration: configuration, schedule: book, calendar: calendar)
        checkEqual(plan.seconds, 7200)
        checkEqual(plan.classCount, 2)
        var earlier = Lecture(title: "Earlier"); earlier.startedAt = scheduleDate("2026-11-02 09:00"); earlier.activeSeconds = 3600
        var later = Lecture(title: "Later"); later.startedAt = scheduleDate("2026-11-09 09:00"); later.activeSeconds = 3600
        checkEqual(TuitionPlan.recordedSeconds([earlier, later], configuration: configuration, calendar: calendar), 3600)
        configuration.hoursSource = .manual; configuration.manualHours = 100
        let manual = TuitionPlan(configuration: configuration, schedule: .init(), calendar: calendar)
        checkTrue(manual.hours < 100 && manual.hours > 0)
        let legacy: [String: Any] = ["fee": 100.0, "currency": "GBP", "semesterStart": configuration.semesterStart.timeIntervalSince1970, "semesterEnd": configuration.semesterEnd.timeIntervalSince1970]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let decoded = try JSONDecoder().decode(TuitionConfiguration.self, from: data)
        checkEqual(decoded.usageStartWeek, 1)
    }
    func testDateOnlyDefaultsPreserveCustomAndLegacyData() throws {
        let date = scheduleDate("2026-11-12 09:00")
        var lecture = Lecture(title: "Economics · " + date.formatted(.dateTime.month().day().hour().minute()))
        lecture.startedAt = date
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(lecture)
        checkEqual(lecture.displayTitle(courseName: "Economics"), Lecture.dateTitle(date))
        checkEqual(try encoder.encode(lecture), original)
        let legacy = try JSONDecoder().decode(Lecture.self, from: original)
        checkNil(legacy.hasAutomaticTitle)
        lecture.hasAutomaticTitle = false
        checkEqual(lecture.displayTitle(courseName: "Economics"), lecture.title)
        lecture.title = "My custom title"
        checkEqual(lecture.displayTitle(courseName: "Economics"), "My custom title")
        lecture.hasAutomaticTitle = true
        checkEqual(lecture.displayTitle(courseName: "Renamed course"), Lecture.dateTitle(date))
        checkEqual(Lecture.dateTitle(date), "2026年11月12日")
    }
}
