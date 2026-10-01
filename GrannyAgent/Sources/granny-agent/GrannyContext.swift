import Foundation
import GrannyCore

/// Main-thread facade over the store and engine. The SwiftUI views observe
/// this object; every mutation goes through `mutate` so the view refreshes.
final class GrannyContext {
    let config: GrannyConfig
    let store: StateStore
    let engine: DecisionEngine
    let trace: TraceClient
    let speaker = Speaker()
    let block = BlockController()
    let scheduler: Scheduler
    let viewModel = GrannyViewModel()

    /// Set when GitHub reports a newer release; the menu offers the link.
    private(set) var availableUpdate: ReleaseInfo?

    private var server: DecisionServer?
    private var killer: AppKiller?
    private var janitor: BrowserJanitor?
    private var updateTimer: Timer?
    /// The task the intake question was asked about, so the answer lands on
    /// that task even if the list changed while the dialog was open.
    private var challengeTaskID: String?

    init() {
        GrannyPaths.ensureDirectories()
        let config = GrannyConfig.load()
        self.config = config
        GrannyLines.language = config.language
        GrannyTheme.configure(appearance: config.appearance)
        self.store = StateStore()
        self.trace = TraceClient(config: config.langfuse)
        self.engine = DecisionEngine(config: config, trace: trace)
        self.scheduler = Scheduler(config: config, store: store, engine: engine, block: block, speaker: speaker)
        speaker.enabled = config.speechEnabled
        speaker.voice = GrannyVoice.resolve(
            configured: config.voiceIdentifier,
            language: config.language,
            voices: Speaker.systemVoices())
        block.onError = { message in postNotification(body: message) }
        viewModel.refresh(from: self)
    }

    func start() {
        scheduler.start()
        startDecisionServer()
        startAppKiller()
        startBrowserJanitor()
        startUpdateCheck()
    }

    func snapshot() -> (DayState, Phase) {
        (store.state, phase())
    }

    /// A fresh install has no keys: the greeting nudges toward Settings.
    var needsSetupKey: Bool {
        (config.openRouterKey ?? "").isEmpty
    }

    func phase() -> Phase {
        computePhase(config: config, state: store.state)
    }

    // MARK: - Mutations

    func markGreeted() {
        mutate { $0.greeted = true }
    }

    func submitTasks(_ text: String, onChallenge: @escaping (String) -> Void) {
        let naive = TaskParser.parse(text)
        guard !naive.isEmpty else { return }
        mutate { state in
            state.tasks = state.carried + naive
            state.carried = []
            state.greeted = true
        }
        scheduler.tick()
        announce(GrannyLines.saved)

        Task { [weak self] in
            guard let self, let intake = await self.engine.parseIntake(text: text), !intake.tasks.isEmpty else { return }
            await MainActor.run {
                self.mutate { state in
                    // Yesterday's frogs stay in the book; only today's entry
                    // gets replaced by the refined version. If the user
                    // already acted on the naive entry while the model was
                    // thinking, keep their state instead.
                    let naiveIDs = Set(naive.map(\.id))
                    let stillThere = state.tasks.filter { naiveIDs.contains($0.id) }
                    guard stillThere.count == naive.count,
                          stillThere.allSatisfy({ !$0.done }) else { return }
                    state.tasks = state.tasks.filter(\.carriedOver) + intake.tasks
                }
                if let question = intake.question {
                    self.challengeTaskID = intake.tasks.first(where: { $0.purpose == nil })?.id
                    onChallenge(question)
                }
            }
        }
    }

    func answerChallenge(_ answer: String) {
        mutate { state in
            // Only write when the challenge still points at a task: never
            // overwrite an unrelated task's purpose.
            let target = challengeTaskID.flatMap { id in
                state.tasks.firstIndex(where: { $0.id == id })
            } ?? state.tasks.firstIndex(where: { $0.purpose == nil })
            if let target {
                state.tasks[target].purpose = answer
            }
        }
        challengeTaskID = nil
    }

    /// Adds tasks after the list was submitted. The naive parse lands first
    /// (instant feedback), then the same intake brain as the morning list
    /// refines them in place - purpose, allowed surfaces, the lot. New open
    /// work re-locks the door if the day was already rewarded.
    func addTask(_ text: String) {
        let naive = TaskParser.parse(text)
        guard !naive.isEmpty else { return }
        mutate { state in
            // A task added straight from the menu still brings yesterday's
            // frogs into the book.
            state.tasks.append(contentsOf: state.carried)
            state.carried = []
            state.tasks.append(contentsOf: naive)
        }
        scheduler.tick()
        announce(GrannyLines.taskAdded)

        Task { [weak self] in
            guard let self,
                  let intake = await self.engine.parseIntake(text: text),
                  !intake.tasks.isEmpty
            else { return }
            await MainActor.run {
                self.replaceNaiveTasks(naive, with: intake.tasks)
            }
        }
    }

    /// Swaps the instantly-appended naive entries for the refined ones.
    /// If the user already acted on a naive entry while the model was
    /// thinking, their state wins and the swap is skipped.
    private func replaceNaiveTasks(_ naive: [TaskItem], with refined: [TaskItem]) {
        mutate { state in
            let naiveIDs = Set(naive.map(\.id))
            let stillThere = state.tasks.filter { naiveIDs.contains($0.id) }
            guard stillThere.count == naive.count,
                  stillThere.allSatisfy({ !$0.done }) else { return }
            state.tasks.removeAll { naiveIDs.contains($0.id) }
            state.tasks.append(contentsOf: refined)
        }
    }

