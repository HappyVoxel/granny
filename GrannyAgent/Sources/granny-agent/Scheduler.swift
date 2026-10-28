import AppKit
import Foundation
import GrannyCore

final class Scheduler {
    let config: GrannyConfig
    let store: StateStore
    let engine: DecisionEngine
    let block: BlockController
    let speaker: Speaker

    var onGreetingNeeded: (() -> Void)?
    /// Whether the block is enforced right now - the phase minus a running
    /// break. nil keeps the phase alone, which is what the CLI wants: a
    /// second process cannot see the app's live tomato flag.
    var blockEnforced: (() -> Bool)?
    /// Fires on the lifted -> enforced transition, and only there: a break
    /// clears the hosts, so a Private Relay tunnel opened during one would
    /// outlive the block that returns after it.
    var onBlockReturned: (() -> Void)?
    /// Fires when the day rolls over, before anything looks at the new day:
    /// the tomato's rounds are counted per day, and a round that was running
    /// across midnight is yesterday's.
    var onDayRollover: (() -> Void)?
    /// Fires when a rollover grew or killed a displayed streak.
    var onStreakEvent: ((StreakEvent) -> Void)?
    /// Fired when the clock crosses wake, bedtime, or the day's payment, so a
    /// window that has been open for hours stops showing the old phase.
    var onPhaseChanged: ((Phase) -> Void)?

    /// Tick cadence, and how long a failed apply/clear waits before the
    /// next attempt (a cancelled authorization dialog must not re-prompt
    /// on every tick).
    private static let tickInterval: TimeInterval = 15
    private static let blockRetryInterval: TimeInterval = 60

    private var timer: Timer?
    private var lastPhase: Phase?
    /// The day the last tick saw. A rollover is compared by date, not by the
    /// phase or the tomato's stage - midnight can land on the same ones.
    private var lastDay: String?
    private var naggedDate: String?
    /// The slot last spoken for, and the day it was spoken on: the tick runs
    /// every 15 s and a slot lasts an hour, so without this it would repeat.
    private var announcedSlot: String?
    private var announcedDay: String?
    /// The timetable, swapped when the user saves a new one while granny
    /// runs. A slot is a name for an hour; rewriting the day must not wait
    /// for a relaunch.
    var schedule = Schedule()
    private var lastBlockAttempt = Date.distantPast
    private var lastClearAttempt = Date.distantPast
    /// Set while the last tick saw a lifted block, so the tick that returns
    /// enforcement can be told apart from an ordinary rewarded/day-off run.
    private var blocksWereLifted = false
    /// BlockController is not thread-safe and an admin dialog can outlive a
    /// tick, so apply/clear run one at a time off the main thread.
    private let blockQueue = DispatchQueue(label: "granny.block")
    private var blockWorkInFlight = false

    init(config: GrannyConfig, store: StateStore, engine: DecisionEngine, block: BlockController, speaker: Speaker) {
        self.config = config
        self.store = store
        self.engine = engine
        self.block = block
        self.speaker = speaker
    }

    func start() {
        tick()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Runs on the main thread: from the timer, menu actions, and wake events.
    func tick() {
        // The init rollover already ran when the app launched after
        // midnight; its event waits in the store until this first drain.
        if let event = store.rolloverIfNeeded() ?? store.drainPendingStreakEvent() {
            onStreakEvent?(event)
        }
        if lastDay != store.state.date {
            lastDay = store.state.date
            onDayRollover?()
        }
        let phase = computePhase(config: config, state: store.state)
        if phase != lastPhase {
            lastPhase = phase
            Task { await engine.clearCache() }
            // The windows drew their header from the phase they last saw: an
            // app left open overnight kept last night's line all day. The
            // clock crossing wake or bedtime is the event they need.
            onPhaseChanged?(phase)
        }
        let enforced = blockEnforced?() ?? phase.blocksActive
        // A tick where the phase wants the block and enforcement says no can
        // only be a running break: that is the lift. Its end - expiry, pause
        // or a phase change - is where the relay proxy is quashed.
        if phase.blocksActive, !enforced {
            blocksWereLifted = true
        } else if blocksWereLifted, enforced {
            blocksWereLifted = false
            onBlockReturned?()
        }
        // Every tick, not only on phase change: a cancelled authorization
        // dialog or a failed apply must land on the next tick, gated by the
        // retry throttle inside. The apply path re-applies when the hosts are
        // clear, which is how the block returns by itself at the break's end.
        applyBlocks(enforced)
        if phase == .awaitingTasks {
            onGreetingNeeded?()
        }
        if phase == .night,
           !store.state.tasks.isEmpty, !store.state.allDone,
           naggedDate != store.state.date {
            naggedDate = store.state.date
            speaker.say(GrannyLines.sleepNag)
            postNotification(body: GrannyLines.sleepNag)
        }
        announceSlotIfDue()
    }

    /// The timetable speaks only for a slot that has work pinned to it, and
    /// only once: a reminder with nothing to do is noise, and noise is what
    /// makes people silence granny for good.
    private func announceSlotIfDue() {
        let state = store.state
        guard !state.dayOff else { return }
        let phase = computePhase(config: config, state: state)
        guard phase == .awaitingTasks || phase == .working else { return }
        guard let slot = schedule.current(),
              let task = state.tasks.first(where: { $0.slotID == slot.id && !$0.done }),
              announcedSlot != slot.id || announcedDay != state.date
        else { return }
        // "It's 15:00" has to be true: launching at 21:00 still finds the
        // 15:00 slot current, and granny must not claim an hour she missed.
        let now = Schedule.minute(of: clockString(Date())) ?? 0
        guard now - (slot.minute ?? 0) < minutesPerHour else { return }
        announcedSlot = slot.id
        announcedDay = state.date
        let line = GrannyLines.slotCue(time: slot.time, task: task.title)
        speaker.say(line)
        postNotification(body: line)
    }

    private func applyBlocks(_ enforced: Bool) {
        guard !blockWorkInFlight else { return }
        if enforced {
            // Retry with a throttle: the authorization dialog may have been
            // cancelled, and the block is the whole point of the app. Also
            // re-applies when the config's domain list changed.
            let domains = config.blockedDomains + config.dohDomains
            if block.needsApply(domains), Date().timeIntervalSince(lastBlockAttempt) > Self.blockRetryInterval {
                lastBlockAttempt = Date()
                runBlockWork("block-applied", input: ["domains": "\(domains.count)"]) {
                    self.block.apply(domains: domains)
                }
            }
        } else if block.isBlocked(),
        Date().timeIntervalSince(lastClearAttempt) > Self.blockRetryInterval {
            // Same throttle as apply: a cancelled authorization dialog must
            // not pop again on every tick.
            lastClearAttempt = Date()
            runBlockWork("block-cleared", input: [:]) {
                self.block.clear()
            }
        }
    }

    /// `BlockController.apply`/`clear` wait on a subprocess (possibly an
    /// admin dialog), so they run on a serial background queue. The retry
    /// throttles above stay on main; only one operation may be in flight.
    private func runBlockWork(
        _ action: String, input: [String: String], _ work: @escaping () -> Bool
    ) {
        blockWorkInFlight = true
        blockQueue.async { [weak self] in
            guard let self else { return }
            let result = work()
            Task { await self.engine.recordAction(
                action,
                input: input,
                output: ["result": result ? "ok" : "failed"]) }
            DispatchQueue.main.async { self.blockWorkInFlight = false }
        }
    }
}
