import Foundation

/// The wire contract between the kernel (the app - the only authority) and
/// `granny-engine` (the harness). Written before any engine exists, so the
/// runtime stays a decision about glue: see `docs/ENGINE.md`.
///
/// The shape is deliberately dull - newline-delimited JSON, one object per
/// line - because the engine is written in another language and must be
/// debuggable with `nc -U` and `cat`.
public enum EngineProtocol {
    /// Bumped only when a method's absence changes behaviour; additive
    /// methods do not bump it. A mismatch is fatal rather than negotiated:
    /// two versions guessing at each other is how a coach says the wrong thing.
    public static let version = 1

    /// Methods the kernel currently serves. Growth is per slice, so an engine
    /// asking for something designed-but-unbuilt is refused with `unavailable`
    /// instead of hanging or half-applying.
    public static let available: Set<EngineCapability> = [.stateRead, .modelStream]
}

/// A minimal JSON tree. The envelope has to carry payloads it does not
/// understand yet (a new engine's params, a tool result), so it cannot be
/// fully typed; typed structs decode out of this per method.
public enum EngineJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([EngineJSON])
    case object([String: EngineJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([EngineJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: EngineJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // 1 stays 1: a fixture that turns into 1.0 after a round trip is a
            // diff nobody asked for, and an engine comparing text would break.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// Every method the engine may ask for. The kernel re-validates the params of
/// each one; this list is the vocabulary, not a permission.
public enum EngineCapability: String, CaseIterable, Codable, Sendable {
    case stateRead = "state.read"
    case stateTaskAdd = "state.task.add"
    case stateTaskTick = "state.task.tick"
    case slotMove = "slot.move"
    case roundStart = "round.start"
    case notifySpeak = "notify.speak"
    case traceEmit = "trace.emit"
    case modelStream = "model.stream"
}

public struct EngineError: Codable, Equatable, Sendable {
    public enum Code: String, Codable, Sendable {
        case refused
        case invalid
        case stale
        case duplicate
        case unavailable
        case `internal`
    }

    public var code: Code
    public var reason: String
    public var retryable: Bool
    /// A `duplicate` hands back what the first attempt produced, so a resumed
    /// run can continue without repeating the effect.
    public var result: EngineJSON?

    public init(code: Code, reason: String, retryable: Bool = false, result: EngineJSON? = nil) {
        self.code = code
        self.reason = reason
        self.retryable = retryable
        self.result = result
    }

    public static func refused(_ reason: String) -> EngineError {
        EngineError(code: .refused, reason: reason)
    }

    public static func invalid(_ reason: String) -> EngineError {
        EngineError(code: .invalid, reason: reason)
    }

    public static func unavailable(_ reason: String) -> EngineError {
        EngineError(code: .unavailable, reason: reason)
    }

    public static func duplicate(result: EngineJSON? = nil) -> EngineError {
        EngineError(code: .duplicate, reason: "key already applied", result: result)
    }
}

/// One line on the wire: a request (has `method`), a reply (has `result` or
/// `error`), or a push (has `event`). Optional fields are omitted, because an
/// explicit `"result": null` reads like a value and is not one.
public struct EngineEnvelope: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String?
    /// Idempotency key, minted per intended effect and reused across retries.
    public var key: String?
    public var method: String?
    public var params: EngineJSON?
    public var result: EngineJSON?
    public var event: String?
    public var error: EngineError?

    public init(
        v: Int = EngineProtocol.version,
        id: String? = nil,
        key: String? = nil,
        method: String? = nil,
        params: EngineJSON? = nil,
        result: EngineJSON? = nil,
        event: String? = nil,
        error: EngineError? = nil
    ) {
        self.v = v
        self.id = id
        self.key = key
        self.method = method
        self.params = params
        self.result = result
        self.event = event
        self.error = error
    }

    public static func request(
        id: String, method: String, params: EngineJSON? = nil, key: String? = nil
    ) -> EngineEnvelope {
        EngineEnvelope(id: id, key: key, method: method, params: params)
    }

    public static func reply(id: String, result: EngineJSON) -> EngineEnvelope {
        EngineEnvelope(id: id, result: result)
    }

    public static func failure(id: String, error: EngineError) -> EngineEnvelope {
        EngineEnvelope(id: id, error: error)
    }

    public static func push(event: String, params: EngineJSON) -> EngineEnvelope {
        EngineEnvelope(params: params, event: event)
    }

    public var isRequest: Bool { method != nil }

    public var isReply: Bool { method == nil && event == nil && (result != nil || error != nil) }

    /// The capability this request names, or nil when the engine invented one.
    public var capability: EngineCapability? {
        method.flatMap(EngineCapability.init(rawValue:))
    }

    public enum CodingKeys: String, CodingKey {
        case v, id, key, method, params, result, event, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = try container.decode(Int.self, forKey: .v)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(EngineJSON.self, forKey: .params)
        result = try container.decodeIfPresent(EngineJSON.self, forKey: .result)
        event = try container.decodeIfPresent(String.self, forKey: .event)
        error = try container.decodeIfPresent(EngineError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(event, forKey: .event)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// The first exchange. A mismatch is reported, never negotiated.
public struct EngineHello: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case engine
        case kernel
    }

    public struct Limits: Codable, Equatable, Sendable {
        /// How many times the engine may ask to speak today. The kernel owns
        /// this number; the engine may read it, not raise it.
        public var nudgesRemaining: Int
        public var quietStart: Int?
        public var quietEnd: Int?

        public init(nudgesRemaining: Int, quietStart: Int? = nil, quietEnd: Int? = nil) {
            self.nudgesRemaining = nudgesRemaining
            self.quietStart = quietStart
            self.quietEnd = quietEnd
        }
    }

    public var role: Role
    public var impl: String
    public var capabilities: [String]
    public var limits: Limits?

    public init(role: Role, impl: String, capabilities: [String], limits: Limits? = nil) {
        self.role = role
        self.impl = impl
        self.capabilities = capabilities
        self.limits = limits
    }
}

public enum EngineHandshakeFailure: Error, Equatable {
    case unsupportedVersion(local: Int, remote: Int)
    case notAHello
    case wrongRole(EngineHello.Role)
}

public enum EngineHandshake {
    /// Validates the peer's opening line. Version first: a peer from another
    /// protocol has no business being interpreted.
    public static func accept(
        _ envelope: EngineEnvelope, expecting role: EngineHello.Role
    ) -> Result<EngineHello, EngineHandshakeFailure> {
        guard envelope.v == EngineProtocol.version else {
            return .failure(.unsupportedVersion(local: EngineProtocol.version, remote: envelope.v))
        }
        if envelope.isRequest, envelope.method != "hello" { return .failure(.notAHello) }
        // A hello arrives as params when the peer opens, and as result when it
        // answers ours; both are the same payload.
        guard let payload = envelope.params ?? envelope.result,
              case let .object(fields) = payload,
              let hello = try? EngineJSON.object(fields).decoded(as: EngineHello.self)
        else { return .failure(.notAHello) }
        guard hello.role == role else { return .failure(.wrongRole(hello.role)) }
        return .success(hello)
    }
}

extension EngineJSON {
    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: try JSONEncoder.engine.encode(self))
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> EngineJSON {
        try JSONDecoder().decode(EngineJSON.self, from: try JSONEncoder.engine.encode(value))
    }
}

extension JSONEncoder {
    /// Sorted keys and unescaped slashes: two encoders of the same envelope
    /// produce identical bytes, so a fixture diff means a real change.
    static let engine: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}

/// Newline framing. One envelope per line, no length prefix: the socket is
/// local and a human may be reading it.
public enum EngineLine {
    public static func encode(_ envelope: EngineEnvelope) throws -> String {
        String(decoding: try JSONEncoder.engine.encode(envelope), as: UTF8.self)
    }

    public static func decode(_ line: String) throws -> EngineEnvelope {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "empty line"))
        }
        return try JSONDecoder().decode(EngineEnvelope.self, from: Data(trimmed.utf8))
    }
}
