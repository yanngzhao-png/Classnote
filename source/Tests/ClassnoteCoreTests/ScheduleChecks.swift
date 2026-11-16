import Foundation
import ClassnoteCore

extension ClassnoteCoreTests {
    func scheduleDate(_ value: String, zone: String = "Europe/London") -> Date { ScheduleImporter.localDate(value, zone: TimeZone(identifier: zone)!)! }
    func scheduleSource() -> ScheduleSource {
        .init(name: "Synthetic timetable", kind: "ICS", from: scheduleDate("2026-10-01 00:00"), through: scheduleDate("2026-12-01 00:00"))
    }
    func calendarData(_ body: String) -> Data { Data(("BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR\n").replacingOccurrences(of: "\n", with: "\r\n").utf8) }
    func testScheduleICSRepeatsDSTAndExceptions() throws {
        let source = scheduleSource()
        let data = calendarData("""
        BEGIN:VEVENT
        UID:weekly
        DTSTART;TZID=Europe/London:20261019T090000
        DTEND;TZID=Europe/London:20261019T100000
        RRULE:FREQ=WEEKLY;COUNT=4;BYDAY=MO
        EXDATE;TZID=Europe/London:20261102T090000
        SUMMARY:Economics\\, lecture
        LOCATION:Room A
         1
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        RECURRENCE-ID;TZID=Europe/London:20261026T090000
        DTSTART;TZID=Europe/London:20261027T110000
        DTEND;TZID=Europe/London:20261027T120000
        SUMMARY:Economics\\, lecture
        END:VEVENT
        BEGIN:VEVENT
        UID:weekly
        RECURRENCE-ID;TZID=Europe/London:20261109T090000
        STATUS:CANCELLED
        END:VEVENT
        """)
        let result = try ScheduleImporter.ics(data, source: source, defaultZone: .current)
        checkEqual(result.events.count, 2)
        checkEqual(result.events[0].start, scheduleDate("2026-10-19 09:00"))
        checkEqual(result.events[1].start, scheduleDate("2026-10-27 11:00"))
        checkTrue(result.events[1].id.hasSuffix(String(Int(scheduleDate("2026-10-26 09:00").timeIntervalSince1970))))
        checkEqual(result.events[0].title, "Economics, lecture"); checkEqual(result.events[0].location, "Room A1")
        let plain = calendarData("""
        BEGIN:VEVENT
        UID:dst
        DTSTART;TZID=Europe/London:20261019T090000
        DTEND;TZID=Europe/London:20261019T100000
        RRULE:FREQ=WEEKLY;COUNT=3
        SUMMARY:DST
        END:VEVENT
        """)
        let events = try ScheduleImporter.ics(plain, source: source, defaultZone: .current).events
        checkEqual(events.count, 3); checkEqual(events[1].start.timeIntervalSince(events[0].start), 7*86400+3600)
        checkTrue(events.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
    }
    func testScheduleUTCIntervalUntilAndRejectedRules() throws {
        let source = scheduleSource()
        let body = """
        BEGIN:VEVENT
        UID:interval
        DTSTART:20261005T080000Z
        DURATION:PT50M
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE;UNTIL=20261102T080000Z
        SUMMARY:Study
        END:VEVENT
        """
        let events = try ScheduleImporter.ics(calendarData(body), source: source, defaultZone: .current).events
        checkEqual(events.count, 5); checkTrue(events.allSatisfy { $0.end.timeIntervalSince($0.start) == 3000 })
        for invalid in [body.replacingOccurrences(of: "FREQ=WEEKLY", with: "FREQ=MONTHLY"), body.replacingOccurrences(of: "Europe/London", with: "Invalid/Timezone").replacingOccurrences(of: "DTSTART:", with: "DTSTART;TZID=Not/AZone:"), body.replacingOccurrences(of: "BYDAY=MO,WE", with: "BYDAY=1MO")] {
            do { _ = try ScheduleImporter.ics(calendarData(invalid), source: source, defaultZone: .current); checkTrue(false) } catch {}
        }
        let allday = calendarData("BEGIN:VEVENT\nUID:holiday\nDTSTART;VALUE=DATE:20261112\nDTEND;VALUE=DATE:20261113\nSUMMARY:Holiday\nEND:VEVENT")
        let skipped = try ScheduleImporter.ics(allday, source: source, defaultZone: .current)
        checkTrue(skipped.events.isEmpty); checkEqual(skipped.warnings.count, 1)
        do { _ = try ScheduleImporter.ics(Data("BEGIN:VCALENDAR".utf8), source: source, defaultZone: .current); checkTrue(false) } catch {}
    }
    func testScheduleCSVEscapingZonesAndValidation() throws {
        let source = scheduleSource()
        let csv = "title,start,end,timezone,location\r\n\"Economics, A\",2026-11-12 09:00,2026-11-12 10:00,Asia/Shanghai,\"Room \"\"A\"\"\"\r\n"
        let values = try ScheduleImporter.csv(Data(csv.utf8), source: source, defaultZone: .current).events
        checkEqual(values.count, 1); checkEqual(values[0].title, "Economics, A"); checkEqual(values[0].location, "Room \"A\"")
        checkEqual(values[0].start, scheduleDate("2026-11-12 01:00"))
        for invalid in [csv.replacingOccurrences(of: "10:00", with: "08:00"), csv.replacingOccurrences(of: "Asia/Shanghai", with: "Bad/Zone"), csv.replacingOccurrences(of: "2026-11-12", with: "2026-02-30"), "title,start,end\n\"unclosed"] {
            do { _ = try ScheduleImporter.csv(Data(invalid.utf8), source: source, defaultZone: .current); checkTrue(false) } catch {}
        }
        checkNil(ScheduleImporter.localDate("2026-03-29 01:30", zone: TimeZone(identifier: "Europe/London")!))
    }
    func testScheduleMatchingAmbiguityBoundaryAndDisable() {
        let source = scheduleSource(); let course = Course(name: "Economics"), other = Course(name: "Media")
        var book = ScheduleBook(); book.sources = [source]
        let event = ScheduleEvent(id: "one", sourceID: source.id, title: "Lecture", start: scheduleDate("2026-11-12 09:00"), end: scheduleDate("2026-11-12 10:00"), timeZoneID: "Europe/London", courseID: course.id)
        book.events = [event]
        checkEqual(book.suggestedCourse(at: scheduleDate("2026-11-12 08:50"), courses: [course]), course.id)
        checkNil(book.suggestedCourse(at: scheduleDate("2026-11-12 08:49"), courses: [course]))
        checkNil(book.suggestedCourse(at: event.end, courses: [course]))
        var conflict = event; conflict.id = "two"; conflict.courseID = other.id; book.events.append(conflict)
        checkNil(book.suggestedCourse(at: event.start, courses: [course,other]))
        book.events[1].courseID = nil; checkNil(book.suggestedCourse(at: event.start, courses: [course,other]))
        book.events[1].courseID = course.id; checkEqual(book.suggestedCourse(at: event.start, courses: [course,other]), course.id)
        book.sources[0].enabled = false; checkTrue(book.candidates(at: event.start, courses: [course]).isEmpty)
        book.sources[0].enabled = true; checkNil(book.suggestedCourse(at: event.start, courses: []))
    }
    func testAutomaticCourseGroupingAndStableIdentity() throws {
        let source = scheduleSource()
        let titles = [
            "8DEMO101 FOUNDATIONS OF POLICY SY 000001/Lecture/01",
            "8DEMO101 FOUNDATIONS OF POLICY SY 000001/Sem/01 <07-11, 13-18>",
            "8DEMO101 FOUNDATIONS OF POLICY SY 000001/SmG/01",
            "8DEMO202 FOUNDATIONS OF POLICY SY 000001/Sem/01"
        ]
        let events = titles.enumerated().map { index, title in
            ScheduleEvent(id: "event-\(index)", sourceID: source.id, title: title, start: scheduleDate("2026-11-12 09:00").addingTimeInterval(Double(index * 3600)), end: scheduleDate("2026-11-12 10:00").addingTimeInterval(Double(index * 3600)), timeZoneID: "Europe/London")
        }
        let groups = ScheduleBook.courseGroups(events)
        checkEqual(groups.count, 2)
        checkEqual(groups.first(where: { $0.events.count == 3 })?.identity.name, "FOUNDATIONS OF POLICY")
        checkTrue(groups.allSatisfy { !$0.identity.name.contains(where: \.isNumber) })
        checkEqual(ScheduleCourseIdentity("ABC Academic writing skills PG <14>").name, "Academic writing skills PG")

        let existing = Course(name: "8DEMO101 FOUNDATIONS OF POLICY SY 000001/Lecture/01")
        var initial = ScheduleBook(); initial.sources = [source]; initial.events = events
        let grouped = initial.groupingCourses([existing])
        checkEqual(grouped.courses.count, 2)
        let firstID = grouped.book.events.first(where: { $0.id == "event-0" })?.courseID
        checkTrue(grouped.book.events.prefix(3).allSatisfy { $0.courseID == firstID })
        checkTrue(grouped.book.events.last?.courseID != firstID)
        let repeated = grouped.book.groupingCourses(grouped.courses)
        checkEqual(repeated.courses, grouped.courses)
        checkEqual(repeated.book.events, grouped.book.events)

        var legacyNames = grouped.courses
        if let index = legacyNames.firstIndex(where: { $0.id == firstID }) { legacyNames[index].name = "8DEMO101 FOUNDATIONS OF POLICY SY 000001/Lecture/01" }
        let cleanedLegacy = grouped.book.groupingCourses(legacyNames)
        checkEqual(cleanedLegacy.courses.first(where: { $0.id == firstID })?.name, "FOUNDATIONS OF POLICY")

        var renamed = grouped.courses
        if let index = renamed.firstIndex(where: { $0.id == firstID }) { renamed[index].name = "Custom course name" }
        let afterRename = grouped.book.groupingCourses(renamed)
        checkEqual(afterRename.book.events.first?.courseID, firstID)
        checkEqual(afterRename.courses.first(where: { $0.id == firstID })?.name, "Custom course name")
        var refreshed = afterRename.book
        var nextWeek = events[1]; nextWeek.id = "next-week"; nextWeek.start.addTimeInterval(7 * 86400); nextWeek.end.addTimeInterval(7 * 86400)
        refreshed.replace(source, with: [nextWeek])
        let refreshResult = refreshed.groupingCourses(afterRename.courses)
        checkEqual(refreshResult.book.events[0].courseID, firstID)
        checkEqual(refreshResult.courses, afterRename.courses)
        checkEqual(refreshResult.book.suggestedCourse(at: nextWeek.start, courses: refreshResult.courses), firstID)
        checkFalse(ScheduleCourseIdentity("History 1").key == ScheduleCourseIdentity("History 2").key)


        let duplicate = Course(name: "8DEMO101 FOUNDATIONS OF POLICY SY 000001/Sem/01")
        let migrated = initial.groupingCourses([existing, duplicate], protectedIDs: [duplicate.id])
        checkTrue(migrated.book.events.prefix(3).allSatisfy { $0.courseID == duplicate.id })
        checkFalse(migrated.courses.contains(where: { $0.id == existing.id }))
        checkTrue(migrated.redirects[existing.id] == duplicate.id)
        checkTrue(migrated.courses.contains(where: { $0.id == duplicate.id }))
    }
    func testScheduleGroupingJournalPreservesLectureFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root)
        let lecture = fixtureLecture(); try store.save(lecture)
        let file = store.directory(lecture.id).appendingPathComponent("lecture.json")
        let before = try Data(contentsOf: file)
        let source = scheduleSource()
        let event = ScheduleEvent(id: "event", sourceID: source.id, title: "Economics · Lecture", start: scheduleDate("2026-11-12 09:00"), end: scheduleDate("2026-11-12 10:00"), timeZoneID: "Europe/London")
        var initial = ScheduleBook(); initial.sources = [source]; initial.events = [event]
        let result = initial.groupingCourses([])
        try store.saveScheduleGrouping(result)
        checkEqual(try store.loadCourses(), result.courses)
        checkEqual(try store.loadSchedule(), result.book)
        checkEqual(try Data(contentsOf: file), before)
        checkFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".schedule-grouping.json").path))
        struct JournalFixture: Encodable { var courses: [Course]; var book: ScheduleBook }
        // Simulate interruption after the journal is committed but before the schedule is written.
        try store.saveSchedule(ScheduleBook())
        try JSONEncoder().encode(JournalFixture(courses: result.courses, book: result.book)).write(to: root.appendingPathComponent(".schedule-grouping.json"))
        checkEqual(try store.loadCourses(), result.courses)
        checkEqual(try store.loadSchedule(), result.book)
        checkEqual(try Data(contentsOf: file), before)

    }
    func testScheduleRefreshAndStoragePreserveRecords() throws {
        let source = scheduleSource(), course = Course(name: "Econ")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LectureStore(root: root); let lecture = fixtureLecture(); try store.save(lecture)
        let file = store.directory(lecture.id).appendingPathComponent("lecture.json"); let before = try Data(contentsOf: file)
        var event = ScheduleEvent(id: "one", sourceID: source.id, title: "Economics", start: scheduleDate("2026-11-12 09:00"), end: scheduleDate("2026-11-12 10:00"), timeZoneID: "Europe/London", courseID: course.id)
        var book = ScheduleBook(); book.replace(source, with: [event]); try store.saveSchedule(book)
        checkEqual(try store.loadSchedule(), book)
        event.courseID = nil; event.location = "Changed"
        book.replace(source, with: [event]); checkEqual(book.events.count, 1); checkEqual(book.events[0].courseID, course.id)
        book.replace(source, with: []); checkTrue(book.events.isEmpty); try store.saveSchedule(book)
        checkEqual(try Data(contentsOf: file), before)
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(".schedule.json"))
        do { _ = try store.loadSchedule(); checkTrue(false) } catch {}
        checkEqual(try String(contentsOf: root.appendingPathComponent(".schedule.json"), encoding: .utf8), "corrupt")
        checkEqual(try store.load().lectures.count, 1)
        let url = try ScheduleImporter.subscriptionURL("webcal://example.com/private.ics?token=test")
        checkEqual(url.scheme, "https")
        for invalid in ["http://example.com/test.ics", "file:///etc/passwd", "https://user:password@example.com/feed"] {
            do { _ = try ScheduleImporter.subscriptionURL(invalid); checkTrue(false) } catch {}
        }
    }
}
