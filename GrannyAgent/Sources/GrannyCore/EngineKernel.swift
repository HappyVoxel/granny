import Foundation

/// Validated `model.stream` invocation ready for async streaming over the wire.
public struct ValidatedModelStream: Equatable, Sendable {
    public var id: String
    public var apiKey: String
    public var model: String
    public var tier: String
    public var language: String
    public var messages: [EngineJSON]
    public var tools: [EngineJSON]?

    public init(
        id: String,
        apiKey: String,
        model: String,
        tier: String,
        language: String,
        messages: [EngineJSON],
        tools: [EngineJSON]? = nil
    ) {
        self.id = id
        self.apiKey = apiKey
        self.model = model
        self.tier = tier
        self.language = language
        self.messages = messages
        self.tools = tools
    }
}

/// What a single engine request produced against the kernel's day state.
/// Pure data: the socket server writes `reply` to the wire, persists `state`
/// when `mutated` is true, and hands `spokenText` to `Speaker` when non-nil.
public struct EngineOutcome: Equatable, Sendable {
    public var reply: EngineEnvelope
    public var spokenText: String?
    public var mutated: Bool
    public var startedRound: Bool
    public var emittedSpan: TraceClient.Span?
    public var modelStream: ValidatedModelStream?

    public init(
        reply: EngineEnvelope,
        spokenText: String? = nil,
        mutated: Bool = false,
        startedRound: Bool = false,
        emittedSpan: TraceClient.Span? = nil,
        modelStream: ValidatedModelStream? = nil
    ) {
        self.reply = reply
        self.spokenText = spokenText
        self.mutated = mutated
        self.startedRound = startedRound
        self.emittedSpan = emittedSpan
        self.modelStream = modelStream
    }
}

/// The capability kernel behind `<state dir>/engine.sock`.
///
/// Every rule in `docs/ENGINE.md` lives here as a pure function over
/// `(GrannyConfig, inout DayState)` so `GrannyCoreTests` can test the refusal
/// table, the quiet-hours clock, the daily nudge ceiling and the idempotency
/// window without opening a socket.
public enum EngineKernel {
    public static var defaultVersion: String { TraceClient.version }

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

