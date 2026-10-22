import AppKit
import Foundation
import GrannyCore

let arguments = CommandLine.arguments

/// Reads state from whichever queue asks: the decision server asks from its
/// own, and the serve tomato mutates on the main run loop.
func onMain<T>(_ read: () -> T) -> T {
    if Thread.isMainThread { return read() }
    return DispatchQueue.main.sync(execute: read)
}

/// `--serve`'s own tomato, keyed on `GRANNY_POMODORO_AUTOSTART=1`: without it
/// the CLI can never show a break lifting the block, and a second process
/// cannot read the app's live flag. Timing only - the stage machine is the
/// shared pure `PomodoroRun.advanced`/`minutes`, and no bell, banner or line
/// is played, because none of that belongs to the decision server.
final class ServePomodoro {
    private let config: GrannyConfig
    private let store: StateStore
    private var timer: Timer?
    private var deadline: Date?
    private var running = false

    init(config: GrannyConfig, store: StateStore) {
        self.config = config
        self.store = store
        guard ProcessInfo.processInfo.environment[GrannyEnv.pomodoroAutostart] == "1" else { return }
        deadline = Date().addingTimeInterval(
            TimeInterval(store.state.pomodoro.minutes(config.pomodoro) * 60))
        running = true
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The enforcement truth the server reads (through `onMain`).
    var enforced: Bool {
        blocksEnforced(
            phase: computePhase(config: config, state: store.state),
            run: store.state.pomodoro,
            running: running)
    }

    /// A stage is over: bank it, and let a break run on its own - the next
    /// deep-work round waits for a click, exactly as the app's tomato does.
    private func tick() {
        guard let deadline, running, deadline.timeIntervalSinceNow <= 0 else { return }
        let over = store.state.pomodoro.stage
        let next = store.state.pomodoro.advanced(config.pomodoro)
        store.update { state in
            state.pomodoro = next
            if over == .deepWork { state.markFirstRound(calendar: store.calendar) }
        }
        running = next.stage != .deepWork
        self.deadline = running
            ? Date().addingTimeInterval(TimeInterval(next.minutes(config.pomodoro) * 60))
            : nil
        if !running {
            timer?.invalidate()
            timer = nil
        }
    }
}

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
    print("rounds: \(store.state.pomodoro.finished)")
    print("schedule: \(config.schedule.count) slots")
    print("first round: \(store.state.firstRoundAt ?? "-")")
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

// A test seam, and the only path in the CLI that writes the block: the e2e
// suite points it at a sandbox hosts file and asserts the real one is
// untouched. The app applies the same block through its scheduler.
if arguments.contains("--apply-blocks") {
    let config = GrannyConfig.load()
    let applied = BlockController().apply(domains: config.blockedDomains + config.dohDomains)
    print("apply: \(applied ? "ok" : "failed")")
    exit(applied ? 0 : 1)
}

if arguments.contains("--status") {
    runStatus()
    exit(0)
}

if arguments.contains("--serve") {
    let config = GrannyConfig.load()
    let store = StateStore()
    let engine = DecisionEngine(config: config)
    let pomodoro = ServePomodoro(config: config, store: store)
    do {
        let server = DecisionServer(
            engine: engine,
            token: config.token,
            port: config.decidePortNumber,
            stateProvider: { onMain { (store.state, computePhase(config: config, state: store.state)) } },
            enforcementProvider: { onMain { pomodoro.enforced } })
        try server.start()
        print("granny-agent serving on 127.0.0.1:\(config.decidePortNumber)")
        // A redirected stdout is block-buffered: a script waiting for the
        // server would read an empty file and call it a crash.
        fflush(stdout)
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
