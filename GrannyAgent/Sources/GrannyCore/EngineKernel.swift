import Foundation

/// What a single engine request produced against the kernel's day state.
/// Pure data: the socket server writes `reply` to the wire, persists `state`
/// when `mutated` is true, and hands `spokenText` to `Speaker` when non-nil.
public struct EngineOutcome: Equatable, Sendable {
    public var reply: EngineEnvelope
    public var spokenText: String?
    public var mutated: Bool

    public init(reply: EngineEnvelope, spokenText: String? = nil, mutated: Bool = false) {
        self.reply = reply
        self.spokenText = spokenText
        self.mutated = mutated
    }
}

/// The capability kernel behind `<state dir>/engine.sock`.
///
/// Every rule in `docs/ENGINE.md` lives here as a pure function over
/// `(GrannyConfig, inout DayState)` so `GrannyCoreTests` can test the refusal
/// table, the quiet-hours clock, the daily nudge ceiling and the idempotency
/// window without opening a socket.
public enum EngineKernel {
    public static let defaultVersion = "0.1.2"

    public static var implVersion: String {
        if let bundleID = Bundle.main.bundleIdentifier,
           bundleID.hasPrefix("io.github.happyvoxel.granny"),
           let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !short.isEmpty
        {
            return "granny/\(short)"
        }
        return "granny/\(defaultVersion)"
    }

    /// Quiet hours may cross midnight (22 -> 7) or sit inside one day (1 -> 6).
    /// When start == end the window is empty.
    public static func isQuietHour(hour: Int, quietStart: Int, quietEnd: Int) -> Bool {
        guard quietStart != quietEnd else { return false }
        if quietStart < quietEnd {
            return hour >= quietStart && hour < quietEnd
        }
        return hour >= quietStart || hour < quietEnd
    }

    /// Validates the peer's opening `hello` and builds the kernel's answer.
    public static func hello(
        from envelope: EngineEnvelope,
        config: GrannyConfig,
        state: DayState
    ) -> (reply: EngineEnvelope, peer: EngineHello?) {
        let id = envelope.id ?? "hello"
        switch EngineHandshake.accept(envelope, expecting: .engine) {
        case .failure(.unsupportedVersion(let local, let remote)):
            return (
                .failure(
                    id: id,
                    error: .refused("protocol mismatch: kernel speaks v\(local), engine speaks v\(remote)")),
                nil
            )
        case .failure(.notAHello):
            return (.failure(id: id, error: .invalid("expected hello handshake")), nil)
        case .failure(.wrongRole(let role)):
            return (.failure(id: id, error: .invalid("expected engine role, got \(role.rawValue)")), nil)
        case .success(let peer):
            let kernelHello = EngineHello(
                role: .kernel,
                impl: implVersion,
                capabilities: EngineProtocol.available.map(\.rawValue).sorted(),
                limits: .init(
                    nudgesRemaining: max(0, config.nudgesPerDayMax - state.nudgesSent),
                    quietStart: config.effectiveQuietStart,
                    quietEnd: config.effectiveQuietEnd))
            let payload = (try? EngineJSON.encoded(kernelHello)) ?? .object([:])
            return (.reply(id: id, result: payload), peer)
        }
    }