    func toggle(taskID: String) {
        mutate { state in
            if let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[index].done.toggle()
            }
        }
        scheduler.tick()
        if store.state.allDone {
            announce(GrannyLines.reward(bedtime: config.bedtimeHour))
        }
    }

    /// Rewrites a task's allowed surfaces. The rules consult these before
    /// the block lists, so this is how a wrong machine-generated surface
    /// (a moved domain, a missed path) gets fixed without re-adding the task.
    func setSurfaces(taskID: String, surfaces: [String]) {
        mutate { state in
            if let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[index].allowedSurfaces = surfaces
            }
        }
    }

    func markAllDone() {
        mutate { state in
            for index in state.tasks.indices { state.tasks[index].done = true }
        }
        scheduler.tick()
        announce(GrannyLines.reward(bedtime: config.bedtimeHour))
    }

    func setDayOff() {
        mutate { $0.dayOff = true }
        scheduler.tick()
        announce(GrannyLines.dayOffDone)
    }

    /// Installs the root helper. Preferred path: the bundled installer run
    /// through the standard admin dialog - one password, no Terminal. Falls
    /// back to opening Terminal when the dialog cannot run.
    func installHelper() {
        let installerName = "install-helper.sh"
        let script = Bundle.main.resourceURL?.appendingPathComponent(installerName)
            ?? URL(fileURLWithPath: "scripts/" + installerName)
        guard FileManager.default.fileExists(atPath: script.path) else {
            postNotification(body: GrannyLines.helperInstallerMissing)
            return
        }

        let command = "GRANNY_USER=\(Quoting.shell(NSUserName())) /bin/bash \(Quoting.shell(script.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "do shell script \(Quoting.appleScript(command)) with administrator privileges",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // The admin dialog can stay up for a long time; never block the main
        // thread (timers, menu, scheduler) on it, and drain the pipes before
        // waiting so a chatty installer cannot deadlock.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async { self?.openHelperInstallerInTerminal(script) }
                return
            }
            _ = stdout.fileHandleForReading.readDataToEndOfFile()
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            DispatchQueue.main.async {
                guard let self else { return }
                if process.terminationStatus == 0 {
                    self.announce(GrannyLines.helperInstalled)
                } else {
                    self.openHelperInstallerInTerminal(script)
                }
            }
        }
    }

    /// Fallback path when the admin dialog cannot run.
    private func openHelperInstallerInTerminal(_ script: URL) {
        let fallback = Process()
        fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        fallback.arguments = ["-a", "Terminal", script.path]
        try? fallback.run()
    }

    // MARK: - Private

    /// The cask cannot self-update: ask GitHub Releases once a day and, when
    /// a newer version exists, let granny nag with the one-line upgrade.
    private static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    private func startUpdateCheck() {
        guard config.checkForUpdates,
              let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty
        else { return }

        checkForUpdate(currentVersion: version)
        let timer = Timer(timeInterval: Self.updateCheckInterval, repeats: true) { [weak self] _ in
            self?.checkForUpdate(currentVersion: version)
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func checkForUpdate(currentVersion: String) {
        Task { [weak self] in
            guard let self,
                  let release = await UpdateChecker.check(currentVersion: currentVersion)
            else { return }
            await MainActor.run {
                guard self.availableUpdate == nil else { return }
                self.availableUpdate = release
                self.announce(GrannyLines.updateAvailable(version: release.version))
            }
        }
    }

    private func mutate(_ block: (inout DayState) -> Void) {
        store.update(block)
        viewModel.refresh(from: self)
        // Cached verdicts were computed against the previous task list and
        // phase; a task change can flip what is allowed.
        Task { await engine.clearCache() }
    }

    private func announce(_ line: String) {
        speaker.say(line)
        postNotification(body: line)
    }

    private func startDecisionServer() {
        do {
            let server = DecisionServer(
                engine: engine,
                token: config.token,
                port: config.decidePortNumber,
                stateProvider: { [unowned self] in
                    // The server calls this on its own queue; the store is
                    // mutated on main, so take the snapshot there.
                    if Thread.isMainThread { return self.snapshot() }
                    return DispatchQueue.main.sync { self.snapshot() }
                })
            try server.start()
            self.server = server
        } catch {
            postNotification(body: GrannyLines.decisionServerFailed(port: config.decidePort))
        }
    }

    private func startBrowserJanitor() {
        let janitor = BrowserJanitor(
            config: config,
            tasksProvider: { [unowned self] in self.store.state.tasks },
            phaseProvider: { [unowned self] in self.phase() })
        janitor.onSweep = { [weak self] urls in
            guard let self, let first = urls.first else { return }
            self.announce(GrannyLines.closedTab(url: first))
            Task { await self.engine.recordAction(
                "tab-closed",
                input: ["urls": urls.joined(separator: " | ")],
                output: ["count": "\(urls.count)"]) }
        }
        janitor.onError = { message in postNotification(body: message) }
        janitor.start()
        self.janitor = janitor
    }

    private func startAppKiller() {
        let killer = AppKiller(config: config, phaseProvider: { [unowned self] in self.phase() })
        killer.onKill = { [weak self] name in
            guard let self else { return }
            let task = self.store.state.tasks.first(where: { !$0.done })?.title
            self.announce(GrannyLines.killApp(name: name, task: task))
            Task { await self.engine.recordAction(
                "app-killed",
                input: ["app": name],
                output: ["task": task ?? ""]) }
        }
        killer.start()
        self.killer = killer
    }
}
