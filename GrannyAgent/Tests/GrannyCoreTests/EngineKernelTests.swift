import XCTest
@testable import GrannyCore

final class EngineKernelTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func date(hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: 0))!
    }

    func testHandshakeAcceptsEngineAndReportsLimits() throws {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23, nudgesPerDayMax: 3)
        let state = DayState(date: "2026-11-10", nudgesSent: 1)
        let hello = EngineHello(role: .engine, impl: "pi-durable/0.1.0", capabilities: ["state.read"])
        let request = EngineEnvelope.request(
            id: "e-1", method: "hello", params: try EngineJSON.encoded(hello))

        let (reply, peer) = EngineKernel.hello(from: request, config: config, state: state)
        XCTAssertEqual(peer?.impl, "pi-durable/0.1.0")
        let kernel = try EngineHandshake.accept(reply, expecting: .kernel).get()
        XCTAssertEqual(kernel.limits?.nudgesRemaining, 2)
        XCTAssertEqual(kernel.limits?.quietStart, 23)
        XCTAssertEqual(kernel.limits?.quietEnd, 7)
    }

    func testHandshakeRefusesWrongProtocolVersion() throws {
        let hello = EngineHello(role: .engine, impl: "pi-durable/0.1.0", capabilities: [])
        let request = EngineEnvelope(
            v: 2, id: "e-1", method: "hello", params: try EngineJSON.encoded(hello))
        let (reply, peer) = EngineKernel.hello(
            from: request, config: GrannyConfig(), state: .fresh(date: "2026-11-10"))
        XCTAssertNil(peer)
        XCTAssertEqual(reply.error?.code, .refused)
    }

    func testTaskAddIsIdempotentOnKey() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23)
        var state = DayState.fresh(date: "2026-11-10")
        let request = EngineEnvelope.request(
            id: "e-2",
            method: EngineCapability.stateTaskAdd.rawValue,
            params: .object(["title": .string("Apply 5 jobs")]),
            key: "k-add-1")

        let first = EngineKernel.handle(
            request, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertTrue(first.mutated)
        XCTAssertEqual(state.tasks.count, 1)
        let firstResult = first.reply.result

        let second = EngineKernel.handle(
            request, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertFalse(second.mutated)
        XCTAssertEqual(state.tasks.count, 1)
        XCTAssertEqual(second.reply.error?.code, .duplicate)
        XCTAssertEqual(second.reply.error?.result, firstResult)
    }

    func testLastTaskTickRefusedWithoutARoundAndAllowedOncePaid() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23)
        let task = TaskItem(title: "Ship Slice 1")
        var state = DayState(date: "2026-11-10", greeted: true, tasks: [task])
        let tickRequest = EngineEnvelope.request(
            id: "e-3",
            method: EngineCapability.stateTaskTick.rawValue,
            params: .object(["taskID": .string(task.id), "done": .bool(true)]),
            key: "k-tick-1")

        let unpaid = EngineKernel.handle(
            tickRequest, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 11), calendar: calendar)
        XCTAssertFalse(unpaid.mutated)
        XCTAssertEqual(unpaid.reply.error?.code, .refused)
        XCTAssertFalse(state.tasks[0].done)

        state.pomodoro.finished = 1
        let paid = EngineKernel.handle(
            tickRequest, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 11), calendar: calendar)
        XCTAssertTrue(paid.mutated)
        XCTAssertTrue(state.tasks[0].done)
        XCTAssertEqual(paid.reply.result, .object(["phase": .string("rewarded")]))
    }

    func testNotifySpeakRespectsQuietHoursAndDailyBudget() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 22, nudgesPerDayMax: 2)
        var state = DayState.fresh(date: "2026-11-10")
        let speak = EngineEnvelope.request(
            id: "e-4",
            method: EngineCapability.notifySpeak.rawValue,
            params: .object(["text": .string("Start the first tomato"), "reason": .string("idle")]))

        let lateNight = EngineKernel.handle(
            speak, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 23), calendar: calendar)
        XCTAssertEqual(lateNight.reply.error?.code, .refused)
        XCTAssertEqual(lateNight.reply.error?.reason, "after quiet hours")
        XCTAssertNil(lateNight.spokenText)

        let first = EngineKernel.handle(
            speak, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(first.spokenText, "Start the first tomato")
        XCTAssertEqual(state.nudgesSent, 1)

        let second = EngineKernel.handle(
            speak, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 14), calendar: calendar)
        XCTAssertEqual(second.spokenText, "Start the first tomato")
        XCTAssertEqual(state.nudgesSent, 2)

        let overBudget = EngineKernel.handle(
            speak, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 15), calendar: calendar)
        XCTAssertEqual(overBudget.reply.error?.code, .refused)
        XCTAssertEqual(overBudget.reply.error?.reason, "nudge budget spent")
        XCTAssertNil(overBudget.spokenText)
    }

    func testQuietHoursPredicateTable() {
        // Overnight window (22 -> 7): 22 is inclusive, 7 is exclusive.
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 21, quietStart: 22, quietEnd: 7))
        XCTAssertTrue(EngineKernel.isQuietHour(hour: 22, quietStart: 22, quietEnd: 7))
        XCTAssertTrue(EngineKernel.isQuietHour(hour: 0, quietStart: 22, quietEnd: 7))
        XCTAssertTrue(EngineKernel.isQuietHour(hour: 6, quietStart: 22, quietEnd: 7))
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 7, quietStart: 22, quietEnd: 7))

        // Within-day window (1 -> 6): 1 is inclusive, 6 is exclusive.
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 0, quietStart: 1, quietEnd: 6))
        XCTAssertTrue(EngineKernel.isQuietHour(hour: 1, quietStart: 1, quietEnd: 6))
        XCTAssertTrue(EngineKernel.isQuietHour(hour: 5, quietStart: 1, quietEnd: 6))
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 6, quietStart: 1, quietEnd: 6))

        // Empty window (quietStart == quietEnd).
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 14, quietStart: 0, quietEnd: 0))
        XCTAssertFalse(EngineKernel.isQuietHour(hour: 14, quietStart: 14, quietEnd: 14))
    }

    func testDecodedConfigQuietHoursOverrideRefusesAfternoonNudge() throws {
        let raw = #"{"wakeHour":7,"bedtimeHour":23,"quietStart":14,"quietEnd":15}"#
        let config = try JSONDecoder().decode(GrannyConfig.self, from: Data(raw.utf8))
        var state = DayState.fresh(date: "2026-11-10")
        let afternoon = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 30))!
        let speak = EngineEnvelope.request(
            id: "q-1",
            method: EngineCapability.notifySpeak.rawValue,
            params: .object(["text": .string("Afternoon check"), "reason": .string("slot")]))
        let outcome = EngineKernel.handle(
            speak, config: config, state: &state, blocksEnforced: true,
            now: afternoon, calendar: calendar)
        XCTAssertEqual(outcome.reply.error?.code, .refused)
        XCTAssertEqual(outcome.reply.error?.reason, "after quiet hours")
    }

    func testSlotPinnedNudgeOutranksFreeFormNudgeAtBudgetEdge() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 22, nudgesPerDayMax: 2)
        let pinnedTask = TaskItem(title: "Deep work", slotID: "morning")
        var state = DayState(date: "2026-11-10", greeted: true, tasks: [pinnedTask], nudgesSent: 1)

        let freeForm = EngineEnvelope.request(
            id: "p-1",
            method: EngineCapability.notifySpeak.rawValue,
            params: .object(["text": .string("Random nudge"), "reason": .string("idle")]))
        let dropped = EngineKernel.handle(
            freeForm, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(dropped.reply.error?.code, .refused)
        XCTAssertEqual(dropped.reply.error?.reason, "nudge budget reserved for slot task")
        XCTAssertEqual(state.nudgesSent, 1)

        let slotNudge = EngineEnvelope.request(
            id: "p-2",
            method: EngineCapability.notifySpeak.rawValue,
            params: .object(["text": .string("Slot started"), "reason": .string("slot")]))
        let delivered = EngineKernel.handle(
            slotNudge, config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(delivered.spokenText, "Slot started")
        XCTAssertEqual(state.nudgesSent, 2)
    }

    func testDayOffRefusesMutationsWhileStateReadWorks() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23)
        var state = DayState(date: "2026-11-10", dayOff: true)

        let read = EngineKernel.handle(
            .request(id: "r-1", method: EngineCapability.stateRead.rawValue),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertNil(read.reply.error)

        let add = EngineKernel.handle(
            .request(
                id: "r-2",
                method: EngineCapability.stateTaskAdd.rawValue,
                params: .object(["title": .string("Work on day off")])),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(add.reply.error?.code, .refused)
        XCTAssertEqual(add.reply.error?.reason, "day off")
    }

    func testStaleDateIsRejectedAsRetryable() {
        let config = GrannyConfig()
        var state = DayState.fresh(date: "2026-11-10")
        let outcome = EngineKernel.handle(
            .request(
                id: "s-1",
                method: EngineCapability.stateTaskAdd.rawValue,
                params: .object(["date": .string("2026-11-09"), "title": .string("Old day")])),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(outcome.reply.error?.code, .stale)
        XCTAssertEqual(outcome.reply.error?.retryable, true)
    }

    func testIdempotencyWindowEvictsOldestKeys() {
        var state = DayState.fresh(date: "2026-11-10")
        for index in 1...5 {
            state.recordAppliedKey("k-\(index)", result: .number(Double(index)), window: 3)
        }
        XCTAssertNil(state.appliedResult(for: "k-1"))
        XCTAssertNil(state.appliedResult(for: "k-2"))
        XCTAssertEqual(state.appliedResult(for: "k-3"), .number(3))
        XCTAssertEqual(state.appliedResult(for: "k-5"), .number(5))
    }
}
