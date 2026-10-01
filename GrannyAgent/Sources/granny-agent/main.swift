import AppKit
import Foundation
import GrannyCore

let arguments = CommandLine.arguments

func runDecide(url: String) {
    let config = GrannyConfig.load()
    let store = StateStore()
    let engine = DecisionEngine(config: config)
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let phase = computePhase(config: config, state: store.state)
        let decision = await engine.decide(url: url, title: nil, tasks: store.state.tasks, phase: phase)
        if let data = JSON.encode(decision), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        await engine.flushTraces()
        semaphore.signal()
    }
    semaphore.wait()
}

func runStatus() {
    let config = GrannyConfig.load()
    let store = StateStore()
    let phase = computePhase(config: config, state: store.state)
    let hosts = (try? String(contentsOf: GrannyPaths.hostsURL, encoding: .utf8)) ?? ""
    print("phase: \(phase.rawValue)")
    print("blocks active: \(phase.blocksActive)")
    print("hosts block present: \(HostsFile.isBlocked(current: hosts)) (\(HostsFile.blockedDomainCount(current: hosts)) domains)")
    print("openrouter: \(config.openRouterKey == nil ? "not configured" : "configured")")
    print("laya: \(config.layaURL == nil ? "not configured" : "configured")")
    print("langfuse: \(config.langfuse == nil ? "not configured" : "configured")")
    print("tasks:")
    for task in store.state.tasks {
        print("  [\(task.done ? "x" : " ")] \(task.title)")
    }
}

if let index = arguments.firstIndex(of: "--decide"), index + 1 < arguments.count {
    runDecide(url: arguments[index + 1])
    exit(0)
}

if arguments.contains("--status") {
    runStatus()
    exit(0)
}

if arguments.contains("--serve") {
    let config = GrannyConfig.load()
    let store = StateStore()
    let engine = DecisionEngine(config: config)
    do {
        let server = try DecisionServer(
            engine: engine,
            token: config.token,
            port: config.decidePortNumber,
            stateProvider: { (store.state, computePhase(config: config, state: store.state)) })
        try server.start()
        print("granny-agent serving on 127.0.0.1:\(config.decidePortNumber)")
        RunLoop.main.run()
    } catch {
        FileHandle.standardError.write(Data("serve failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
