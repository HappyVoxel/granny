import AppKit
import Foundation
import GrannyCore
import UserNotifications

/// Posts granny's notifications. Prefers UserNotifications so they are
/// attributed to "granny" and can be tuned in System Settings; falls back to
/// osascript when running unbundled (CLI) or when permission is missing.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var started = false

    /// What a click on one of granny's notifications does. The app delegate
    /// sets it: granny comes forward with her notebook, which is where the
    /// tasks are - and the tomato. A finished round is answered by clicking
    /// that tomato, so the bell's banner has to land where the tomato is.
    var onOpen: (() -> Void)?

    func start() {
        guard !started, Bundle.main.bundleIdentifier != nil else { return }
        started = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            Notifier.osascript(title: title, body: body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Notifier.deliver(title: title, body: body, via: center)
            case .notDetermined:
                // A freshly rebuilt (ad-hoc) app starts undetermined; ask
                // once here so the banner wears granny's icon instead of
                // osascript's Script Editor one.
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        Notifier.deliver(title: title, body: body, via: center)
                    } else {
                        Notifier.osascript(title: title, body: body)
                    }
                }
            default:
                Notifier.osascript(title: title, body: body)
            }
        }
    }

    private static func deliver(title: String, body: String, via center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// Show the banner even while granny is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// A click on the banner brings granny forward instead of leaving the
    /// grandchild to find her.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in self?.onOpen?() }
        completionHandler()
    }

    static func osascript(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e",
            "display notification \(Quoting.appleScript(body)) with title \(Quoting.appleScript(title))",
        ]
        try? process.run()
    }
}

func postNotification(title: String = "granny", body: String) {
    Notifier.shared.post(title: title, body: body)
}

/// The pomodoro's bell, rung by granny herself. A notification can be muted by
/// Focus or by the banner settings, and one system sound is about a second -
/// it disappears under music or a meeting. So the bell rings a few times, and
/// stops the moment it is answered.
///
/// An instance rather than a namespace: the ring pattern is state (a timer and
/// a count left), and static mutable state needs isolation this does not.
final class Chime {
    /// How many times the bell rings, and how far apart: one system sound runs
    /// about a second, so three of them are roughly four seconds of bell.
    private static let rings = 3
    private static let gap: TimeInterval = 1.3

    private var timer: Timer?
    private var ringsLeft = 0
    private var name = "Glass"

    /// A deep-work round is over: the break has started.
    func breakTime() { ring("Glass") }
    /// A break is over: back to the desk.
    func backToWork() { ring("Ping") }

    /// Rings no more. The tomato answers the bell the moment it is clicked,
    /// and a new stage's bell takes over from the one still ringing.
    func silence() {
        timer?.invalidate()
        timer = nil
        ringsLeft = 0
        NSSound(named: NSSound.Name(name))?.stop()
    }

    func ring(_ sound: String) {
        silence()
        name = sound
        ringsLeft = Self.rings
        play()
        guard ringsLeft > 0 else { return }
        let timer = Timer(timeInterval: Self.gap, repeats: true) { [weak self] _ in
            self?.play()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func play() {
        guard ringsLeft > 0 else { return silence() }
        ringsLeft -= 1
        // `GRANNY_CHIME` replaces the system sound with a command, the way
        // `GRANNY_OSA_CMD` replaces osascript: a run can silence the bell, and
        // a manual one can watch it ring (the command gets the sound's name).
        if let tool = ProcessInfo.processInfo.environment[GrannyEnv.chime], !tool.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = [name]
            // Forward the command's output: the point of the seam is to watch
            // the bell ring - `/bin/date` shows the three rings and their
            // spacing.
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            try? process.run()
            return
        }
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            NSSound.beep()
            return
        }
        // System sounds are shared and cached: stop before replaying, so a
        // quick second ring is not swallowed.
        sound.stop()
        sound.volume = 0.85
        sound.play()
    }
}

final class Speaker {
    var enabled = false
    var voice: String?

    func say(_ text: String) {
        guard enabled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var arguments: [String] = []
        if let voice, !voice.isEmpty {
            arguments += ["-v", voice]
        }
        arguments.append(text)
        process.arguments = arguments
        try? process.run()
    }

    /// Installed voices, as reported by `say -v '?'`.
    static func systemVoices() -> [GrannyVoice.Voice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "?"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return GrannyVoice.parse(output)
    }
}