    /// Evaluates one post-handshake request from the engine.
    public static func handle(
        _ envelope: EngineEnvelope,
        config: GrannyConfig,
        state: inout DayState,
        blocksEnforced: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EngineOutcome {
        let id = envelope.id ?? ""
        guard envelope.v == EngineProtocol.version else {
            return EngineOutcome(
                reply: .failure(
                    id: id,
                    error: .refused(
                        "protocol mismatch: kernel speaks v\(EngineProtocol.version), engine speaks v\(envelope.v)")))
        }
        guard !id.isEmpty, envelope.isRequest else {
            return EngineOutcome(reply: .failure(id: id, error: .invalid("request requires id and method")))
        }
        guard let capability = envelope.capability else {
            return EngineOutcome(
                reply: .failure(id: id, error: .invalid("unknown method \(envelope.method ?? "")")))
        }
        guard EngineProtocol.available.contains(capability) else {
            return EngineOutcome(
                reply: .failure(id: id, error: .unavailable("\(capability.rawValue) is not available")))
        }

        let fields: [String: EngineJSON]
        if case .object(let map) = envelope.params {
            fields = map
        } else {
            fields = [:]
        }

        if case .string(let expectedDate) = fields["date"], expectedDate != state.date {
            return EngineOutcome(
                reply: .failure(
                    id: id,
                    error: EngineError(
                        code: .stale,
                        reason: "day rolled over to \(state.date)",
                        retryable: true)))
        }

        if capability == .stateRead {
            let phase = computePhase(now: now, config: config, state: state, calendar: calendar)
            let tasksJSON: [EngineJSON] = state.tasks.map { task in
                var item: [String: EngineJSON] = [
                    "id": .string(task.id),
                    "title": .string(task.title),
                    "done": .bool(task.done),
                ]
                if let slotID = task.slotID { item["slotID"] = .string(slotID) }
                if let detail = task.detail { item["detail"] = .string(detail) }
                return .object(item)
            }
            let slotsJSON: [EngineJSON] = config.schedule.map { slot in
                .object([
                    "id": .string(slot.id),
                    "time": .string(slot.time),
                    "label": .string(slot.label),
                    "tag": .string(slot.tag),
                ])
            }
            let result: EngineJSON = .object([
                "phase": .string(phase.rawValue),
                "date": .string(state.date),
                "dayOff": .bool(state.dayOff),
                "tasks": .array(tasksJSON),
                "slots": .array(slotsJSON),
                "rounds": .number(Double(state.pomodoro.finished)),
                "streak": .number(Double(displayStreak(state: state, now: now, calendar: calendar))),
                "blocksEnforced": .bool(blocksEnforced),
                "nudgesRemaining": .number(Double(max(0, config.nudgesPerDayMax - state.nudgesSent))),
            ])
            return EngineOutcome(reply: .reply(id: id, result: result))
        }

        // Idempotency comes before mutations and budget checks so a retried
        // effect after a crash gets its original answer back.
        if let key = envelope.key, !key.isEmpty, let previous = state.appliedResult(for: key) {
            return EngineOutcome(reply: .failure(id: id, error: .duplicate(result: previous)))
        }

        if state.dayOff {
            return EngineOutcome(reply: .failure(id: id, error: .refused("day off")))
        }

        switch capability {
        case .stateTaskAdd:
            guard case .string(let rawTitle) = fields["title"] else {
                return EngineOutcome(reply: .failure(id: id, error: .invalid("missing title")))
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return EngineOutcome(reply: .failure(id: id, error: .refused("empty title")))
            }
            var slotID: String?
            if case .string(let candidate) = fields["slotID"], !candidate.isEmpty {
                guard config.schedule.contains(where: { $0.id == candidate }) else {
                    return EngineOutcome(
                        reply: .failure(id: id, error: .refused("unknown slot \(candidate)")))
                }
                slotID = candidate
            }
            var detail: String?
            if case .string(let rawDetail) = fields["detail"] {
                let trimmed = rawDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { detail = trimmed }
            }
            let surfaces = TaskParser.parse(title).first?.allowedSurfaces ?? []
            let task = TaskItem(
                title: title,
                allowedSurfaces: surfaces,
                slotID: slotID,
                detail: detail)
            state.tasks.append(task)
            state.greeted = true
            let result: EngineJSON = .object(["taskID": .string(task.id)])
            state.recordAppliedKey(envelope.key, result: result)
            return EngineOutcome(reply: .reply(id: id, result: result), mutated: true)

        case .stateTaskTick:
            guard case .string(let taskID) = fields["taskID"],
                  case .bool(let done) = fields["done"]
            else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("state.task.tick requires taskID and done")))
            }
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("unknown task \(taskID)")))
            }
            var candidate = state
            candidate.tasks[index].done = done
            if candidate.allDone, !candidate.paid {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("finish one deep-work round first")))
            }
            state.tasks[index].done = done
            let phase = computePhase(now: now, config: config, state: state, calendar: calendar)
            let result: EngineJSON = .object(["phase": .string(phase.rawValue)])
            state.recordAppliedKey(envelope.key, result: result)
            return EngineOutcome(reply: .reply(id: id, result: result), mutated: true)

        case .notifySpeak:
            guard case .string(let rawText) = fields["text"] else {
                return EngineOutcome(reply: .failure(id: id, error: .invalid("missing text")))
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return EngineOutcome(reply: .failure(id: id, error: .invalid("empty text")))
            }
            guard case .string(let rawReason) = fields["reason"] else {
                return EngineOutcome(reply: .failure(id: id, error: .invalid("missing reason")))
            }
            let reason = rawReason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else {
                return EngineOutcome(reply: .failure(id: id, error: .invalid("empty reason")))
            }
            let hour = calendar.component(.hour, from: now)
            if isQuietHour(
                hour: hour,
                quietStart: config.effectiveQuietStart,
                quietEnd: config.effectiveQuietEnd)
            {
                return EngineOutcome(reply: .failure(id: id, error: .refused("after quiet hours")))
            }
            guard state.nudgesSent < config.nudgesPerDayMax else {
                return EngineOutcome(reply: .failure(id: id, error: .refused("nudge budget spent")))
            }
            let hasPinnedOpenTask = state.tasks.contains {
                !$0.done && ($0.slotID?.isEmpty == false)
            }
            let isSlotPinned = reason == "slot" || {
                guard case .string(let slotID) = fields["slotID"], !slotID.isEmpty else {
                    return false
                }
                return state.tasks.contains { !$0.done && $0.slotID == slotID }
            }()
            if hasPinnedOpenTask, config.nudgesPerDayMax > 1,
               !isSlotPinned, state.nudgesSent >= config.nudgesPerDayMax - 1
            {
                return EngineOutcome(
                    reply: .failure(
                        id: id,
                        error: .refused("nudge budget reserved for slot task")))
            }
            state.nudgesSent += 1
            let result: EngineJSON = .object(["delivered": .bool(true)])
            state.recordAppliedKey(envelope.key, result: result)
            return EngineOutcome(
                reply: .reply(id: id, result: result),
                spokenText: text,
                mutated: true)

        default:
            return EngineOutcome(
                reply: .failure(id: id, error: .unavailable("\(capability.rawValue) is not available")))
        }
    }
}