    /// Resolves which `granny-engine` sidecar executable `EngineServer` should
    /// supervise: `GRANNY_ENGINE_PATH` wins (empty disables supervision), then
    /// `GRANNY_ENGINE_RESOURCES_DIR/engine/granny-engine` (the test seam), then
    /// the packaged app's `Contents/Resources/engine/granny-engine` outside CLI
    /// `--serve` runs.
    public static func resolveEnginePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        resourceURL: URL? = Bundle.main.resourceURL,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> String? {
        if let explicit = environment[GrannyEnv.enginePath] {
            return explicit.isEmpty ? nil : explicit
        }
        if let overrideResources = environment[GrannyEnv.engineResourcesDir],
           !overrideResources.isEmpty
        {
            let candidate = URL(fileURLWithPath: overrideResources)
                .appendingPathComponent("engine/granny-engine").path
            return isExecutable(candidate) ? candidate : nil
        }
        guard !arguments.contains("--serve"),
              bundleIdentifier == "io.github.happyvoxel.granny",
              let resourceURL
        else { return nil }
        let candidate = resourceURL.appendingPathComponent("engine/granny-engine").path
        return isExecutable(candidate) ? candidate : nil
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
        pomodoroRunning: Bool = false,
        pomodoroRemaining: TimeInterval? = nil,
        deviceContext: EngineDeviceContext = .empty,
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

        if capability == .deviceContext {
            let result = (try? EngineJSON.encoded(deviceContext)) ?? .object([
                "frontmostApp": .null,
                "openTabs": .array([]),
                "calendarEvents": .array([]),
            ])
            return EngineOutcome(reply: .reply(id: id, result: result))
        }

        if capability == .traceEmit {
            guard case .object(let spanFields) = fields["span"] else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("trace.emit requires span object")))
            }
            guard case .string(let rawName) = spanFields["name"] else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("span requires name")))
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("span requires name")))
            }
            let traceName: String
            if case .string(let rawTrace) = spanFields["traceName"],
               !rawTrace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                traceName = rawTrace.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                traceName = "granny.engine"
            }
            let model: String?
            if case .string(let rawModel) = spanFields["model"],
               !rawModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                model = nil
            }
            let startedAt = parseTimestamp(spanFields["startedAt"]) ?? now
            let rawEnded = parseTimestamp(spanFields["endedAt"]) ?? now
            let endedAt = max(startedAt, rawEnded)
            let span = TraceClient.Span(
                name: name,
                traceName: traceName,
                input: stringDictionary(from: spanFields["input"]),
                output: stringDictionary(from: spanFields["output"]),
                model: model,
                startedAt: startedAt,
                endedAt: endedAt)
            return EngineOutcome(reply: .reply(id: id, result: .object([:])), emittedSpan: span)
        }

        if capability == .modelStream {
            guard case .array(let messages) = fields["messages"], !messages.isEmpty else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("model.stream requires non-empty messages")))
            }
            var tools: [EngineJSON]?
            if let rawTools = fields["tools"], rawTools != .null {
                guard case .array(let parsedTools) = rawTools else {
                    return EngineOutcome(
                        reply: .failure(id: id, error: .invalid("tools must be an array")))
                }
                tools = parsedTools
            }
            guard OpenRouterClient.modelStreamRequestBody(
                model: config.model, messages: messages, tools: tools) != nil
            else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("invalid model.stream messages or tools")))
            }
            guard let rawKey = config.openRouterKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawKey.isEmpty
            else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .unavailable("OpenRouter key is not configured")))
            }
            let tier: String
            if case .string(let rawTier) = fields["tier"],
               !rawTier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                tier = rawTier.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                tier = "default"
            }
            let resolvedModel = OpenRouterClient.resolveModel(tier: tier, config: config)
            let stream = ValidatedModelStream(
                id: id,
                apiKey: rawKey,
                model: resolvedModel,
                tier: tier,
                language: config.language,
                messages: messages,
                tools: tools)
            return EngineOutcome(reply: .reply(id: id, result: .object([:])), modelStream: stream)
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
            state.takeCarriedFrogs()
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
            var candidate = state
            candidate.takeCarriedFrogs()
            guard let index = candidate.tasks.firstIndex(where: { $0.id == taskID }) else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("unknown task \(taskID)")))
            }
            candidate.tasks[index].done = done
            if candidate.allDone, !candidate.paid {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("finish one deep-work round first")))
            }
            state = candidate
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
            let currentSlotID = Schedule(slots: config.schedule)
                .current(at: now, calendar: calendar)?.id
            let openWork = state.tasks + state.carried
            let hasCurrentSlotTask = currentSlotID != nil && openWork.contains {
                !$0.done && $0.slotID == currentSlotID
            }
            let isCurrentSlotNudge = hasCurrentSlotTask && (reason == "slot" || {
                guard case .string(let slotID) = fields["slotID"] else {
                    return false
                }
                return slotID == currentSlotID
            }())
            if hasCurrentSlotTask, !isCurrentSlotNudge,
               state.nudgesSent >= config.nudgesPerDayMax - 1
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

        case .slotMove:
            guard case .string(let taskID) = fields["taskID"], !taskID.isEmpty else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .invalid("slot.move requires taskID")))
            }
            enum SlotTarget {
                case propose
                case clear
                case pin(String)
            }
            let target: SlotTarget
            if let rawSlot = fields["slotID"] {
                switch rawSlot {
                case .null:
                    target = .clear
                case .string(let candidate):
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        target = .clear
                    } else {
                        guard config.schedule.contains(where: { $0.id == trimmed }) else {
                            return EngineOutcome(
                                reply: .failure(id: id, error: .refused("unknown slot \(trimmed)")))
                        }
                        target = .pin(trimmed)
                    }
                default:
                    return EngineOutcome(
                        reply: .failure(id: id, error: .invalid("slotID must be a string or null")))
                }
            } else {
                target = .propose
            }

            var candidate = state
            candidate.takeCarriedFrogs()
            guard let index = candidate.tasks.firstIndex(where: { $0.id == taskID }) else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("unknown task \(taskID)")))
            }
            let schedule = Schedule(slots: config.schedule)
            switch target {
            case .pin(let slotID):
                candidate.tasks[index].slotID = slotID
            case .clear:
                candidate.tasks[index].slotID = nil
            case .propose:
                candidate.tasks[index].slotID = proposeSlots(
                    for: [candidate.tasks[index]], in: schedule)[taskID]
            }
            state = candidate
            let proposals: [EngineJSON] = state.tasks.map { item in
                .object([
                    "taskID": .string(item.id),
                    "slotID": item.slotID.map(EngineJSON.string) ?? .null,
                ])
            }
            let result: EngineJSON = .object(["proposals": .array(proposals)])
            state.recordAppliedKey(envelope.key, result: result)
            return EngineOutcome(reply: .reply(id: id, result: result), mutated: true)

        case .roundStart:
            guard state.pomodoro.stage == .deepWork else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("break in progress")))
            }
            guard !pomodoroRunning else {
                return EngineOutcome(
                    reply: .failure(id: id, error: .refused("round already running")))
            }
            let duration: TimeInterval
            if let remaining = pomodoroRemaining, remaining > 0 {
                duration = remaining
            } else {
                duration = TimeInterval(state.pomodoro.minutes(config.pomodoro) * 60)
            }
            let endsAt = iso8601Timestamp(now.addingTimeInterval(duration))
            let result: EngineJSON = .object([
                "stage": .string(state.pomodoro.stage.rawValue),
                "endsAt": .string(endsAt),
            ])
            let hasKey = !(envelope.key ?? "").isEmpty
            state.recordAppliedKey(envelope.key, result: result)
            return EngineOutcome(
                reply: .reply(id: id, result: result),
                mutated: hasKey,
                startedRound: true)

        default:
            return EngineOutcome(
                reply: .failure(id: id, error: .unavailable("\(capability.rawValue) is not available")))
        }
    }

    private static func iso8601Timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func parseTimestamp(_ raw: EngineJSON?) -> Date? {
        guard let raw else { return nil }
        switch raw {
        case .string(let text):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = fractional.date(from: text) { return parsed }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        case .number(let val):
            let seconds = val > 10_000_000_000 ? val / 1000.0 : val
            return Date(timeIntervalSince1970: seconds)
        default:
            return nil
        }
    }

    private static func stringDictionary(from raw: EngineJSON?) -> [String: String] {
        guard case .object(let map) = raw else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in map {
            switch value {
            case .string(let s): out[key] = s
            case .bool(let b): out[key] = b ? "true" : "false"
            case .number(let n):
                out[key] = (n.rounded() == n && abs(n) < 1e15) ? String(Int(n)) : String(n)
            case .null: out[key] = ""
            case .array, .object:
                if let data = try? JSONEncoder.engine.encode(value),
                   let text = String(data: data, encoding: .utf8)
                {
                    out[key] = text
                }
            }
        }
        return out
    }
}
