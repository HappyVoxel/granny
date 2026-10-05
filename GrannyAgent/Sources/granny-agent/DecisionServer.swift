import Foundation
import Network
import GrannyCore

/// Local HTTP endpoint the browser extension talks to.
/// GET /decide?url=…&title=…  -> verdict JSON, requires X-Granny-Token.
/// GET /status, GET /health.
final class DecisionServer {
    private let engine: DecisionEngine
    private let token: String
    private let port: UInt16

    /// Request-size guards: one read chunk, and the largest body accepted
    /// before the connection is dropped.
    private static let maxRequestChunk = 65536
    private static let maxRequestBytes = 131072
    private let stateProvider: () -> (DayState, Phase)
    private var listener: NWListener?

    init(
        engine: DecisionEngine,
        token: String,
        port: UInt16,
        stateProvider: @escaping () -> (DayState, Phase)
    ) {
        self.engine = engine
        self.token = token
        self.port = port
        self.stateProvider = stateProvider
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "granny", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad port"])
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestChunk) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                Task { await self.respond(connection: connection, head: head) }
            } else if error != nil || isComplete || buffer.count > Self.maxRequestBytes {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(connection: NWConnection, head: String) async {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let requestLine = lines.first else { connection.cancel(); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { connection.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let path = String(target.split(separator: "?").first ?? "")

        // Pairing endpoint for the browser extension: tokenless on loopback,
        // hands out the local token so users never paste it. The token only
        // gates decision queries - unlocking stays in the app UI. Only a
        // loopback Host is answered: a page using DNS rebinding to 127.0.0.1
        // must not be able to read the token.
        if method == "GET", path == "/hello" {
            let host = (headers["host"] ?? "").lowercased()
            // Exact loopback names only: a prefix check lets a DNS-rebound
            // "127.0.0.1.attacker.com" read the token. Strip the port, keeping
            // a bracketed IPv6 literal whole.
            let hostname: String
            if let bracket = host.firstIndex(of: "]") {
                hostname = String(host[...bracket])
            } else {
                hostname = String(host.split(separator: ":").first ?? "")
            }
            let loopback = hostname == "127.0.0.1" || hostname == "localhost" || hostname == "[::1]"
            guard loopback else {
                send(connection, status: 403, json: ["error": "loopback only"])
                return
            }
            send(connection, status: 200, json: [
                "ok": true,
                "port": Int(port),
                "token": token,
            ])
            return
        }

        guard headers["x-granny-token"] == token else {
            send(connection, status: 401, json: ["error": "invalid token"])
            return
        }

        switch (method, path) {
        case ("GET", "/health"):
            send(connection, status: 200, json: ["ok": true])
        case ("GET", "/status"):
            let (state, phase) = stateProvider()
            send(connection, status: 200, json: [
                "phase": phase.rawValue,
                "blocksActive": phase.blocksActive,
                "dayOff": state.dayOff,
                "tasks": state.tasks.map { ["title": $0.title, "done": $0.done] },
            ])
        case ("GET", "/decide"):
            let query = parseQuery(target)
            let (state, phase) = stateProvider()
            let context = PageContext(
                url: query["url"] ?? "",
                title: query["title"],
                channel: query["channel"],
                description: query["description"],
                kind: query["kind"])
            let force = query["force"] == "1" || query["force"] == "true"
            let decision = await engine.decide(
                context: context, tasks: state.tasks, phase: phase, force: force)
            send(connection, status: 200, json: [
                "action": decision.action.rawValue,
                "message": decision.message ?? "",
                "reason": decision.reason,
                "source": decision.source,
            ])
        default:
            send(connection, status: 404, json: ["error": "not found"])
        }
    }

    private func send(_ connection: NWConnection, status: Int, json: [String: Any]) {
        guard let body = JSON.data(from: json) else { connection.cancel(); return }
        let reason = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Not Found")
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
