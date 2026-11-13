import Darwin
import Foundation
import GrannyCore

/// Local Unix-socket server (`<state dir>/engine.sock`, mode 0600) that sits
/// between `GrannyCore` and `granny-engine` (Pi Durable, or the Node stub in
/// `tests/e2e-engine.sh`).
///
/// The kernel never blocks on the engine: if no process is connected, or the
/// child crashes mid-stream, the day, the blocks and `/decide` keep running.
final class EngineServer: @unchecked Sendable {
    enum Status: Equatable {
        case absent
        case ready(impl: String)
        case degraded(reason: String)
    }

    private static let promptTimeout: TimeInterval = 30
    private static let maxRestartAttempts = 6
    private static let maxEngineLogBytes: UInt64 = 5 * 1024 * 1024

    private let socketURL: URL
    private let configProvider: () -> GrannyConfig
    private let stateStore: StateStore
    private let enforcementProvider: () -> Bool
    private let pomodoroProvider: () -> (running: Bool, remaining: TimeInterval?)
    private let deviceContextProvider: () -> EngineDeviceContext
    private let traceProvider: () -> TraceClient?
    private let onStartRound: (() -> Void)?
    private let onSpeak: ((String) -> Void)?
    private let onMutated: (() -> Void)?
    private let onStatusChange: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "io.github.happyvoxel.granny.engine-io")
    private let statusLock = NSLock()
    private var _status: Status = .absent
    private var listenFD: Int32 = -1
    private var boundInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var engineFD: Int32 = -1
    private var activePromptWaiters: [String: (EngineEnvelope) -> Void] = [:]
    private var activeModelStreams: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var stopped = false

    private var childProcess: Process?
    private let supervisedEnginePath: String?
    private var restartAttempt = 0
    private var lastDayWokeDate: String?

    var currentStatus: Status {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _status
    }

    private func setStatus(_ newValue: Status) {
        statusLock.lock()
        let changed = _status != newValue
        _status = newValue
        statusLock.unlock()
        if changed, let onStatusChange {
            DispatchQueue.main.async(execute: onStatusChange)
        }
    }

    init(
        socketURL: URL = GrannyPaths.engineSocketURL,
        resourceURL: URL? = Bundle.main.resourceURL,
        configProvider: @escaping () -> GrannyConfig,
        stateStore: StateStore,
        enforcementProvider: @escaping () -> Bool,
        pomodoroProvider: @escaping () -> (running: Bool, remaining: TimeInterval?) = { (false, nil) },
        deviceContextProvider: @escaping () -> EngineDeviceContext = { DeviceContextCollector.snapshot() },
        traceProvider: @escaping () -> TraceClient? = { nil },
        onStartRound: (() -> Void)? = nil,
        onSpeak: ((String) -> Void)? = nil,
        onMutated: (() -> Void)? = nil,
        onStatusChange: (() -> Void)? = nil
    ) {
        self.socketURL = socketURL
        self.configProvider = configProvider
        self.stateStore = stateStore
        self.enforcementProvider = enforcementProvider
        self.pomodoroProvider = pomodoroProvider
        self.deviceContextProvider = deviceContextProvider
        self.traceProvider = traceProvider
        self.onStartRound = onStartRound
        self.onSpeak = onSpeak
        self.onMutated = onMutated
        self.onStatusChange = onStatusChange
        self.supervisedEnginePath = EngineKernel.resolveEnginePath(resourceURL: resourceURL)
    }

    deinit {
        stop()
    }

    func start() throws {
        GrannyPaths.ensureDirectories()
        let path = socketURL.path

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8CString)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count <= maxLen else {
            throw NSError(
                domain: "granny",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "engine.sock path exceeds sun_path (\(utf8.count) bytes)"])
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                for (index, byte) in utf8.enumerated() {
                    dst[index] = byte
                }
            }
        }

        // Never unlink a socket another live granny-agent still owns.
        var existing = stat()
        if Darwin.lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFSOCK, !Self.isSocketLive(addr: &addr) else {
                throw NSError(
                    domain: "granny",
                    code: Int(EADDRINUSE),
                    userInfo: [NSLocalizedDescriptionKey: "another granny owns \(path)"])
            }
            unlink(path)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "socket(AF_UNIX) failed"])
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "bind(\(path)) failed"])
        }

        guard Darwin.chmod(path, mode_t(0o600)) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            unlink(path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "chmod(\(path), 0600) failed"])
        }

        var boundStat = stat()
        if Darwin.lstat(path, &boundStat) == 0 {
            self.boundInode = boundStat.st_ino
        }

        guard Darwin.listen(fd, 16) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            unlink(path)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "listen(\(path)) failed"])
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        self.listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.acceptSource = source

        spawnEngineIfConfigured()
    }

    func stop() {
        ioQueue.sync {
            stopped = true
            for entry in activeModelStreams.values { entry.task.cancel() }
            activeModelStreams.removeAll()
            if engineFD >= 0 {
                _ = Darwin.shutdown(engineFD, SHUT_RDWR)
                engineFD = -1
            }
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            if let child = childProcess, child.isRunning {
                child.terminate()
            }
            childProcess = nil
            if boundInode != 0 {
                var current = stat()
                if Darwin.lstat(socketURL.path, &current) == 0, current.st_ino == boundInode {
                    unlink(socketURL.path)
                }
                boundInode = 0
            }
        }
    }

    private static func isSocketLive(addr: inout sockaddr_un) -> Bool {
        let probe = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { Darwin.close(probe) }
        let flags = fcntl(probe, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(probe, F_SETFL, flags | O_NONBLOCK) }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(probe, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return true }
        let err = errno
        return err != ECONNREFUSED && err != ENOENT
    }

    /// Pushes a kernel domain event (`day.woke`, `slot.entered`, `round.idle`,
    /// `round.finished`, `warn.continued`, `day.rollover`) to the connected
    /// engine, if one is present.
    func push(domainEvent: EngineDomainEvent, params: EngineJSON) {
        let envelope = EngineEnvelope.push(domainEvent: domainEvent, params: params)
        ioQueue.async { [weak self] in
            guard let self, self.engineFD >= 0 else { return }
            if !self.writeLine(envelope, to: self.engineFD) {
                _ = Darwin.shutdown(self.engineFD, SHUT_RDWR)
                self.engineFD = -1
                self.setStatus(.degraded(reason: "engine write timed out"))
            }
        }
    }

    /// Emits `day.woke` at most once per calendar date, and only once an engine
    /// has completed its `hello` handshake.
    func pushDayWokeIfNeeded() {
        let state = stateStore.state
        let config = configProvider()
        guard computePhase(config: config, state: state, calendar: stateStore.calendar) == .awaitingTasks,
              lastDayWokeDate != state.date,
              case .ready = currentStatus
        else { return }
        lastDayWokeDate = state.date
        push(
            domainEvent: .dayWoke,
            params: .object([
                "date": .string(state.date),
                "frogs": .number(Double(state.carried.count)),
            ]))
    }

    /// Sends `chat.prompt` to the connected engine and streams deltas back.
    func prompt(
        id: String = "c-\(UUID().uuidString.prefix(8))",
        text: String,
        reasoning: Bool = false,
        onEvent: @escaping (EngineEnvelope) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.engineFD >= 0 else {
                onEvent(
                    .failure(
                        id: id,
                        error: .unavailable("engine is not connected")))
                return
            }
            self.activePromptWaiters[id] = onEvent
            let request = EngineEnvelope.request(
                id: id,
                method: "chat.prompt",
                params: .object([
                    "text": .string(text),
                    "stream": .bool(true),
                    "reasoning": .bool(reasoning),
                ]))
            if !self.writeLine(request, to: self.engineFD) {
                self.activePromptWaiters.removeValue(forKey: id)
                onEvent(
                    .failure(
                        id: id,
                        error: EngineError(
                            code: .internal,
                            reason: "engine disconnected",
                            retryable: false)))
            }
        }
    }

    /// Cancels an in-flight `chat.prompt` run on the connected engine.
    func abort(id: String, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else {
                completion?(false)
                return
            }
            guard let waiter = self.activePromptWaiters.removeValue(forKey: id),
                  self.engineFD >= 0
            else {
                completion?(false)
                return
            }
            let request = EngineEnvelope.request(
                id: id,
                method: "chat.abort",
                params: .object(["id": .string(id)]))
            let sent = self.writeLine(request, to: self.engineFD)
            waiter(.reply(id: id, result: .object(["aborted": .bool(sent)])))
            completion?(sent)
        }
    }

    // MARK: - Child supervision

    private func spawnEngineIfConfigured() {
        guard let enginePath = supervisedEnginePath else { return }
        ioQueue.async { [weak self] in
            self?.launchEngineProcess(at: enginePath)
        }
    }

    private func launchEngineProcess(at path: String) {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let hostEnv = ProcessInfo.processInfo.environment
        let basePath = hostEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var env: [String: String] = [
            GrannyEnv.engineSocket: socketURL.path,
            "PATH": "\(basePath):/opt/homebrew/bin:/usr/local/bin",
        ]
        for key in ["HOME", "TMPDIR", "LANG", GrannyEnv.node, GrannyEnv.engineStorageDir] {
            if let value = hostEnv[key] { env[key] = value }
        }
        for (key, value) in hostEnv where key.hasPrefix("GRANNY_TEST_") {
            env[key] = value
        }
        process.environment = env
        let logURL = socketURL.deletingLastPathComponent().appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        if let logHandle {
            if ((try? logHandle.seekToEnd()) ?? 0) > Self.maxEngineLogBytes {
                try? logHandle.truncate(atOffset: 0)
            }
            process.standardError = logHandle
        }
        process.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            self?.ioQueue.async { [weak self] in
                self?.scheduleRestart(at: path, exitStatus: code)
            }
        }
        do {
            try process.run()
            self.childProcess = process
        } catch {
            self.setStatus(.degraded(reason: "failed to launch engine: \(error.localizedDescription)"))
            scheduleRestart(at: path, exitStatus: nil)
        }
    }

    private func scheduleRestart(at path: String, exitStatus: Int32?) {
        guard !stopped else { return }
        let logURL = socketURL.deletingLastPathComponent().appendingPathComponent("engine.log")
        if let exitStatus, currentStatus == .absent {
            setStatus(.degraded(reason: "engine exited (\(exitStatus)); see \(logURL.path)"))
        }
        guard restartAttempt < Self.maxRestartAttempts else {
            let suffix = exitStatus.map { " (exit \($0))" } ?? ""
            let reason = "engine failed after \(Self.maxRestartAttempts) attempts\(suffix); see \(logURL.path)"
            setStatus(.degraded(reason: reason))
            appendEngineLog(reason)
            return
        }
        let delay = min(10.0, 0.25 * pow(2.0, Double(min(restartAttempt, 5))))
        restartAttempt += 1
        ioQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.launchEngineProcess(at: path)
        }
    }

    // MARK: - Socket connections

    private func acceptPendingConnections() {
        while listenFD >= 0 {
            var addr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.accept(listenFD, sa, &len)
                }
            }
            if clientFD < 0 { break }
            let clientFlags = fcntl(clientFD, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(clientFD, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size))
            var sndTimeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(
                clientFD,
                SOL_SOCKET,
                SO_SNDTIMEO,
                &sndTimeout,
                socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self] in
                self?.serveConnection(fd: clientFD)
            }
        }
    }

    private static func peerPID(of fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else {
            return nil
        }
        return pid
    }

    private static func isDescriptorOpen(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var rc: Int32
        repeat {
            pfd.revents = 0
            rc = Darwin.poll(&pfd, 1, 0)
        } while rc < 0 && errno == EINTR
        guard rc >= 0 else { return true }
        return (pfd.revents & Int16(POLLHUP | POLLNVAL)) == 0
    }

    func recordStartupFailure(_ error: Error) {
        let reason = error.localizedDescription
        setStatus(.degraded(reason: reason))
        appendEngineLog("engine socket failed: \(reason)")
    }

    private func appendEngineLog(_ message: String) {
        let logURL = socketURL.deletingLastPathComponent().appendingPathComponent("engine.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            if ((try? handle.seekToEnd()) ?? 0) > Self.maxEngineLogBytes {
                try? handle.truncate(atOffset: 0)
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    private func serveConnection(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var isRegisteredEngine = false
        var handshaked = false

        defer {
            ioQueue.sync {
                if isRegisteredEngine, self.engineFD == fd {
                    self.engineFD = -1
                    self.setStatus(.degraded(reason: "engine disconnected"))
                    for entry in self.activeModelStreams.values { entry.task.cancel() }
                    self.activeModelStreams.removeAll()
                    let waiters = self.activePromptWaiters
                    self.activePromptWaiters.removeAll()
                    for (id, callback) in waiters {
                        callback(
                            .failure(
                                id: id,
                                error: EngineError(
                                    code: .internal,
                                    reason: "engine disconnected",
                                    retryable: false)))
                    }
                }
            }
            Darwin.close(fd)
        }

        while true {
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[..<newlineIndex]
                buffer.removeSubrange(...newlineIndex)
                let line = String(decoding: lineData, as: UTF8.self)
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                guard let envelope = try? EngineLine.decode(line) else {
                    _ = ioQueue.sync {
                        self.writeLine(
                            .failure(id: "", error: .invalid("malformed JSON envelope")),
                            to: fd)
                    }
                    return
                }

                if !handshaked {
                    if envelope.method == "hello" {
                        let slotRefusal: String? = ioQueue.sync {
                            if self.supervisedEnginePath != nil {
                                guard let child = self.childProcess, child.isRunning,
                                      let peerPID = Self.peerPID(of: fd),
                                      peerPID == child.processIdentifier
                                else {
                                    self.setStatus(
                                        .degraded(reason: "engine slot is owned by the spawned child"))
                                    return "engine slot is owned by the spawned child"
                                }
                            }
                            if self.engineFD >= 0, self.engineFD != fd,
                               Self.isDescriptorOpen(self.engineFD)
                            {
                                return "engine already connected"
                            }
                            return nil
                        }
                        if let reason = slotRefusal {
                            _ = ioQueue.sync {
                                self.writeLine(
                                    .failure(id: envelope.id ?? "hello", error: .refused(reason)),
                                    to: fd)
                            }
                            return
                        }
                        let (reply, peer) = onMain {
                            EngineKernel.hello(
                                from: envelope,
                                config: self.configProvider(),
                                state: self.stateStore.state)
                        }
                        _ = ioQueue.sync { self.writeLine(reply, to: fd) }
                        guard let peer else {
                            self.setStatus(
                                .degraded(reason: reply.error?.reason ?? "engine handshake refused"))
                            return
                        }
                        handshaked = true
                        isRegisteredEngine = true
                        ioQueue.sync {
                            if self.engineFD >= 0, self.engineFD != fd {
                                _ = Darwin.shutdown(self.engineFD, SHUT_RD)
                            }
                            self.engineFD = fd
                            self.restartAttempt = 0
                            self.setStatus(.ready(impl: peer.impl))
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.pushDayWokeIfNeeded()
                        }
                        continue
                    } else if envelope.method == "chat.prompt" {
                        // A local client (CLI or e2e test) driving `chat.prompt`
                        // through the kernel to the connected engine.
                        handleClientPromptOverSocket(envelope: envelope, clientFD: fd)
                        return
                    } else if envelope.method == "chat.abort" {
                        var targetID = envelope.id ?? ""
                        if case .object(let fields) = envelope.params,
                           case .string(let runID) = fields["id"], !runID.isEmpty
                        {
                            targetID = runID
                        }
                        let done = DispatchSemaphore(value: 0)
                        var aborted = false
                        abort(id: targetID) { ok in
                            aborted = ok
                            done.signal()
                        }
                        _ = done.wait(timeout: .now() + 2)
                        _ = ioQueue.sync {
                            self.writeLine(
                                .reply(id: envelope.id ?? targetID, result: .object(["aborted": .bool(aborted)])),
                                to: fd)
                        }
                        return
                    } else if envelope.method == "intent.schedule"
                        || envelope.method == "reflection.run"
                        || envelope.method == "lesson.list"
                        || envelope.method == "lesson.accept"
                    {
                        handleClientEngineRpcOverSocket(envelope: envelope, clientFD: fd)
                        return
                    } else if envelope.method == EngineCapability.stateRead.rawValue {
                        // Reads are replay-safe and serve the app's own status
                        // path; a mutation waits for the handshake.
                        let outcome = onMain {
                            self.evaluateKernelRequest(envelope)
                        }
                        _ = ioQueue.sync { self.writeLine(outcome.reply, to: fd) }
                        return
                    } else {
                        _ = ioQueue.sync {
                            self.writeLine(
                                .failure(
                                    id: envelope.id ?? "",
                                    error: .refused("hello handshake required first")),
                                to: fd)
                        }
                        return
                    }
                }

                // Registered engine connection: may send capability requests or
                // stream events (`chat.delta`, `chat.done`, `chat.error`).
                if envelope.isRequest {
                    let snapshot: EngineDeviceContext = envelope.capability == .deviceContext
                        ? deviceContextProvider()
                        : .empty
                    let outcome = onMain {
                        self.evaluateKernelRequest(envelope, deviceContext: snapshot)
                    }
                    if let streamReq = outcome.modelStream {
                        startModelStream(streamReq, to: fd)
                    } else {
                        _ = ioQueue.sync { self.writeLine(outcome.reply, to: fd) }
                    }
                } else {
                    ioQueue.sync {
                        self.routeEnginePushOrReply(envelope)
                    }
                }
            }
        }
    }

    private func evaluateKernelRequest(
        _ envelope: EngineEnvelope,
        deviceContext: EngineDeviceContext = .empty
    ) -> EngineOutcome {
        let config = configProvider()
        let enforced = enforcementProvider()
        let pomodoro = pomodoroProvider()
        var draft = stateStore.state
        let outcome = EngineKernel.handle(
            envelope,
            config: config,
            state: &draft,
            blocksEnforced: enforced,
            pomodoroRunning: pomodoro.running,
            pomodoroRemaining: pomodoro.remaining,
            deviceContext: deviceContext,
            calendar: stateStore.calendar)
        if outcome.mutated {
            stateStore.update { $0 = draft }
        }
        if outcome.startedRound {
            onStartRound?()
        }
        if outcome.mutated {
            onMutated?()
        }
        if let spoken = outcome.spokenText {
            onSpeak?(spoken)
        }
        if let span = outcome.emittedSpan {
            traceProvider()?.record(span)
        }
        return outcome
    }

    private func startModelStream(_ req: ValidatedModelStream, to fd: Int32) {
        let streamKey = "\(fd):\(req.id)"
        let streamToken = UUID()
        let task = Task { [weak self] in
            let startedAt = Date()
            let client = OpenRouterClient(
                settings: .init(apiKey: req.apiKey, model: req.model, language: req.language))
            let result = await client.streamChat(
                messages: req.messages,
                tools: req.tools,
                reasoning: req.reasoning
            ) { [weak self] chunk in
                let deltaCancelled = Task.isCancelled
                guard !deltaCancelled, let self else { return }
                self.ioQueue.sync {
                    guard !self.stopped,
                          self.engineFD == fd,
                          self.activeModelStreams[streamKey]?.token == streamToken
                    else { return }
                    _ = self.writeLine(
                        EngineEnvelope(
                            id: req.id,
                            params: .object(["text": .string(chunk)]),
                            event: "model.delta"),
                        to: fd)
                }
            }
            let cancelled = Task.isCancelled
            guard let self else { return }
            let endedAt = Date()
            var emittedDone = false
            self.ioQueue.sync {
                let isCurrent = self.activeModelStreams[streamKey]?.token == streamToken
                if isCurrent {
                    self.activeModelStreams.removeValue(forKey: streamKey)
                }
                guard !cancelled, isCurrent, !self.stopped, self.engineFD == fd else { return }
                switch result {
                case .success(let done):
                    let params = (try? EngineJSON.encoded(done)) ?? .object([
                        "text": .string(done.text),
                        "toolCalls": .array([]),
                        "usage": .object([
                            "in": .number(Double(done.usage.inTokens)),
                            "out": .number(Double(done.usage.outTokens)),
                        ]),
                    ])
                    emittedDone = self.writeLine(
                        EngineEnvelope(id: req.id, params: params, event: "model.done"),
                        to: fd)
                case .failure(let err):
                    _ = self.writeLine(.failure(id: req.id, error: err), to: fd)
                }
            }
            if emittedDone, case .success(let done) = result {
                let tracer = onMain { self.traceProvider() }
                tracer?.record(.init(
                    name: "model.stream",
                    traceName: "granny.engine",
                    input: [
                        "tier": req.tier,
                        "messages": "\(req.messages.count)",
                    ],
                    output: [
                        "text": String(done.text.prefix(500)),
                        "toolCalls": "\(done.toolCalls.count)",
                        "in": "\(done.usage.inTokens)",
                        "out": "\(done.usage.outTokens)",
                    ],
                    model: req.model,
                    startedAt: startedAt,
                    endedAt: endedAt))
            }
        }
        ioQueue.sync {
            activeModelStreams[streamKey]?.task.cancel()
            activeModelStreams[streamKey] = (streamToken, task)
        }
    }

    private func routeEnginePushOrReply(_ envelope: EngineEnvelope) {
        if let id = envelope.id, let waiter = activePromptWaiters[id] {
            if envelope.event == "chat.done" || envelope.event == "chat.error" || envelope.isReply {
                activePromptWaiters.removeValue(forKey: id)
            }
            waiter(envelope)
            return
        }
        // Unkeyed `chat.delta` / `chat.done` events when only one prompt is in flight.
        if envelope.id == nil, let event = envelope.event, event.hasPrefix("chat."),
           activePromptWaiters.count == 1, let (id, waiter) = activePromptWaiters.first
        {
            if event == "chat.done" || event == "chat.error" {
                activePromptWaiters.removeValue(forKey: id)
            }
            waiter(envelope)
        }
    }

    private func handleClientPromptOverSocket(envelope: EngineEnvelope, clientFD: Int32) {
        let id = envelope.id ?? "c-1"
        var promptText = ""
        var reasoning = false
        if case .object(let fields) = envelope.params {
            if case .string(let text) = fields["text"] { promptText = text }
            if case .bool(let flag) = fields["reasoning"] { reasoning = flag }
        }
        let done = DispatchSemaphore(value: 0)
        prompt(id: id, text: promptText, reasoning: reasoning) { [weak self] event in
            guard let self else {
                done.signal()
                return
            }
            // Invoked on `ioQueue`.
            _ = self.writeLine(event, to: clientFD)
            if event.event == "chat.done" || event.event == "chat.error" || event.isReply {
                done.signal()
            }
        }
        if done.wait(timeout: .now() + Self.promptTimeout) == .timedOut {
            ioQueue.sync {
                self.activePromptWaiters.removeValue(forKey: id)
                _ = self.writeLine(
                    .failure(
                        id: id,
                        error: EngineError(
                            code: .internal,
                            reason: "engine prompt timed out",
                            retryable: false)),
                    to: clientFD)
            }
        }
    }

    private func handleClientEngineRpcOverSocket(envelope: EngineEnvelope, clientFD: Int32) {
        let id = envelope.id ?? "rpc-\(UUID().uuidString.prefix(8))"
        let method = envelope.method ?? ""
        let done = DispatchSemaphore(value: 0)
        ioQueue.async { [weak self] in
            guard let self else {
                done.signal()
                return
            }
            guard self.engineFD >= 0 else {
                _ = self.writeLine(
                    .failure(id: id, error: .unavailable("engine is not connected")),
                    to: clientFD)
                done.signal()
                return
            }
            self.activePromptWaiters[id] = { [weak self] reply in
                guard let self else {
                    done.signal()
                    return
                }
                _ = self.writeLine(reply, to: clientFD)
                if reply.isReply {
                    done.signal()
                }
            }
            let forwarded = EngineEnvelope(
                v: envelope.v,
                id: id,
                key: envelope.key,
                method: method,
                params: envelope.params)
            if !self.writeLine(forwarded, to: self.engineFD) {
                self.activePromptWaiters.removeValue(forKey: id)
                _ = self.writeLine(
                    .failure(
                        id: id,
                        error: EngineError(
                            code: .internal,
                            reason: "engine disconnected",
                            retryable: false)),
                    to: clientFD)
                done.signal()
            }
        }
        if done.wait(timeout: .now() + Self.promptTimeout) == .timedOut {
            ioQueue.sync {
                self.activePromptWaiters.removeValue(forKey: id)
                _ = self.writeLine(
                    .failure(
                        id: id,
                        error: EngineError(
                            code: .internal,
                            reason: "engine request timed out",
                            retryable: false)),
                    to: clientFD)
            }
        }
    }

    @discardableResult
    private func writeLine(_ envelope: EngineEnvelope, to fd: Int32) -> Bool {
        guard fd >= 0, let line = try? EngineLine.encode(envelope) else { return false }
        let bytes = Array((line + "\n").utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBufferPointer { ptr in
                Darwin.write(fd, ptr.baseAddress! + written, bytes.count - written)
            }
            if n <= 0 { return false }
            written += n
        }
        return true
    }
}
