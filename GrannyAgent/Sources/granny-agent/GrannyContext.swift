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
    private let chime = Chime()
    let viewModel = GrannyViewModel()

    /// Set when GitHub reports a newer release; the menu offers the link.
    private(set) var availableUpdate: ReleaseInfo?

    /// The timetable the running app honours. Settings and the timetable
    /// window write the file; this copy is what the ticks read until the next
    /// save, so an edit lands without a relaunch.
    private(set) var schedule: Schedule

    /// The coach's line about the last days, read once at launch and once per
    /// rollover - the log only grows at midnight, so there is nothing to
    /// re-read in between.
    private(set) var rhythmReport: RhythmReport?

    private var server: DecisionServer?
    private var killer: AppKiller?
    private var janitor: BrowserJanitor?
    private var updateTimer: Timer?
    /// The task the intake question was asked about, so the answer lands on
    /// that task even if the list changed while the dialog was open.
    private var challengeTaskID: String?

    /// The tomato's live countdown. Only the stage and the round count are
    /// persisted (in the day state); the seconds are a deadline in memory,
    /// so the tick cannot make them drift and a relaunch starts fresh.
    private var pomodoroDeadline: Date?
    private var pomodoroRemaining: TimeInterval = 0
    private var pomodoroRunning = false
    private var pomodoroTimer: Timer?

    init() {
        GrannyPaths.ensureDirectories()
        let config = GrannyConfig.load()
        self.config = config
        GrannyLines.language = config.language
        GrannyTheme.configure(appearance: config.appearance)
        self.store = StateStore()
        self.rhythmReport = store.rhythm()
        self.schedule = Schedule(slots: config.schedule)
        self.trace = TraceClient(config: config.langfuse)
        self.engine = DecisionEngine(config: config, trace: trace)
        self.scheduler = Scheduler(config: config, store: store, engine: engine, block: block, speaker: speaker)
        self.scheduler.schedule = schedule
        // The block follows the work interval, not the clock: the scheduler
        // asks this every tick, and the tick that returns enforcement quashes
        // the relay tunnels a cleared-hosts break made possible.
        self.scheduler.blockEnforced = { [unowned self] in self.blocksEnforced() }
        self.scheduler.onBlockReturned = { [weak self] in self?.quashRelayTunnels() }
        speaker.enabled = config.speechEnabled
        speaker.voice = GrannyVoice.resolve(
            configured: config.voiceIdentifier,
            language: config.language,
            voices: Speaker.systemVoices())
        block.onError = { message in postNotification(body: message) }
        viewModel.refresh(from: self)
        // Idle, the tomato wears the stage that a click would start.
        pomodoroRemaining = TimeInterval(store.state.pomodoro.minutes(config.pomodoro) * 60)
        syncPomodoro()
    }

    func start() {
        // Midnight moves the tomato to a new day even when the stage it left
        // was deep work too - which is exactly what a running round looks
        // like, and why the clock is reset here instead of by comparing
        // stages.
        scheduler.onDayRollover = { [weak self] in self?.startPomodoroDay() }
        scheduler.start()
        startDecisionServer()
        startAppKiller()
        startBrowserJanitor()
        startUpdateCheck()
        // A round can be asked to start itself, so a run can watch a whole
        // stage end - the bell, the banner, the next stage - without a click.
        if ProcessInfo.processInfo.environment[GrannyEnv.pomodoroAutostart] == "1" {
            startPomodoro()
        }
    }

    func snapshot() -> (DayState, Phase) {
        (store.state, phase())
    }

    /// A fresh install has no keys: the greeting nudges toward Settings.
    var needsSetupKey: Bool {
        (config.openRouterKey ?? "").isEmpty
    }

    /// Until the root helper is installed once, every block asks for the
    /// admin password; the greeting offers the one-time install.
    var helperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: BlockController.installedHelperPath)
    }

    func phase() -> Phase {
        computePhase(config: config, state: store.state)
    }

    /// The enforcement truth the four ends share: the phase, minus a running
    /// pomodoro break. Reads live state only - `pomodoroRunning` is never
    /// persisted - so a relaunch mid-break or an expiry while granny was down
    /// cannot inherit the holiday.
    func blocksEnforced() -> Bool {
        // The server, killer and janitor ask from their own queues; the store
        // and the tomato flag are main-thread-only.
        if Thread.isMainThread { return blocksEnforcedNow() }
        return DispatchQueue.main.sync { blocksEnforcedNow() }
    }

    private func blocksEnforcedNow() -> Bool {
        GrannyCore.blocksEnforced(
            phase: phase(),
            run: store.state.pomodoro,
            running: pomodoroRunning)
    }

    // MARK: - Mutations

    func markGreeted() {
        mutate { $0.greeted = true }
    }

    func submitTasks(_ text: String, onChallenge: @escaping (String) -> Void) {
        let naive = TaskParser.parse(text)
        guard !naive.isEmpty else { return }
        var resumed = false
        mutate { state in
            resumed = state.cancelDayOff()
            state.tasks = state.carried + naive
            state.carried = []
            state.greeted = true
        }
        scheduler.tick()
        announce(resumed ? GrannyLines.dayOffCancelled : GrannyLines.saved)
        assignSlots()

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
                self.assignSlots()
                if let question = intake.question {
                    self.challengeTaskID = self.challengeTarget(in: intake.tasks)?.id
                    onChallenge(question)
                }
            }
        }
    }

    /// Which task a follow-up question is about: the one missing a purpose,
    /// else the one missing its sites - the "never invent a domain" case -
    /// else the only task. A question without a target would drop the
    /// grandchild's answer on the floor.
    private func challengeTarget(in tasks: [TaskItem]) -> TaskItem? {
        tasks.first { $0.purpose == nil }
            ?? tasks.first { $0.allowedSurfaces.isEmpty }
            ?? tasks.first
    }

    /// The answer to the intake's follow-up. It lands as the task's purpose,
    /// and then the task is re-read the way an edit is: any URL the user
    /// pasted becomes the surfaces verbatim (the model guesses no hosts -
    /// that is how "granny.com" got invented once), and the engine's second
    /// read refreshes the rest.
    func answerChallenge(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Only write when the challenge still points at a task: never
        // overwrite an unrelated task's purpose.
        let target = challengeTaskID.flatMap { id in
            store.state.tasks.first { $0.id == id }
        } ?? challengeTarget(in: store.state.tasks)
        challengeTaskID = nil
        guard let task = target else { return }

        let explicit = TaskParser.surfaces(in: trimmed)
        mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            state.tasks[index].purpose = trimmed
            if !explicit.isEmpty { state.tasks[index].allowedSurfaces = explicit }
        }

        Task { [weak self] in
            guard let self else { return }
            let text = "\(task.title). \(trimmed)"
            guard let intake = await self.engine.parseIntake(text: text),
                  let refined = intake.tasks.first
            else { return }
            await MainActor.run {
                self.applyRefinement(
                    refined, to: task.id,
                    purposeEdited: true,
                    surfacesEdited: !explicit.isEmpty)
            }
        }
    }

    /// Adds tasks after the list was submitted. The naive parse lands first
    /// (instant feedback), then the same intake brain as the morning list
    /// refines them in place - purpose, allowed surfaces, the lot. New open
    /// work re-locks the door if the day was already rewarded.
    func addTask(_ text: String) {
        let naive = TaskParser.parse(text)
        guard !naive.isEmpty else { return }
        var resumed = false
        mutate { state in
            // A task written on a day off cancels the day off.
            resumed = state.cancelDayOff()
            // A task added straight from the menu still brings yesterday's
            // frogs into the book.
            state.tasks.append(contentsOf: state.carried)
            state.carried = []
            state.tasks.append(contentsOf: naive)
        }
        scheduler.tick()
        announce(resumed ? GrannyLines.dayOffCancelled : GrannyLines.taskAdded)
        assignSlots()

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
        assignSlots()
    }

    func toggle(taskID: String) {
        mutate { state in
            if let index = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[index].done.toggle()
            }
        }
        scheduler.tick()
        if let task = store.state.tasks.first(where: { $0.id == taskID }), task.done {
            nudgeOffSlot(task)
        }
        if store.state.allDone {
            announce(store.state.paid
                ? GrannyLines.reward(bedtime: config.bedtimeHour)
                : GrannyLines.unpaidNudge)
        }
    }

    /// Finishing something at the wrong hour still counts - granny is strict,
    /// not petty - but she says so, once per task: repeating it is how a coach
    /// becomes a nag.
    private func nudgeOffSlot(_ task: TaskItem) {
        guard let slot = schedule.slot(id: task.slotID),
              let current = schedule.current(), current.id != slot.id,
              !store.state.nudgedOffSlot.contains(task.id)
        else { return }
        mutate { $0.nudgedOffSlot.append(task.id) }
        announce(GrannyLines.offSlot(task: task.title, slot: slot.time))
    }

    /// Saves the day to the config and adopts it at once: the next tick
    /// announces from the new hours, no relaunch. The file on disk is
    /// re-read first and only `schedule` is merged into it - this context's
    /// `config` is the launch-time copy, and writing that back would undo a
    /// Settings save the user declined to relaunch for.
    func saveSchedule(_ slots: [ScheduleSlot]) throws {
        var onDisk = GrannyConfig.load()
        onDisk.schedule = slots
        try onDisk.save()
        admit(slots)
    }

    /// Adopts a timetable that is already on disk. The failed-save path must
    /// not reach here: the window would behave as if the hours were saved
    /// while the next launch quietly reverted them.
    private func admit(_ slots: [ScheduleSlot]) {
        schedule = Schedule(slots: slots)
        scheduler.schedule = schedule
        mutate { state in
            state.tasks = droppingUnknownSlots(state.tasks, in: schedule)
            state.carried = droppingUnknownSlots(state.carried, in: schedule)
        }
        assignSlots()
    }

    /// The user moving a task off its proposed hour, or onto one.
    func assignSlot(taskID: String, slotID: String?) {
        mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            state.tasks[index].slotID = slotID
        }
    }

    /// Granny's read of the day, as a proposal: same kind of hour first, one
    /// task per slot, in the order the list was written. Stored so the hour
    /// cannot drift under the task - a task granny already placed keeps its
    /// slot even if the wording changes.
    private func assignSlots() {
        guard !schedule.slots.isEmpty else { return }
        let pending = store.state.tasks.filter { !$0.done && $0.slotID == nil }
        let proposal = proposeSlots(for: pending, in: schedule)
        guard !proposal.isEmpty else { return }
        mutate { state in
            for index in state.tasks.indices {
                if let slot = proposal[state.tasks[index].id] {
                    state.tasks[index].slotID = slot
                }
            }
        }
    }

    /// Drops a task from the book for good, carried frogs included - "this
    /// frog is not coming back". The next tick recomputes the phase, so
    /// removing the last open task can flip the day to rewarded.
    func removeTask(taskID: String) {
        mutate { state in
            state.tasks.removeAll { $0.id == taskID }
            state.carried.removeAll { $0.id == taskID }
        }
        scheduler.tick()
    }

    /// Rewrites a task's words (and, when the editor touched them, its
    /// surfaces), then re-runs the intake brain on the new wording - the
    /// edited task gets the same treatment as a freshly added one, so the
    /// rules open the sites the new words need and the purpose matches them.
    /// Whether the user wrote the purpose and the surfaces themselves is
    /// read off the change: an untouched field belongs to the model.
    func updateTask(taskID: String, title: String, purpose: String?, surfaces: [String]) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let purposeText = purpose?.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = store.state.tasks.first { $0.id == taskID }
        let purposeEdited = (purposeText ?? "") != (original?.purpose ?? "")
        let surfacesEdited = surfaces != (original?.allowedSurfaces ?? [])

        mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            state.tasks[index].title = trimmed
            state.tasks[index].purpose = (purposeText?.isEmpty ?? true) ? nil : purposeText
            state.tasks[index].allowedSurfaces = surfaces
        }
        scheduler.tick()

        Task { [weak self] in
            guard let self else { return }
            let text = [trimmed, purposeText ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: ". ")
            guard let intake = await self.engine.parseIntake(text: text),
                  let refined = intake.tasks.first
            else { return }
            await MainActor.run {
                self.applyRefinement(
                    refined, to: taskID,
                    purposeEdited: purposeEdited, surfacesEdited: surfacesEdited)
            }
        }
    }

    /// The engine's one-line reading of a task, for the editor's "ask
    /// granny": elaborates a purpose the user typed.
    func elaboratePurpose(title: String, purpose: String?) async -> String? {
        let text = [title, purpose ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
        guard !text.isEmpty,
              let intake = await engine.parseIntake(text: text),
              let refined = intake.tasks.first,
              let elaborated = refined.purpose, !elaborated.isEmpty
        else { return nil }
        return elaborated
    }

    /// The engine's reading of an edited task, merged by `TaskParser.refined`:
    /// untouched fields take the model's words, hand-written ones survive.
    private func applyRefinement(
        _ refined: TaskItem, to taskID: String, purposeEdited: Bool, surfacesEdited: Bool
    ) {
        mutate { state in
            guard let index = state.tasks.firstIndex(where: { $0.id == taskID }) else { return }
            state.tasks[index] = TaskParser.refined(
                state.tasks[index], with: refined,
                purposeEdited: purposeEdited, surfacesEdited: surfacesEdited)
        }
    }

    func markAllDone() {
        mutate { state in
            for index in state.tasks.indices { state.tasks[index].done = true }
        }
        scheduler.tick()
        announce(store.state.paid
            ? GrannyLines.reward(bedtime: config.bedtimeHour)
            : GrannyLines.unpaidNudge)
    }

    func setDayOff() {
        mutate { $0.dayOff = true }
        scheduler.tick()
        announce(GrannyLines.dayOffDone)
    }

    /// The user changed their mind: cancels the day off and lets the next
    /// scheduler tick re-apply the blocks the open work calls for.
    func clearDayOff() {
        guard store.state.dayOff else { return }
        mutate { _ = $0.cancelDayOff() }
        scheduler.tick()
        announce(GrannyLines.backToWork)
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

    /// Whether a browser carries granny's extension. Cached briefly: the
    /// status menu asks on every open, and the scan reads profile files.
    private var extensionStatus: (installed: Bool, at: Date)?

    var extensionInstalled: Bool {
        if let status = extensionStatus,
           Date().timeIntervalSince(status.at) < Self.extensionCacheTTL {
            return status.installed
        }
        // An unreadable Chromium profile counts as installed: a wrong "not
        // installed" would nag someone who already loaded the extension.
        let installed = ExtensionCheck.safari(run: Self.runTool)
            || (ExtensionCheck.chromium() ?? true)
        extensionStatus = (installed, Date())
        return installed
    }

    private static let extensionCacheTTL: TimeInterval = 60

    /// One-shot tool runner for the checks that shell out (pluginkit).
    private static func runTool(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

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
        syncPomodoro()
        // Cached verdicts were computed against the previous task list and
        // phase; a task change can flip what is allowed.
        Task { await engine.clearCache() }
    }

    // MARK: - Pomodoro

    /// The tomato: click to start the stage, click again to freeze it where
    /// it is. Pausing is the whole control set - a round is 25 minutes, so
    /// losing one to a misclick is not a disaster, and every extra button on
    /// a tomato this small would be clutter.
    func togglePomodoro() {
        // The click is also the answer to the bell: stop ringing.
        chime.silence()
        pomodoroRunning ? pausePomodoro() : startPomodoro()
    }

    private func startPomodoro() {
        if pomodoroRemaining <= 0 {
            pomodoroRemaining = TimeInterval(store.state.pomodoro.minutes(config.pomodoro) * 60)
        }
        pomodoroDeadline = Date().addingTimeInterval(pomodoroRemaining)
        pomodoroRunning = true
        startPomodoroTimer()
        syncPomodoro()
    }

    private func pausePomodoro() {
        if let deadline = pomodoroDeadline {
            pomodoroRemaining = max(0, deadline.timeIntervalSinceNow)
        }
        pomodoroDeadline = nil
        pomodoroRunning = false
        pomodoroTimer?.invalidate()
        pomodoroTimer = nil
        syncPomodoro()
    }

    /// Quarter-second ticks: the painted second must not lag the real one,
    /// and the ring's edge glides instead of stepping.
    private func startPomodoroTimer() {
        pomodoroTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.pomodoroTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pomodoroTimer = timer
    }

    private func pomodoroTick() {
        guard let deadline = pomodoroDeadline else { return }
        pomodoroRemaining = deadline.timeIntervalSinceNow
        guard pomodoroRemaining > 0 else {
            finishPomodoroStage()
            return
        }
        syncPomodoro()
    }

    /// A stage is over: bank it, show what comes next, and let a break run on
    /// its own. The next deep-work round waits for the click - that is the
    /// pomofocus default, and it keeps granny from starting a 25-minute
    /// round while nobody is at the desk.
    private func finishPomodoroStage() {
        let over = store.state.pomodoro.stage
        let next = store.state.pomodoro.advanced(config.pomodoro)
        let minutes = next.minutes(config.pomodoro)
        pomodoroRemaining = TimeInterval(minutes * 60)
        pomodoroRunning = next.stage != .deepWork
        pomodoroDeadline = pomodoroRunning ? Date().addingTimeInterval(pomodoroRemaining) : nil
        if pomodoroRunning {
            startPomodoroTimer()
        } else {
            pomodoroTimer?.invalidate()
            pomodoroTimer = nil
        }
        mutate { state in
            state.pomodoro = next
            if over == .deepWork { state.markFirstRound(calendar: store.calendar) }
        }
        // The bell first: it is the part that has to work with the window
        // behind another app or the screen asleep.
        if over == .deepWork {
            chime.breakTime()
            // The break lifts the block: the line says what to do with it,
            // and when the door closes again. Only the round that first paid
            // the day says "go play" - every later round is a break again,
            // and nothing else would announce the reward.
            announce(store.state.paidThisRound
                ? GrannyLines.reward(bedtime: config.bedtimeHour)
                : GrannyLines.pomodoroBreakLine(minutes: minutes))
        } else {
            chime.backToWork()
            announce(GrannyLines.pomodoroNext(stage: stageName(next.stage), minutes: minutes))
        }
    }

    /// Pushes the clock into the view.
    func syncPomodoro() {
        let run = store.state.pomodoro
        viewModel.pomodoroStage = run.stage
        viewModel.pomodoroIndex = run.index(longBreakEvery: config.pomodoro.resolved.longBreakEvery)
        viewModel.pomodoroTotal = TimeInterval(run.minutes(config.pomodoro) * 60)
        viewModel.pomodoroRemaining = pomodoroRemaining
        viewModel.pomodoroRunning = pomodoroRunning
    }

    /// A new day: the day's tomato starts over, and so does its clock. Paused,
    /// running or mid-break, nothing of yesterday carries into today.
    private func startPomodoroDay() {
        pomodoroTimer?.invalidate()
        pomodoroTimer = nil
        pomodoroDeadline = nil
        pomodoroRunning = false
        pomodoroRemaining = TimeInterval(store.state.pomodoro.minutes(config.pomodoro) * 60)
        syncPomodoro()
        // The rollover just logged yesterday: the line may say something new.
        rhythmReport = store.rhythm()
    }

    private func stageName(_ stage: PomodoroStage) -> String {
        GrannyLines.pomodoroStage(stage)
    }

    /// Private Relay is the classic bypass: blocking the ingress hostnames
    /// only stops *new* tunnels, so a tunnel opened during a break (when the
    /// hosts are clear) would outlive the block that comes back. Best effort
    /// and no sudo; macOS restarts the proxy on demand.
    private func quashRelayTunnels() {
        let tool = ProcessInfo.processInfo.environment[GrannyEnv.killall] ?? "/usr/bin/killall"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["-x", "networkserviceproxy"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
        }
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
                },
                enforcementProvider: { [unowned self] in self.blocksEnforced() })
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
            phaseProvider: { [unowned self] in self.phase() },
            enforcementProvider: { [unowned self] in self.blocksEnforced() })
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
        let killer = AppKiller(
            config: config,
            phaseProvider: { [unowned self] in self.phase() },
            enforcementProvider: { [unowned self] in self.blocksEnforced() })
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
