import Darwin
import Foundation
import GrannyCore

/// Local Unix-socket server (`<state dir>/engine.sock`, mode 0600) that sits
/// between `GrannyCore` and `granny-engine` (Pi Durable, or the Node stub in
/// `tests/e2e-engine.sh`).
///
/// The kernel never blocks on the engine: if no process is connected, or the
/// child crashes mid-stream, the day, the blocks and `/decide` keep running.
final class EngineServer {
    enum Status: Equatable {
        case absent
        case ready(impl: String)
        case degraded(reason: String)
    }

    private static let promptTimeout: TimeInterval = 30
    private static let maxRestartAttempts = 6

    private let socketURL: URL
    private let configProvider: () -> GrannyConfig
    private let stateStore: StateStore
    private let enforcementProvider: () -> Bool
    private let onSpeak: ((String) -> Void)?
    private let onMutated: (() -> Void)?

    private let ioQueue = DispatchQueue(label: "io.github.happyvoxel.granny.engine-io")
    private var listenFD: Int32 = -1
    private var boundInode: ino_t = 0
    private var acceptSource: DispatchSourceRead?
    private var engineFD: Int32 = -1
    private var activePromptWaiters: [String: (EngineEnvelope) -> Void] = [:]
    private var stopped = false

    private var childProcess: Process?
    private var restartAttempt = 0

    private(set) var status: Status = .absent

    init(
        socketURL: URL = GrannyPaths.engineSocketURL,
        configProvider: @escaping () -> GrannyConfig,
        stateStore: StateStore,
        enforcementProvider: @escaping () -> Bool,
        onSpeak: ((String) -> Void)? = nil,
        onMutated: (() -> Void)? = nil
    ) {
        self.socketURL = socketURL
        self.configProvider = configProvider
        self.stateStore = stateStore
        self.enforcementProvider = enforcementProvider
        self.onSpeak = onSpeak
        self.onMutated = onMutated
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
            if engineFD >= 0 {
                Darwin.close(engineFD)
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
            self.writeLine(envelope, to: self.engineFD)
        }
    }

    /// Sends `chat.prompt` to the connected engine and streams deltas back.
    func prompt(
        id: String = "c-\(UUID().uuidString.prefix(8))",
        text: String,
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

    // MARK: - Child supervision

    private func spawnEngineIfConfigured() {
        guard let enginePath = ProcessInfo.processInfo.environment[GrannyEnv.enginePath],
              !enginePath.isEmpty
        else { return }
        ioQueue.async { [weak self] in
            self?.launchEngineProcess(at: enginePath)
        }
    }

    private func launchEngineProcess(at path: String) {
        guard !stopped else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        let hostEnv = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            GrannyEnv.engineSocket: socketURL.path,
        ]
        for key in ["PATH", "HOME", "TMPDIR", "LANG"] {
            if let value = hostEnv[key] { env[key] = value }
        }
        for (key, value) in hostEnv where key.hasPrefix("GRANNY_TEST_") {
            env[key] = value
        }
        process.environment = env
        process.terminationHandler = { [weak self] _ in
            self?.ioQueue.async { [weak self] in
                self?.scheduleRestart(at: path)
            }
        }
        do {
            try process.run()
            self.childProcess = process
        } catch {
            self.status = .degraded(reason: "failed to launch engine: \(error.localizedDescription)")
            scheduleRestart(at: path)
        }
    }

    private func scheduleRestart(at path: String) {
        guard !stopped, restartAttempt < Self.maxRestartAttempts else { return }
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
        ioQueue.sync {
            self.status = .degraded(reason: reason)
        }
        let logURL = socketURL.deletingLastPathComponent().appendingPathComponent("engine.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) engine socket failed: \(reason)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL, options: .atomic)
            }
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
                    self.status = .degraded(reason: "engine disconnected")
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
                            if let child = self.childProcess, child.isRunning {
                                guard let peerPID = Self.peerPID(of: fd),
                                      peerPID == child.processIdentifier
                                else {
                                    self.status = .degraded(
                                        reason: "engine slot is owned by the spawned child")
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
                            ioQueue.sync {
                                self.status = .degraded(
                                    reason: reply.error?.reason ?? "engine handshake refused")
                            }
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
                            self.status = .ready(impl: peer.impl)
                        }
                        continue
                    } else if envelope.method == "chat.prompt" {
                        // A local client (CLI or e2e test) driving `chat.prompt`
                        // through the kernel to the connected engine.
                        handleClientPromptOverSocket(envelope: envelope, clientFD: fd)
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
                    let outcome = onMain {
                        self.evaluateKernelRequest(envelope)
                    }
                    _ = ioQueue.sync { self.writeLine(outcome.reply, to: fd) }
                } else {
                    ioQueue.sync {
                        self.routeEnginePushOrReply(envelope)
                    }
                }
            }
        }
    }

    private func evaluateKernelRequest(_ envelope: EngineEnvelope) -> EngineOutcome {
        let config = configProvider()
        let enforced = enforcementProvider()
        var draft = stateStore.state
        let outcome = EngineKernel.handle(
            envelope,
            config: config,
            state: &draft,
            blocksEnforced: enforced,
            calendar: stateStore.calendar)
        if outcome.mutated {
            stateStore.update { $0 = draft }
            onMutated?()
        }
        if let spoken = outcome.spokenText {
            onSpeak?(spoken)
        }
        return outcome
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
        if let event = envelope.event, event.hasPrefix("chat."), activePromptWaiters.count == 1,
           let (id, waiter) = activePromptWaiters.first
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
        if case .object(let fields) = envelope.params, case .string(let text) = fields["text"] {
            promptText = text
        }
        let done = DispatchSemaphore(value: 0)
        prompt(id: id, text: promptText) { [weak self] event in
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
