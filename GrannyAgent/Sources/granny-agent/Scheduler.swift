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
    /// Fires when a rollover grew or killed a displayed streak.
    var onStreakEvent: ((StreakEvent) -> Void)?

    /// Tick cadence, and how long a failed apply/clear waits before the
    /// next attempt (a cancelled authorization dialog must not re-prompt
    /// on every tick).
    private static let tickInterval: TimeInterval = 15
    private static let blockRetryInterval: TimeInterval = 60

    private var timer: Timer?
    private var lastPhase: Phase?
    private var naggedDate: String?
    private var lastBlockAttempt = Date.distantPast
    private var lastClearAttempt = Date.distantPast
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
        if let event = store.rolloverIfNeeded() {
            onStreakEvent?(event)
        }
        let phase = computePhase(config: config, state: store.state)
        if phase != lastPhase {
            lastPhase = phase
            Task { await engine.clearCache() }
        }
        // Every tick, not only on phase change: a cancelled authorization
        // dialog or a failed apply must land on the next tick, gated by the
        // retry throttle inside.
        applyBlocks(phase)
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
    }

    private func applyBlocks(_ phase: Phase) {
        guard !blockWorkInFlight else { return }
        if phase.blocksActive {
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
