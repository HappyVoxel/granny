import Foundation
import GrannyCore
import UserNotifications

/// Posts granny's notifications. Prefers UserNotifications so they are
/// attributed to "granny" and can be tuned in System Settings; falls back to
/// osascript when running unbundled (CLI) or when permission is missing.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var started = false

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
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request)
            default:
                Notifier.osascript(title: title, body: body)
            }
        }
    }

    /// Show the banner even while granny is the frontmost app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
