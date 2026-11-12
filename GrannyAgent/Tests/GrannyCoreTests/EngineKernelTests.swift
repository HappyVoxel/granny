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

    func testTaskAddPullsCarriedFrogsIntoTasksSoAllDoneCannotSkipThem() {
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23)
        let frog = TaskItem(title: "Yesterday's frog", carriedOver: true)
        var state = DayState(
            date: "2026-11-10",
            carried: [frog],
            pomodoro: PomodoroRun(stage: .deepWork, finished: 1))

        let add = EngineKernel.handle(
            .request(
                id: "e-add",
                method: EngineCapability.stateTaskAdd.rawValue,
                params: .object(["title": .string("Today's task")]),
                key: "k-frog"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertTrue(add.mutated)
        XCTAssertTrue(state.carried.isEmpty)
        XCTAssertEqual(state.tasks.map(\.title), ["Yesterday's frog", "Today's task"])

        let addedID = state.tasks[1].id
        let tick = EngineKernel.handle(
            .request(
                id: "e-tick",
                method: EngineCapability.stateTaskTick.rawValue,
                params: .object(["taskID": .string(addedID), "done": .bool(true)]),
                key: "k-frog-tick"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(tick.reply.result, .object(["phase": .string("working")]))
        XCTAssertFalse(state.rewarded)
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
        let schedule = [
            ScheduleSlot(id: "morning", time: "09:00", label: "Deep work", tag: "deepWork"),
            ScheduleSlot(id: "afternoon", time: "15:00", label: "Admin", tag: "admin"),
        ]
        let config = GrannyConfig(
            wakeHour: 7, bedtimeHour: 22, schedule: schedule, nudgesPerDayMax: 2)

        // A task pinned to a later slot (15:00) does not suppress a free-form nudge at 10:00.
        let laterTask = TaskItem(title: "Admin", slotID: "afternoon")
        var laterState = DayState(
            date: "2026-11-10", greeted: true, tasks: [laterTask], nudgesSent: 1)
        let freeForm = EngineEnvelope.request(
            id: "p-1",
            method: EngineCapability.notifySpeak.rawValue,
            params: .object(["text": .string("Random nudge"), "reason": .string("idle")]))
        let allowedWhenFutureSlot = EngineKernel.handle(
            freeForm, config: config, state: &laterState, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(allowedWhenFutureSlot.spokenText, "Random nudge")

        // A carried frog pinned to the current slot (09:00 at 10:00) reserves the last nudge.
        let currentFrog = TaskItem(title: "Deep work", carriedOver: true, slotID: "morning")
        var state = DayState(
            date: "2026-11-10", greeted: true, carried: [currentFrog], nudgesSent: 1)
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

    func testDeviceContextReturnsSnapshotEvenOnDayOff() throws {
        let config = GrannyConfig()
        var state = DayState(date: "2026-11-10", dayOff: true)
        let snapshot = EngineDeviceContext(
            frontmostApp: .init(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
            openTabs: [.init(browser: "Safari", url: "https://swift.org", title: "Swift.org")],
            calendarEvents: [
                .init(
                    title: "Design review",
                    startAt: "2026-11-10T10:00:00Z",
                    endAt: "2026-11-10T10:30:00Z")
            ])

        let outcome = EngineKernel.handle(
            .request(id: "dc-1", method: EngineCapability.deviceContext.rawValue),
            config: config, state: &state, blocksEnforced: false,
            deviceContext: snapshot, now: date(hour: 10), calendar: calendar)
        XCTAssertNil(outcome.reply.error)
        let decoded = try outcome.reply.result?.decoded(as: EngineDeviceContext.self)
        XCTAssertEqual(decoded, snapshot)
    }

    func testSlotMovePinsClearsProposesAndRefusesUnknownSlot() {
        let schedule = [
            ScheduleSlot(id: "morning", time: "09:00", label: "Deep work", tag: "deepWork"),
            ScheduleSlot(id: "afternoon", time: "15:00", label: "Admin", tag: "admin"),
        ]
        let config = GrannyConfig(wakeHour: 7, bedtimeHour: 23, schedule: schedule)
        let task = TaskItem(title: "Apply 5 jobs")
        var state = DayState(date: "2026-11-10", greeted: true, tasks: [task])

        let bogus = EngineKernel.handle(
            .request(
                id: "sm-1",
                method: EngineCapability.slotMove.rawValue,
                params: .object(["taskID": .string(task.id), "slotID": .string("midnight")]),
                key: "k-sm-bogus"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(bogus.reply.error?.code, .refused)
        XCTAssertEqual(bogus.reply.error?.reason, "unknown slot midnight")

        let pinned = EngineKernel.handle(
            .request(
                id: "sm-2",
                method: EngineCapability.slotMove.rawValue,
                params: .object(["taskID": .string(task.id), "slotID": .string("morning")]),
                key: "k-sm-pin"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertTrue(pinned.mutated)
        XCTAssertEqual(state.tasks[0].slotID, "morning")
        XCTAssertEqual(
            pinned.reply.result,
            .object([
                "proposals": .array([
                    .object(["taskID": .string(task.id), "slotID": .string("morning")])
                ])
            ]))

        let cleared = EngineKernel.handle(
            .request(
                id: "sm-3",
                method: EngineCapability.slotMove.rawValue,
                params: .object(["taskID": .string(task.id), "slotID": .null]),
                key: "k-sm-clear"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertNil(state.tasks[0].slotID)
        XCTAssertEqual(
            cleared.reply.result,
            .object([
                "proposals": .array([
                    .object(["taskID": .string(task.id), "slotID": .null])
                ])
            ]))

        // Omitting slotID re-runs the keyword slot proposal ("Apply 5 jobs" -> admin -> afternoon).
        let proposed = EngineKernel.handle(
            .request(
                id: "sm-4",
                method: EngineCapability.slotMove.rawValue,
                params: .object(["taskID": .string(task.id)]),
                key: "k-sm-prop"),
            config: config, state: &state, blocksEnforced: true,
            now: date(hour: 10), calendar: calendar)
        XCTAssertNil(proposed.reply.error)
        XCTAssertEqual(state.tasks[0].slotID, "afternoon")
    }

    func testRoundStartEnforcesRunningAndBreakGuardsWithIdempotency() {
        let config = GrannyConfig(
            wakeHour: 7, bedtimeHour: 23, pomodoro: PomodoroConfig(workMinutes: 25))
        var state = DayState(date: "2026-11-10", greeted: true)
        let req = EngineEnvelope.request(
            id: "rs-1", method: EngineCapability.roundStart.rawValue, key: "k-rs-1")

        let started = EngineKernel.handle(
            req, config: config, state: &state, blocksEnforced: true,
            pomodoroRunning: false, now: date(hour: 10), calendar: calendar)
        XCTAssertTrue(started.startedRound)
        XCTAssertTrue(started.mutated)
        XCTAssertEqual(
            started.reply.result,
            .object([
                "stage": .string("deepWork"),
                "endsAt": .string("2026-11-10T10:25:00Z"),
            ]))

        // Retrying the same key while the round is running returns duplicate + original result.
        let retrySameKey = EngineKernel.handle(
            req, config: config, state: &state, blocksEnforced: true,
            pomodoroRunning: true, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(retrySameKey.reply.error?.code, .duplicate)
        XCTAssertEqual(retrySameKey.reply.error?.result, started.reply.result)

        // A fresh request while the round is running is refused.
        let whileRunning = EngineKernel.handle(
            .request(id: "rs-2", method: EngineCapability.roundStart.rawValue, key: "k-rs-2"),
            config: config, state: &state, blocksEnforced: true,
            pomodoroRunning: true, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(whileRunning.reply.error?.code, .refused)
        XCTAssertEqual(whileRunning.reply.error?.reason, "round already running")

        // A request during a break is refused even if paused.
        state.pomodoro = PomodoroRun(stage: .shortBreak, finished: 1)
        let onBreak = EngineKernel.handle(
            .request(id: "rs-3", method: EngineCapability.roundStart.rawValue, key: "k-rs-3"),
            config: config, state: &state, blocksEnforced: false,
            pomodoroRunning: false, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(onBreak.reply.error?.code, .refused)
        XCTAssertEqual(onBreak.reply.error?.reason, "break in progress")
    }

    func testTraceEmitBuildsSpanAndWorksOnDayOff() {
        let config = GrannyConfig()
        var state = DayState(date: "2026-11-10", dayOff: true)
        let outcome = EngineKernel.handle(
            .request(
                id: "tr-1",
                method: EngineCapability.traceEmit.rawValue,
                params: .object([
                    "span": .object([
                        "name": .string("proactive.check"),
                        "traceName": .string("granny.proactive"),
                        "model": .string("deepseek/deepseek-v4.1-flash"),
                        "input": .object(["slot": .string("morning"), "rounds": .number(0)]),
                        "output": .object(["action": .string("nudge")]),
                    ])
                ])),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(outcome.reply.result, .object([:]))
        XCTAssertEqual(outcome.emittedSpan?.name, "proactive.check")
        XCTAssertEqual(outcome.emittedSpan?.traceName, "granny.proactive")
        XCTAssertEqual(outcome.emittedSpan?.model, "deepseek/deepseek-v4.1-flash")
        XCTAssertEqual(outcome.emittedSpan?.input["rounds"], "0")
    }

    func testModelStreamValidatesKeyMessagesAndResolvesTiers() {
        var state = DayState(date: "2026-11-10", dayOff: true)
        let messages: [EngineJSON] = [
            .object(["role": .string("user"), "content": .string("Help me split this task")])
        ]

        // Missing OpenRouter key -> unavailable.
        let noKey = EngineKernel.handle(
            .request(
                id: "ms-1",
                method: EngineCapability.modelStream.rawValue,
                params: .object(["messages": .array(messages)])),
            config: GrannyConfig(openRouterKey: nil),
            state: &state, blocksEnforced: false, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(noKey.reply.error?.code, .unavailable)

        // Empty messages -> invalid.
        let emptyMessages = EngineKernel.handle(
            .request(
                id: "ms-2",
                method: EngineCapability.modelStream.rawValue,
                params: .object(["messages": .array([])])),
            config: GrannyConfig(openRouterKey: "sk-test"),
            state: &state, blocksEnforced: false, now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(emptyMessages.reply.error?.code, .invalid)

        // Tier resolution: default, fast (jevModel), free (streakModel).
        let config = GrannyConfig(
            openRouterKey: "sk-test",
            model: "deepseek/deepseek-v4.1-flash",
            streakModel: "openrouter/free-custom",
            jevModel: "typesafe/jev-router")

        let defaultTier = EngineKernel.handle(
            .request(
                id: "ms-3",
                method: EngineCapability.modelStream.rawValue,
                params: .object(["messages": .array(messages)])),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(defaultTier.modelStream?.model, "deepseek/deepseek-v4.1-flash")

        let fastTier = EngineKernel.handle(
            .request(
                id: "ms-4",
                method: EngineCapability.modelStream.rawValue,
                params: .object(["messages": .array(messages), "tier": .string("fast")])),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(fastTier.modelStream?.model, "typesafe/jev-router")

        let freeTier = EngineKernel.handle(
            .request(
                id: "ms-5",
                method: EngineCapability.modelStream.rawValue,
                params: .object(["messages": .array(messages), "tier": .string("free")])),
            config: config, state: &state, blocksEnforced: false,
            now: date(hour: 10), calendar: calendar)
        XCTAssertEqual(freeTier.modelStream?.model, "openrouter/free-custom")
    }

    func testResolveEnginePathHonoursOverridesBundleAndServeGuard() {
        let bundleResources = URL(fileURLWithPath: "/Applications/granny.app/Contents/Resources")
        let bundledPath = "/Applications/granny.app/Contents/Resources/engine/granny-engine"

        // Packaged app discovers bundled engine when executable.
        XCTAssertEqual(
            EngineKernel.resolveEnginePath(
                environment: [:],
                arguments: ["/Applications/granny.app/Contents/MacOS/granny-agent"],
                bundleIdentifier: "io.github.happyvoxel.granny",
                resourceURL: bundleResources,
                isExecutable: { $0 == bundledPath }),
            bundledPath)

        // Non-executable bundle entry falls back to nil.
        XCTAssertNil(
            EngineKernel.resolveEnginePath(
                environment: [:],
                arguments: ["/Applications/granny.app/Contents/MacOS/granny-agent"],
                bundleIdentifier: "io.github.happyvoxel.granny",
                resourceURL: bundleResources,
                isExecutable: { _ in false }))

        // CLI `--serve` stays stub-only unless an env override is set.
        XCTAssertNil(
            EngineKernel.resolveEnginePath(
                environment: [:],
                arguments: ["granny-agent", "--serve"],
                bundleIdentifier: "io.github.happyvoxel.granny",
                resourceURL: bundleResources,
                isExecutable: { _ in true }))

        // `GRANNY_ENGINE_RESOURCES_DIR` exercises bundle discovery even under `--serve`.
        XCTAssertEqual(
            EngineKernel.resolveEnginePath(
                environment: [GrannyEnv.engineResourcesDir: "/tmp/fake-resources"],
                arguments: ["granny-agent", "--serve"],
                bundleIdentifier: nil,
                resourceURL: nil,
                isExecutable: { $0 == "/tmp/fake-resources/engine/granny-engine" }),
            "/tmp/fake-resources/engine/granny-engine")

        // Explicit empty `GRANNY_ENGINE_PATH=""` disables bundled engine supervision.
        XCTAssertNil(
            EngineKernel.resolveEnginePath(
                environment: [GrannyEnv.enginePath: ""],
                arguments: ["/Applications/granny.app/Contents/MacOS/granny-agent"],
                bundleIdentifier: "io.github.happyvoxel.granny",
                resourceURL: bundleResources,
                isExecutable: { _ in true }))
    }
}
