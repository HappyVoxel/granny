import AppKit
import GrannyCore

/// Closes entertainment apps while blocks are active: immediately when one
/// launches, and by sweeping already-running ones (a phase can turn into
/// "working" while Facebook was already open).
final class AppKiller {
    private let config: GrannyConfig
    private let phaseProvider: () -> Phase
    var onKill: ((String) -> Void)?

    /// Sweep cadence for already-running apps.
    private static let sweepInterval: TimeInterval = 5

    private var timer: Timer?

    init(config: GrannyConfig, phaseProvider: @escaping () -> Phase) {
        self.config = config
        self.phaseProvider = phaseProvider
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  shouldKill(bundleID: bundleID, phase: self.phaseProvider(), entertainmentApps: self.config.entertainmentApps)
            else { return }
            self.close(app)
        }

        sweep()
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Kills every running entertainment app while blocks are active.
    func sweep() {
        guard phaseProvider().blocksActive else { return }
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  shouldKill(bundleID: bundleID, phase: phaseProvider(), entertainmentApps: config.entertainmentApps)
            else { continue }
            close(app)
        }
    }

    private func close(_ app: NSRunningApplication) {
        let name = app.localizedName ?? app.bundleIdentifier ?? "app"
        let pid = app.processIdentifier
        app.terminate()
        onKill?(name)
        // Launchers and games swallow the graceful quit (their own confirm
        // dialog); force them down after a short grace period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let running = NSRunningApplication(processIdentifier: pid),
                  !running.isTerminated,
                  running.bundleIdentifier == app.bundleIdentifier else { return }
            running.forceTerminate()
        }
    }
}
