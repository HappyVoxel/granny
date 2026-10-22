import XCTest
@testable import GrannyCore

final class ScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private func at(hour: Int, minute: Int = 0) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }

    private func schedule() -> Schedule {
        Schedule(slots: [
            ScheduleSlot(time: "09:00", label: "Làm việc — deep work", tag: SlotKind.deepWork.rawValue),
            ScheduleSlot(time: "12:00", label: "Ăn trưa", tag: SlotKind.rest.rawValue),
            ScheduleSlot(time: "13:00", label: "Làm việc", tag: SlotKind.deepWork.rawValue),
            ScheduleSlot(time: "15:00", label: "Apply jobs", tag: SlotKind.admin.rawValue),
        ])
    }

    func testTimeParsing() {
        XCTAssertEqual(Schedule.minute(of: "09:00"), 540)
        XCTAssertEqual(Schedule.minute(of: "00:00"), 0)
        XCTAssertEqual(Schedule.minute(of: "23:59"), 23 * 60 + 59)
        XCTAssertNil(Schedule.minute(of: "24:00"))
        XCTAssertEqual(Schedule.minute(of: "9:0"), 540, "a text field is not a form")
        XCTAssertEqual(Schedule.minute(of: "6.30"), 390, "6.30 is how a Vietnamese writes it")
        XCTAssertEqual(Schedule.normalized("6.30"), "06:30")
        XCTAssertNil(Schedule.minute(of: ""))
        XCTAssertNil(Schedule.minute(of: "nine"))
    }

    func testTimesAreNormalisedForTheFile() {
        XCTAssertEqual(Schedule.normalized("9:0"), "09:00")
        XCTAssertEqual(Schedule.normalized("09:05"), "09:05")
        XCTAssertEqual(Schedule.normalized("noon"), "noon", "unreadable input is left alone")
    }

    func testSortedSkipsUnreadableHours() {
        let broken = Schedule(slots: [
            ScheduleSlot(time: "noon", label: "x", tag: SlotKind.rest.rawValue),
            ScheduleSlot(time: "09:00", label: "work", tag: SlotKind.deepWork.rawValue),
        ])
        XCTAssertEqual(broken.sorted.map(\.time), ["09:00"])
    }

    func testCurrentIsTheLastSlotThatStarted() {
        let schedule = schedule()
        XCTAssertNil(schedule.current(at: at(hour: 8), calendar: calendar),
                     "before the first slot is not late, it is early")
        XCTAssertEqual(schedule.current(at: at(hour: 9, minute: 30), calendar: calendar)?.time, "09:00")
        XCTAssertEqual(schedule.current(at: at(hour: 12, minute: 59), calendar: calendar)?.time, "12:00")
        XCTAssertEqual(schedule.current(at: at(hour: 15), calendar: calendar)?.time, "15:00")
        XCTAssertEqual(schedule.current(at: at(hour: 23), calendar: calendar)?.time, "15:00",
                       "after the last slot the day is still inside it")
    }

    func testKindFromTheTaskWords() {
        XCTAssertEqual(kindOf(TaskItem(title: "Apply job tại ABB")), .admin)
        XCTAssertEqual(kindOf(TaskItem(title: "Deliver feature mới cho granny")), .deepWork)
        XCTAssertEqual(kindOf(TaskItem(title: "Đọc sách")), .learn)
        XCTAssertEqual(kindOf(TaskItem(title: "Đi gym")), .body)
        XCTAssertEqual(kindOf(TaskItem(title: "Nộp hồ sơ thuế")), .admin)
        XCTAssertEqual(kindOf(TaskItem(title: "Học thêm một kỹ năng")), .learn)
        XCTAssertEqual(kindOf(TaskItem(title: "Viết nhật ký")), .journal)
        XCTAssertEqual(kindOf(TaskItem(title: "Journal before bed")), .journal)
        XCTAssertEqual(kindOf(TaskItem(title: "Viết feature mới cho granny")), .deepWork,
                       "one journal word cannot outvote two work words")
        XCTAssertEqual(kindOf(TaskItem(title: "Gọi mẹ")), .deepWork,
                       "no recognisable word lands at the desk, the safer default")
    }

    func testProposalUsesTheMatchingHoursOneEach() {
        let tasks = [
            TaskItem(title: "Deliver feature mới cho granny"),
            TaskItem(title: "Polish HuggerHustle"),
            TaskItem(title: "Apply job tại ABB"),
        ]
        let schedule = self.schedule()
        let proposal = proposeSlots(for: tasks, in: schedule)
        let byTime = Dictionary(uniqueKeysWithValues: schedule.slots.map { ($0.id, $0.time) })
        XCTAssertEqual(proposal.count, 3)
        XCTAssertEqual(proposal[tasks[0].id].flatMap { byTime[$0] }, "09:00")
        XCTAssertEqual(proposal[tasks[1].id].flatMap { byTime[$0] }, "13:00",
                       "the second deep-work task takes the second deep-work hour")
        XCTAssertEqual(proposal[tasks[2].id].flatMap { byTime[$0] }, "15:00")
    }

    func testPhrasesCountDoubleAndSingleWordsDoNot() {
        XCTAssertEqual(kindOf(TaskItem(title: "Viết lách buổi tối")), .journal,
                       "a two-word phrase outranks the bare verb")
        XCTAssertEqual(kindOf(TaskItem(title: "Viết báo cáo tuần")), .deepWork)
        XCTAssertEqual(kindOf(TaskItem(title: "Deep work session")), .deepWork)
    }

    func testTimesWithStraySpaceStillParse() {
        XCTAssertEqual(Schedule.minute(of: "09:00 "), 540)
        XCTAssertEqual(Schedule.minute(of: " 6.30"), 390)
    }

    func testTasksOnADeletedHourAreReleased() {
        let schedule = self.schedule()
        let kept = TaskItem(title: "Apply job", slotID: schedule.slots[1].id)
        let orphan = TaskItem(title: "Old hour", slotID: "gone")
        let result = droppingUnknownSlots([kept, orphan], in: schedule)
        XCTAssertEqual(result[0].slotID, schedule.slots[1].id)
        XCTAssertNil(result[1].slotID)
        XCTAssertEqual(result[1].title, "Old hour", "the task survives, only the hour goes")
    }

    func testAnOldConfigKeepsItsColours() throws {
        let raw = Data(#"{"schedule":[{"time":"09:00","label":"Work","kind":"journal"}]}"#.utf8)
        let config = try JSONDecoder().decode(GrannyConfig.self, from: raw)
        XCTAssertEqual(config.schedule.first?.tag, SlotKind.journal.rawValue)
        XCTAssertEqual(config.tags.count, SlotTag.defaults.count,
                       "no tags key in the file still means the seven built-ins")
    }

    func testTagColourParsing() {
        XCTAssertEqual(SlotTag(id: "x", color: "#D1A85C").rgb?.red ?? 0, 209.0 / 255, accuracy: 0.001)
        XCTAssertNil(SlotTag(id: "x", color: "gold").rgb, "unreadable colour falls back, never traps")
        XCTAssertNil(SlotTag(id: "x", color: "#12345").rgb)
        XCTAssertEqual(SlotTag.defaults.count, SlotKind.allCases.count)
        XCTAssertTrue(SlotTag.defaults.allSatisfy { $0.rgb != nil })
    }

    func testACustomTagIsNotMatchable() {
        let custom = SlotTag(id: "custom-1", name: "Reading", color: "#7EA0C8")
        XCTAssertNil(custom.kind, "only the built-ins can be guessed from a task's words")
        XCTAssertEqual(custom.displayName, "Reading")
    }

    func testProposalSkipsHoursWithNoMatch() {
        let schedule = Schedule(slots: [
            ScheduleSlot(time: "09:00", label: "Làm việc", tag: SlotKind.deepWork.rawValue),
        ])
        let tasks = [TaskItem(title: "Apply job tại ABB")]
        XCTAssertTrue(proposeSlots(for: tasks, in: schedule).isEmpty,
                      "an admin task is not shoved into the deep-work hour")
    }

    func testMoreTasksThanHoursReusesTheFirst() {
        let schedule = Schedule(slots: [
            ScheduleSlot(time: "09:00", label: "Làm việc", tag: SlotKind.deepWork.rawValue),
        ])
        let tasks = [TaskItem(title: "Feature A"), TaskItem(title: "Feature B")]
        XCTAssertEqual(proposeSlots(for: tasks, in: schedule).count, 2)
    }

    func testSlotSurvivesAnOldStateFile() throws {
        let old = """
        {"id":"1","title":"Apply job","done":false}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(TaskItem.self, from: old)
        XCTAssertNil(task.slotID)
        XCTAssertEqual(task.title, "Apply job")
    }

    func testNudgedOffSlotIsLenient() throws {
        let old = """
        {"date":"2026-02-10","greeted":true}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(DayState.self, from: old)
        XCTAssertEqual(state.nudgedOffSlot, [])
    }

    func testScheduleSurvivesAHandEditedConfig() throws {
        let raw = """
        {"schedule":[{"time":"09:00","label":"Work","kind":"deepWork"},
                     {"time":"broken","label":"Fix me"}]}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(GrannyConfig.self, from: raw)
        XCTAssertEqual(config.schedule.count, 2)
        XCTAssertEqual(config.schedule.first?.tag, SlotKind.deepWork.rawValue)
        XCTAssertEqual(config.schedule.last?.tag, SlotKind.admin.rawValue,
                       "a missing tag falls back")
        XCTAssertNil(config.schedule.last?.minute)
    }
}
