import Foundation

/// Every language granny can speak. The `code` is a BCP-47 language tag
/// (lowercased, region dropped); unknown codes fall back to English.
public enum GrannyLanguage: String, CaseIterable, Sendable {
    case en
    case vi
    case fi

    public init?(code: String) {
        let base = code.lowercased().split(separator: "-").first.map(String.init) ?? ""
        self.init(rawValue: base)
    }

    /// The language's own name, shown in Settings.
    public var displayName: String {
        switch self {
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        case .fi: return "Suomi"
        }
    }

    public var strings: any GrannyStrings {
        switch self {
        case .en: return EnglishStrings()
        case .vi: return VietnameseStrings()
        case .fi: return FinnishStrings()
        }
    }

    /// First supported language among the machine's preferences, English
    /// otherwise. Used on a fresh install, before a config exists.
    public static func preferred(from codes: [String]) -> GrannyLanguage {
        for code in codes {
            if let language = GrannyLanguage(code: code) { return language }
        }
        return .en
    }
}

/// Granny's voice, one conformance per language. Adding a language means
/// adding a struct: the compiler lists every string it still needs.
public protocol GrannyStrings: Sendable {
    // Intake
    var greeting: String { get }
    var greetHint: String { get }
    var saved: String { get }
    var challengeFallback: String { get }

    // Verdicts
    var warnGeneric: String { get }
    var shorts: String { get }
    func blocked(host: String) -> String
    func offSurface(task: String) -> String
    func surfaceAllow(task: String) -> String

    // Enforcement
    func killApp(name: String, task: String?) -> String
    func closedTab(url: String) -> String
    func browserControlDenied(browser: String) -> String
    func browserNotScriptable(browser: String) -> String
    var helperMissing: String { get }
    var helperInstalled: String { get }
    var helperInstallerMissing: String { get }
    func decisionServerFailed(port: Int) -> String

    // Day cycle
    var sleepNag: String { get }
    func reward(bedtime: Int) -> String
    func dayOffConfirm() -> String
    var dayOffDone: String { get }

    // Setup
    var setupHint: String { get }
    var setupKeyReminder: String { get }
    var openSettingsButton: String { get }
    var appearanceHint: String { get }

    // Window titles
    var windowTitle: String { get }
    var settingsTitle: String { get }
    var tasksTitle: String { get }
    var notebookLabel: String { get }
    var tasksNotebookLabel: String { get }

    // Task list
    var saveButton: String { get }
    var dayOffButton: String { get }
    var markAllDoneButton: String { get }
    var tasksEmpty: String { get }
    var addTaskButton: String { get }
    var addTaskPlaceholder: String { get }
    var addTaskConfirm: String { get }
    var cancelButton: String { get }
    var taskAdded: String { get }
    /// Yesterday's unfinished work.
    func carryOver(tasks: [String]) -> String
    var carriedBadge: String { get }

    // Streak
    var streakHelp: String { get }
    func streakUp(count: Int) -> String
    func streakLost(days: Int) -> String

    // Status line
    var statusAwaiting: String { get }
    var statusWorking: String { get }
    var statusRewarded: String { get }
    var statusDayOff: String { get }
    var statusNight: String { get }

    // Menu
    var menuTodayList: String { get }
    var menuDayOff: String { get }
    var menuTestURL: String { get }
    var menuSettings: String { get }
    var menuInstallHelper: String { get }
    var menuOpenConfig: String { get }
    var menuQuit: String { get }
    var statusPrefix: String { get }
    var dayOffTag: String { get }

    // Dialogs
    var savedTitle: String { get }
    var relaunchBody: String { get }
    var relaunchNow: String { get }
    var relaunchLater: String { get }
    var configSaveFailed: String { get }
    var testURLTitle: String { get }
    var testURLBody: String { get }
    var judgeButton: String { get }
    var challengeTitle: String { get }
    var answerButton: String { get }
    var grannyAsks: String { get }
    var agreeButton: String { get }
    var backButton: String { get }

    // Settings
    var settingsSubtitle: String { get }
    var settingsAIGroup: String { get }
    var settingsOpenRouterKey: String { get }
    var settingsModel: String { get }
    var settingsAICaption: String { get }
    var settingsClassifierGroup: String { get }
    var settingsLayaURL: String { get }
    var settingsLayaKey: String { get }
    var settingsJevModel: String { get }
    var settingsJevURL: String { get }
    var settingsJevKey: String { get }
    var settingsClassifierCaption: String { get }
    var settingsTracingGroup: String { get }
    var settingsHost: String { get }
    var settingsPublicKey: String { get }
    var settingsSecretKey: String { get }
    var settingsLanguageGroup: String { get }
    var settingsSpeaksLabel: String { get }
    var settingsLanguageCaption: String { get }
    var settingsAppearanceGroup: String { get }
    var settingsThemeLabel: String { get }
    var settingsThemeSystem: String { get }
    var settingsThemeDark: String { get }
    var settingsThemeLight: String { get }
    var settingsDayGroup: String { get }
    var settingsWakeHour: String { get }
    var settingsBedtime: String { get }
    var settingsSpeechToggle: String { get }
    var settingsListsGroup: String { get }
    var settingsAppsLabel: String { get }
    var settingsAppsCaption: String { get }
    var settingsAppsAdd: String { get }
    var settingsBlockedSitesLabel: String { get }
    var settingsAllowedSitesLabel: String { get }
    var settingsAllowedSitesCaption: String { get }
    var settingsSitePlaceholder: String { get }
    var settingsAddSite: String { get }
    var settingsRemoveEntry: String { get }
    var surfacesEditTitle: String { get }
    var surfacesCaption: String { get }
    var surfacesPlaceholder: String { get }
    var surfacesEditHelp: String { get }
    var dropTaskHelp: String { get }
    var settingsSave: String { get }
    var keyCheckValid: String { get }
    var keyCheckInvalid: String { get }
    var keyCheckUnreachable: String { get }
    var secretShow: String { get }
    var secretHide: String { get }
    func updateAvailable(version: String) -> String
    var menuUpdateAvailable: String { get }
}

public extension GrannyStrings {
    /// The app's name is the same in every language.
    var windowTitle: String { "granny" }
}

// MARK: - English

public struct EnglishStrings: GrannyStrings {
    public init() {}

    public var greeting: String { "So, what is my dear grandchild up to today?" }
    public var greetHint: String { "One task per line, or separate with ;" }
    public var saved: String { "Granny wrote it down. Tell me when you're done, dear." }
    public var challengeFallback: String { "What exactly is this task, dear? Tell granny properly." }

    public var warnGeneric: String { "Easy there, dear. This isn't helping today's work." }
    public var shorts: String { "No Shorts, dear. Finish your work and granny will let you watch all evening." }
    public func blocked(host: String) -> String {
        "Granny saw you heading to \(host). Finish your work first, then play."
    }
    public func offSurface(task: String) -> String {
        "Today's job is \"\(task)\", remember? Stay on it, dear."
    }
    public func surfaceAllow(task: String) -> String {
        "That's for \"\(task)\" - go on and finish it, dear."
    }

    public func killApp(name: String, task: String?) -> String {
        if let task, !task.isEmpty {
            return "You're in the middle of \"\(task)\" and opening \(name)? Granny is closing it, dear. Finish your work, then play."
        }
        return "Opening \(name) during work? Granny is closing it, dear. Finish your work, then play."
    }
    public func closedTab(url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return "Granny saw a \(host) tab open. Cleaned it up, dear. Finish your work, then play."
    }
    public func browserControlDenied(browser: String) -> String {
        "Granny isn't allowed to control \(browser) yet. Enable it in System Settings > Privacy & Security > Automation (granny -> \(browser)) so she can tidy tabs."
    }
    public func browserNotScriptable(browser: String) -> String {
        "Granny sees \(browser) running but can't control it (no AppleScript support). Install the granny extension so she can tidy its tabs."
    }
    public var helperMissing: String {
        "Granny couldn't lock the door: the password was cancelled. Install the helper once (granny menu -> Install helper…) so she never asks again."
    }
    public var helperInstalled: String {
        "Helper installed. Granny locks the door without asking again."
    }
    public var helperInstallerMissing: String {
        "Granny's helper installer is missing from the app bundle. Reinstall granny to fix it."
    }
    public func decisionServerFailed(port: Int) -> String {
        "Granny couldn't open the decision server on port \(port)."
    }

    public var sleepNag: String { "It's late, dear. Off to bed - tomorrow is another day." }
    public func reward(bedtime: Int) -> String { "Good grandchild. Go play, be back before \(bedtime)." }
    public func dayOffConfirm() -> String { "Are you sure? Granny writes it down. A real day off?" }
    public var dayOffDone: String { "Granny wrote it down. Rest up, dear." }

    public var setupHint: String {
        "Granny has no OpenRouter key yet. Open Settings and paste one - she needs it to judge pages."
    }
    public var setupKeyReminder: String { "Granny has no OpenRouter key yet. Open Settings and paste one, dear." }
    public var openSettingsButton: String { "Open Settings" }
    public var appearanceHint: String { "Switch granny's look; takes effect after relaunch." }

    public var settingsTitle: String { "granny Settings" }
    public var tasksTitle: String { "Today" }
    public var notebookLabel: String { "THE DAILY LIST" }
    public var tasksNotebookLabel: String { "GRANNY'S NOTEBOOK" }

    public var saveButton: String { "Write it down" }
    public var dayOffButton: String { "Today is my day off" }
    public var markAllDoneButton: String { "Tell granny I'm done" }
    public var tasksEmpty: String { "No tasks yet." }
    public var addTaskButton: String { "Add task" }
    public var addTaskPlaceholder: String { "New task…" }
    public var addTaskConfirm: String { "Add" }
    public var cancelButton: String { "Cancel" }
    public var taskAdded: String { "Granny added it, dear." }
    public func carryOver(tasks: [String]) -> String {
        let list = tasks.joined(separator: "; ")
        if tasks.count == 1 {
            return "Yesterday's \"\(list)\" is still open, dear. Remember to eat that frog."
        }
        return "Yesterday's \"\(list)\" are still open, dear. Remember to eat those frogs."
    }
    public var carriedBadge: String { "Left over from yesterday - eat the frog first" }
    public var streakHelp: String { "Clean days in a row - no frogs left behind" }
    public func streakUp(count: Int) -> String {
        "🔥 \(count) clean days in a row, dear. Keep it going."
    }
    public func streakLost(days: Int) -> String {
        "The streak stopped at \(days), dear. Start a new one today."
    }

    public var statusAwaiting: String { "Today's list isn't written yet." }
    public var statusWorking: String { "Working. Granny lets you play when it's all done." }
    public var statusRewarded: String { "All done. Go play, dear." }
    public var statusDayOff: String { "Day off today." }
    public var statusNight: String { "It's late. Off to bed, dear." }

    public var menuTodayList: String { "Today's list…" }
    public var menuDayOff: String { "Day off…" }
    public var menuTestURL: String { "Test a URL…" }
    public var menuSettings: String { "Settings…" }
    public var menuInstallHelper: String { "Install helper…" }
    public var menuOpenConfig: String { "Open config" }
    public var menuQuit: String { "Quit granny" }
    public var statusPrefix: String { "Phase" }
    public var dayOffTag: String { "(day off)" }

    public var savedTitle: String { "Saved" }
    public var relaunchBody: String { "Granny needs a relaunch to use the new keys." }
    public var relaunchNow: String { "Relaunch" }
    public var relaunchLater: String { "Later" }
    public var configSaveFailed: String { "Couldn't save the config" }
    public var testURLTitle: String { "Test a URL" }
    public var testURLBody: String { "Granny will judge this URL against today's tasks." }
    public var judgeButton: String { "Judge" }
    public var challengeTitle: String { "Granny asks" }
    public var answerButton: String { "Answer" }
    public var grannyAsks: String { "Granny asks" }
    public var agreeButton: String { "Agree" }
    public var backButton: String { "Back" }

    public var settingsSubtitle: String { "Keys stay on this Mac in ~/.config/granny/config.json (mode 600)." }
    public var settingsAIGroup: String { "AI — page verdicts" }
    public var settingsOpenRouterKey: String { "OpenRouter key" }
    public var settingsModel: String { "Model" }
    public var settingsAICaption: String {
        "Fast classifier (Laya/Jev) is tried before the model; leave the model as the fallback and for chat later."
    }
    public var settingsClassifierGroup: String { "Fast classifier (optional)" }
    public var settingsLayaURL: String { "Laya URL" }
    public var settingsLayaKey: String { "Laya key" }
    public var settingsJevModel: String { "Jev model" }
    public var settingsJevURL: String { "Jev URL" }
    public var settingsJevKey: String { "Jev key" }
    public var settingsClassifierCaption: String {
        "Laya is your self-hosted classifier and runs first. If it is missing or down, granny falls back to Jev: automatically through OpenRouter when a key is set (default model above), or through TypeSafe's own API with the Jev URL/key."
    }
    public var settingsTracingGroup: String { "Tracing (optional, Langfuse)" }
    public var settingsHost: String { "Host" }
    public var settingsPublicKey: String { "Public key" }
    public var settingsSecretKey: String { "Secret key" }
    public var settingsLanguageGroup: String { "Language" }
    public var settingsSpeaksLabel: String { "Granny speaks" }
    public var settingsLanguageCaption: String { "Same warm granny, any language. Takes effect after relaunch." }
    public var settingsAppearanceGroup: String { "Appearance" }
    public var settingsThemeLabel: String { "Theme" }
    public var settingsThemeSystem: String { "System" }
    public var settingsThemeDark: String { "Dark" }
    public var settingsThemeLight: String { "Light" }
    public var settingsDayGroup: String { "Day" }
    public var settingsWakeHour: String { "Wake hour" }
    public var settingsBedtime: String { "Bedtime" }
    public var settingsSpeechToggle: String { "Granny speaks (say -v)" }
    public var settingsListsGroup: String { "Granny's watchlists" }
    public var settingsAppsLabel: String { "Apps closed during work" }
    public var settingsAppsCaption: String {
        "Granny closes these apps while tasks are open. Pick an app to add it; the trash removes it."
    }
    public var settingsAppsAdd: String { "Choose app…" }
    public var settingsBlockedSitesLabel: String { "Blocked sites" }
    public var settingsAllowedSitesLabel: String { "Allowed sites" }
    public var settingsAllowedSitesCaption: String {
        "Granny looks away from these completely - they stay open even while tasks are undone."
    }
    public var settingsSitePlaceholder: String { "e.g. threads.com" }
    public var settingsAddSite: String { "Add" }
    public var settingsRemoveEntry: String { "Remove" }
    public var surfacesEditTitle: String { "ALLOWED URLS" }
    public var surfacesCaption: String {
        "While this task is open, granny lets these URL patterns through - the block lists come second. e.g. threads.com/feed*"
    }
    public var surfacesPlaceholder: String { "e.g. threads.com/feed*" }
    public var surfacesEditHelp: String { "Edit allowed URLs" }
    public var dropTaskHelp: String { "Drop this task from the notebook" }
    public var settingsSave: String { "Save" }
    public var keyCheckValid: String { "Key works." }
    public var keyCheckInvalid: String { "Granny can't use this key." }
    public var keyCheckUnreachable: String { "Couldn't reach the service." }
    public var secretShow: String { "Show" }
    public var secretHide: String { "Hide" }

    public func updateAvailable(version: String) -> String {
        "A newer granny is out: v\(version). Update with: brew upgrade --cask granny"
    }
    public var menuUpdateAvailable: String { "Update available…" }
}

// MARK: - Vietnamese

public struct VietnameseStrings: GrannyStrings {
    public init() {}

    public var greeting: String { "Hôm nay cháu của ta sẽ làm những gì đây?" }
    public var greetHint: String { "Mỗi dòng một việc, hoặc ngăn cách bằng dấu ;" }
    public var saved: String { "Ngoại đã ghi sổ. Làm xong thì báo ngoại nhé." }
    public var challengeFallback: String { "Việc này cụ thể là gì, cháu nói rõ cho ngoại xem nào?" }

    public var warnGeneric: String { "Từ từ đã cháu, cái này chưa giúp gì cho việc hôm nay đâu nhé." }
    public var shorts: String { "Shorts thì không nhé cháu. Xong việc ngoại cho xem cả tối." }
    public func blocked(host: String) -> String {
        "Ngoại thấy cháu định vào \(host) đấy. Xong việc đã rồi hẵng chơi."
    }
    public func offSurface(task: String) -> String {
        "Việc hôm nay là «\(task)» cơ mà? Làm đúng phần việc thôi nhé."
    }
    public func surfaceAllow(task: String) -> String {
        "Đúng việc «\(task)» thì làm cho xong nhé cháu."
    }

    public func killApp(name: String, task: String?) -> String {
        if let task, !task.isEmpty {
            return "Đang làm dở «\(task)» mà mở \(name) à? Ngoại đóng lại đấy. Xong việc rồi lướt gì thì lướt nhé cháu."
        }
        return "Giờ làm việc mà mở \(name) à? Ngoại đóng lại đấy. Xong việc rồi lướt gì thì lướt nhé cháu."
    }
    public func closedTab(url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return "Ngoại thấy tab \(host) đang mở đây. Ngoại dọn rồi nhé. Xong việc rồi lướt gì thì lướt."
    }
    public func browserControlDenied(browser: String) -> String {
        "Ngoại chưa được phép điều khiển \(browser). Bật trong System Settings > Privacy & Security > Automation (granny → \(browser)) để ngoại tự dọn tab."
    }
    public func browserNotScriptable(browser: String) -> String {
        "Ngoại thấy \(browser) đang mở nhưng không điều khiển được nó (không hỗ trợ AppleScript). Cài extension granny để ngoại dọn tab trong đó nhé."
    }
    public var helperMissing: String {
        "Ngoại chưa khóa được cửa: password bị hủy. Cài helper một lần (menu ngoại → Install helper…) để khỏi phải nhập lại."
    }
    public var helperInstalled: String {
        "Helper cài xong. Ngoại khóa cửa không hỏi lại nữa."
    }
    public var helperInstallerMissing: String {
        "Thiếu file cài helper trong app bundle. Cài lại granny để sửa nhé."
    }
    public func decisionServerFailed(port: Int) -> String {
        "Decision server không mở được cổng \(port)."
    }

    public var sleepNag: String { "Muộn rồi cháu. Đi ngủ đi, mai còn làm việc." }
    public func reward(bedtime: Int) -> String { "Tốt lắm cháu. Đi chơi đi, nhớ về trước \(bedtime) giờ." }
    public func dayOffConfirm() -> String { "Chắc chưa? Ngoại ghi sổ đấy. Hôm nay nghỉ thật à?" }
    public var dayOffDone: String { "Ngoại ghi sổ rồi. Nghỉ ngơi đi cháu." }

    public var setupHint: String {
        "Ngoại chưa có chìa khóa OpenRouter. Mở Settings dán vào nhé — ngoại cần nó để phán trang."
    }
    public var setupKeyReminder: String { "Ngoại chưa có chìa khóa OpenRouter. Vào Settings dán vào nhé cháu." }
    public var openSettingsButton: String { "Mở Settings" }
    public var appearanceHint: String { "Đổi giao diện ngoại; cần khởi động lại." }

    public var settingsTitle: String { "Cài đặt ngoại" }
    public var tasksTitle: String { "Việc hôm nay" }
    public var notebookLabel: String { "SỔ HÔM NAY" }
    public var tasksNotebookLabel: String { "SỔ TAY CỦA NGOẠI" }

    public var saveButton: String { "Ngoại ghi sổ" }
    public var dayOffButton: String { "Hôm nay là day off của cháu" }
    public var markAllDoneButton: String { "Báo ngoại xong hết" }
    public var tasksEmpty: String { "Chưa có việc nào." }
    public var addTaskButton: String { "Thêm việc" }
    public var addTaskPlaceholder: String { "Việc mới…" }
    public var addTaskConfirm: String { "Thêm" }
    public var cancelButton: String { "Huỷ" }
    public var taskAdded: String { "Ngoại ghi thêm rồi nhé." }
    public func carryOver(tasks: [String]) -> String {
        let list = tasks.joined(separator: "; ")
        if tasks.count == 1 {
            return "Hôm qua cháu còn \"\(list)\" chưa xong đấy. Nhớ ăn con ếch đó nhé."
        }
        return "Hôm qua cháu còn \"\(list)\" chưa xong đấy. Nhớ ăn mấy con ếch đó nhé."
    }
    public var carriedBadge: String { "Còn lại từ hôm qua - ăn con ếch trước nhé" }
    public var streakHelp: String { "Số ngày liên tiếp xong hết việc - không con ếch nào bị bỏ lại" }
    public func streakUp(count: Int) -> String {
        "🔥 \(count) ngày liên tiếp sạch sổ rồi cháu. Giữ phong độ nhé."
    }
    public func streakLost(days: Int) -> String {
        "Streak đứt ở \(days) ngày rồi cháu. Hôm nay làm lại từ đầu nhé."
    }

    public var statusAwaiting: String { "Chưa nhập danh sách hôm nay." }
    public var statusWorking: String { "Đang làm việc. Xong hết ngoại mới cho chơi." }
    public var statusRewarded: String { "Xong việc rồi. Đi chơi đi cháu." }
    public var statusDayOff: String { "Hôm nay nghỉ." }
    public var statusNight: String { "Muộn rồi. Đi ngủ đi cháu." }

    public var menuTodayList: String { "Sổ hôm nay…" }
    public var menuDayOff: String { "Ngày nghỉ…" }
    public var menuTestURL: String { "Thử URL…" }
    public var menuSettings: String { "Cài đặt…" }
    public var menuInstallHelper: String { "Cài helper…" }
    public var menuOpenConfig: String { "Mở config" }
    public var menuQuit: String { "Thoát granny" }
    public var statusPrefix: String { "Trạng thái" }
    public var dayOffTag: String { "(nghỉ)" }

    public var savedTitle: String { "Đã lưu" }
    public var relaunchBody: String { "Ngoại cần khởi động lại để dùng keys mới." }
    public var relaunchNow: String { "Khởi động lại" }
    public var relaunchLater: String { "Để sau" }
    public var configSaveFailed: String { "Không lưu được config" }
    public var testURLTitle: String { "Thử một URL" }
    public var testURLBody: String { "Ngoại sẽ phán URL này theo danh sách việc hiện tại." }
    public var judgeButton: String { "Phán" }
    public var challengeTitle: String { "Ngoại hỏi thêm" }
    public var answerButton: String { "Trả lời" }
    public var grannyAsks: String { "Ngoại hỏi" }
    public var agreeButton: String { "Đồng ý" }
    public var backButton: String { "Quay lại" }

    public var settingsSubtitle: String { "Keys ở lại máy này trong ~/.config/granny/config.json (mode 600)." }
    public var settingsAIGroup: String { "AI — phán trang" }
    public var settingsOpenRouterKey: String { "OpenRouter key" }
    public var settingsModel: String { "Model" }
    public var settingsAICaption: String {
        "Fast classifier (Laya/Jev) thử trước model; model là fallback và dành cho chat sau này."
    }
    public var settingsClassifierGroup: String { "Fast classifier (tuỳ chọn)" }
    public var settingsLayaURL: String { "Laya URL" }
    public var settingsLayaKey: String { "Laya key" }
    public var settingsJevModel: String { "Jev model" }
    public var settingsJevURL: String { "Jev URL" }
    public var settingsJevKey: String { "Jev key" }
    public var settingsClassifierCaption: String {
        "Laya là classifier tự host của bạn, chạy trước. Nếu thiếu hoặc down, ngoại rơi xuống Jev: tự động qua OpenRouter khi có key (model mặc định ở trên), hoặc qua API riêng của TypeSafe bằng Jev URL/key."
    }
    public var settingsTracingGroup: String { "Tracing (tuỳ chọn, Langfuse)" }
    public var settingsHost: String { "Host" }
    public var settingsPublicKey: String { "Public key" }
    public var settingsSecretKey: String { "Secret key" }
    public var settingsLanguageGroup: String { "Ngôn ngữ" }
    public var settingsSpeaksLabel: String { "Ngoại nói" }
    public var settingsLanguageCaption: String { "Cùng một ngoại ấm áp, ngôn ngữ nào cũng vậy. Cần khởi động lại." }
    public var settingsAppearanceGroup: String { "Giao diện" }
    public var settingsThemeLabel: String { "Theme" }
    public var settingsThemeSystem: String { "Theo máy" }
    public var settingsThemeDark: String { "Tối" }
    public var settingsThemeLight: String { "Sáng" }
    public var settingsDayGroup: String { "Ngày" }
    public var settingsWakeHour: String { "Giờ thức" }
    public var settingsBedtime: String { "Giờ ngủ" }
    public var settingsSpeechToggle: String { "Ngoại nói (say -v)" }
    public var settingsListsGroup: String { "Danh sách của ngoại" }
    public var settingsAppsLabel: String { "Ứng dụng bị đóng khi làm việc" }
    public var settingsAppsCaption: String {
        "Ngoại đóng những app này khi còn việc chưa xong. Chọn app để thêm, thùng rác để bỏ."
    }
    public var settingsAppsAdd: String { "Chọn app…" }
    public var settingsBlockedSitesLabel: String { "Trang bị chặn" }
    public var settingsAllowedSitesLabel: String { "Trang được phép" }
    public var settingsAllowedSitesCaption: String {
        "Ngoại làm ngơ hoàn toàn những trang này - còn việc vẫn mở được."
    }
    public var settingsSitePlaceholder: String { "ví dụ: threads.com" }
    public var settingsAddSite: String { "Thêm" }
    public var settingsRemoveEntry: String { "Bỏ" }
    public var surfacesEditTitle: String { "URL ĐƯỢC PHÉP" }
    public var surfacesCaption: String {
        "Khi task này còn dở, ngoại cho phép mở những mẫu URL này - danh sách chặn phải nhường. Ví dụ: threads.com/feed*"
    }
    public var surfacesPlaceholder: String { "ví dụ: threads.com/feed*" }
    public var surfacesEditHelp: String { "Sửa URL được phép" }
    public var dropTaskHelp: String { "Bỏ việc này khỏi sổ" }
    public var settingsSave: String { "Lưu" }
    public var keyCheckValid: String { "Key dùng được." }
    public var keyCheckInvalid: String { "Ngoại không dùng được key này." }
    public var keyCheckUnreachable: String { "Không kết nối được dịch vụ." }
    public var secretShow: String { "Hiện" }
    public var secretHide: String { "Ẩn" }

    public func updateAvailable(version: String) -> String {
        "Ngoại có bản mới: v\(version). Cập nhật bằng: brew upgrade --cask granny"
    }
    public var menuUpdateAvailable: String { "Có bản cập nhật…" }
}

// MARK: - Finnish

public struct FinnishStrings: GrannyStrings {
    public init() {}

    public var greeting: String { "No, mitäs mummon kulta tekee tänään?" }
    public var greetHint: String { "Yksi tehtävä per rivi tai erottele puolipisteellä ;" }
    public var saved: String { "Mummo kirjasi ne ylös. Kerro, kun olet valmis, kulta." }
    public var challengeFallback: String { "Mikä tämä tehtävä oikein on, kulta? Kerro mummolle tarkemmin." }

    public var warnGeneric: String { "Rauhallisesti, kulta. Tämä ei auta tämän päivän töissä." }
    public var shorts: String { "Ei Shortseja, kulta. Tee työt loppuun, niin mummo antaa katsoa koko illan." }
    public func blocked(host: String) -> String {
        "Mummo näki, että olit menossa osoitteeseen \(host). Tee työt ensin, leiki sitten."
    }
    public func offSurface(task: String) -> String {
        "Tämän päivän työ on \"\(task)\", muistatko? Pysy siinä, kulta."
    }
    public func surfaceAllow(task: String) -> String {
        "Tuohan on tehtävää \"\(task)\" varten - jatka ja saat sen valmiiksi, kulta."
    }

    public func killApp(name: String, task: String?) -> String {
        if let task, !task.isEmpty {
            return "Olet kesken \"\(task)\" ja avaat \(name)? Mummo sulkee sen, kulta. Tee työt loppuun, leiki sitten."
        }
        return "Avaat \(name) kesken työpäivän? Mummo sulkee sen, kulta. Tee työt loppuun, leiki sitten."
    }
    public func closedTab(url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return "Mummolta jäi \(host)-välilehti auki. Mummo siivosi sen, kulta. Tee työt loppuun, leiki sitten."
    }
    public func browserControlDenied(browser: String) -> String {
        "Mummolla ei ole vielä lupaa ohjata \(browser)-selainta. Salli se: Järjestelmäasetukset > Tietosuoja ja turvallisuus > Automaatio (granny -> \(browser))."
    }
    public func browserNotScriptable(browser: String) -> String {
        "Mummo näkee, että \(browser) on auki, mutta ei voi ohjata sitä (ei AppleScript-tukea). Asenna granny-laajennus, niin mummo siivoaa sen välilehdet."
    }
    public var helperMissing: String {
        "Mummo ei saanut ovea lukkoon: salasana peruutettiin. Asenna helper kerran (granny-valikko -> Install helper…)."
    }
    public var helperInstalled: String {
        "Helper asennettu. Mummo lukitsee oven kysymättä uudelleen."
    }
    public var helperInstallerMissing: String {
        "Mummon helper-asentaja puuttuu sovelluspaketista. Asenna granny uudelleen."
    }
    public func decisionServerFailed(port: Int) -> String {
        "Mummo ei saanut päätöspalvelinta auki porttiin \(port)."
    }

    public var sleepNag: String { "Nyt on myöhä, kulta. Nukkumaan - huomenna on taas päivä." }
    public func reward(bedtime: Int) -> String { "Hyvä kulta. Mene leikkimään, palaa ennen kello \(bedtime)." }
    public func dayOffConfirm() -> String { "Oletko varma? Mummo kirjaa sen ylös. Oikeasti vapaapäivä?" }
    public var dayOffDone: String { "Mummo kirjasi sen ylös. Lepää, kulta." }

    public var setupHint: String {
        "Mummolla ei ole vielä OpenRouter-avainta. Avaa asetukset ja liitä se - mummo tarvitsee sitä sivujen arviointiin."
    }
    public var setupKeyReminder: String { "Mummolla ei ole vielä OpenRouter-avainta. Avaa asetukset ja liitä se, kulta." }
    public var openSettingsButton: String { "Avaa asetukset" }
    public var appearanceHint: String { "Vaihda mummon ulkoasua; astuu voimaan uudelleenkäynnistyksen jälkeen." }

    public var settingsTitle: String { "grannyn asetukset" }
    public var tasksTitle: String { "Tänään" }
    public var notebookLabel: String { "TÄMÄN PÄIVÄN LISTA" }
    public var tasksNotebookLabel: String { "MUMMON MUISTIKIRJA" }

    public var saveButton: String { "Kirjaa ylös" }
    public var dayOffButton: String { "Tänään on vapaapäiväni" }
    public var markAllDoneButton: String { "Kerro mummolle, että olen valmis" }
    public var tasksEmpty: String { "Ei tehtäviä vielä." }
    public var addTaskButton: String { "Lisää tehtävä" }
    public var addTaskPlaceholder: String { "Uusi tehtävä…" }
    public var addTaskConfirm: String { "Lisää" }
    public var cancelButton: String { "Peruuta" }
    public var taskAdded: String { "Mummo lisäsi sen, kulta." }
    public func carryOver(tasks: [String]) -> String {
        let list = tasks.joined(separator: "; ")
        if tasks.count == 1 {
            return "Eilen \"\(list)\" jäi vielä kesken, kulta. Muista syödä se sammakko."
        }
        return "Eilen \"\(list)\" jäivät vielä kesken, kulta. Muista syödä ne sammakot."
    }
    public var carriedBadge: String { "Eilen kesken jäänyt - syö sammakko ensin" }
    public var streakHelp: String { "Peräkkäiset puhtaat päivät - ei sammakoita jäänyt" }
    public func streakUp(count: Int) -> String {
        "🔥 \(count) puhdasta päivää putkeen, kulta. Jatka samaan malliin."
    }
    public func streakLost(days: Int) -> String {
        "Putki katkesi \(days) päivän kohdalla, kulta. Aloita uusi tänään."
    }

    public var statusAwaiting: String { "Tämän päivän listaa ei ole vielä kirjoitettu." }
    public var statusWorking: String { "Työ kesken. Mummo päästää leikkimään, kun kaikki on valmista." }
    public var statusRewarded: String { "Kaikki valmista. Mene leikkimään, kulta." }
    public var statusDayOff: String { "Tänään on vapaapäivä." }
    public var statusNight: String { "On myöhä. Nukkumaan, kulta." }

    public var menuTodayList: String { "Tämän päivän lista…" }
    public var menuDayOff: String { "Vapaapäivä…" }
    public var menuTestURL: String { "Testaa URL…" }
    public var menuSettings: String { "Asetukset…" }
    public var menuInstallHelper: String { "Asenna helper…" }
    public var menuOpenConfig: String { "Avaa config" }
    public var menuQuit: String { "Lopeta granny" }
    public var statusPrefix: String { "Tila" }
    public var dayOffTag: String { "(vapaapäivä)" }

    public var savedTitle: String { "Tallennettu" }
    public var relaunchBody: String { "Mummo tarvitsee uudelleenkäynnistyksen käyttääkseen uusia avaimia." }
    public var relaunchNow: String { "Käynnistä uudelleen" }
    public var relaunchLater: String { "Myöhemmin" }
    public var configSaveFailed: String { "Configin tallennus ei onnistunut" }
    public var testURLTitle: String { "Testaa URL" }
    public var testURLBody: String { "Mummo arvioi tämän URL-osoitteen tämän päivän tehtävien perusteella." }
    public var judgeButton: String { "Arvioi" }
    public var challengeTitle: String { "Mummo kysyy" }
    public var answerButton: String { "Vastaa" }
    public var grannyAsks: String { "Mummo kysyy" }
    public var agreeButton: String { "Kyllä" }
    public var backButton: String { "Takaisin" }

    public var settingsSubtitle: String { "Avaimet pysyvät tällä Macilla: ~/.config/granny/config.json (oikeudet 600)." }
    public var settingsAIGroup: String { "Tekoäly — sivujen arviot" }
    public var settingsOpenRouterKey: String { "OpenRouter-avain" }
    public var settingsModel: String { "Malli" }
    public var settingsAICaption: String {
        "Nopea luokittelija (Laya/Jev) kokeillaan ennen mallia; malli jää varavaihtoehdoksi ja chattiin myöhemmin."
    }
    public var settingsClassifierGroup: String { "Nopea luokittelija (valinnainen)" }
    public var settingsLayaURL: String { "Laya-URL" }
    public var settingsLayaKey: String { "Laya-avain" }
    public var settingsJevModel: String { "Jev-malli" }
    public var settingsJevURL: String { "Jev-URL" }
    public var settingsJevKey: String { "Jev-avain" }
    public var settingsClassifierCaption: String {
        "Laya on itse ylläpidetty luokittelija ja sitä kokeillaan ensin. Jos se puuttuu tai on alhaalla, mummo siirtyy Jeviin: automaattisesti OpenRouterin kautta, kun avain on asetettu (oletusmalli yllä), tai TypeSafen omaan APIin Jev-URL:n ja -avaimen kautta."
    }
    public var settingsTracingGroup: String { "Jäljitys (valinnainen, Langfuse)" }
    public var settingsHost: String { "Palvelin" }
    public var settingsPublicKey: String { "Julkinen avain" }
    public var settingsSecretKey: String { "Salainen avain" }
    public var settingsLanguageGroup: String { "Kieli" }
    public var settingsSpeaksLabel: String { "Mummo puhuu" }
    public var settingsLanguageCaption: String {
        "Sama lämmin mummo, millä kielellä tahansa. Astuu voimaan uudelleenkäynnistyksen jälkeen."
    }
    public var settingsAppearanceGroup: String { "Ulkoasu" }
    public var settingsThemeLabel: String { "Teema" }
    public var settingsThemeSystem: String { "Järjestelmä" }
    public var settingsThemeDark: String { "Tumma" }
    public var settingsThemeLight: String { "Vaalea" }
    public var settingsDayGroup: String { "Päivä" }
    public var settingsWakeHour: String { "Herätystunti" }
    public var settingsBedtime: String { "Nukkumaanmenoaika" }
    public var settingsSpeechToggle: String { "Mummo puhuu (say -v)" }
    public var settingsListsGroup: String { "Mummon vahtilistat" }
    public var settingsAppsLabel: String { "Työn aikana suljettavat sovellukset" }
    public var settingsAppsCaption: String {
        "Mummo sulkee nämä sovellukset, kun tehtäviä on kesken. Valitse sovellus lisätäksesi, roskakori poistaa."
    }
    public var settingsAppsAdd: String { "Valitse sovellus…" }
    public var settingsBlockedSitesLabel: String { "Estetyt sivustot" }
    public var settingsAllowedSitesLabel: String { "Sallitut sivustot" }
    public var settingsAllowedSitesCaption: String {
        "Mummo katsoo näitä kokonaan muualle - ne pysyvät auki, vaikka tehtäviä olisi kesken."
    }
    public var settingsSitePlaceholder: String { "esim. threads.com" }
    public var settingsAddSite: String { "Lisää" }
    public var settingsRemoveEntry: String { "Poista" }
    public var surfacesEditTitle: String { "SALLITUT OSOITTEET" }
    public var surfacesCaption: String {
        "Kun tämä tehtävä on kesken, mummo päästää nämä osoitekuviot läpi - estolistat väistyvät. Esim. threads.com/feed*"
    }
    public var surfacesPlaceholder: String { "esim. threads.com/feed*" }
    public var surfacesEditHelp: String { "Muokkaa sallittuja osoitteita" }
    public var dropTaskHelp: String { "Poista tämä tehtävä kirjasta" }
    public var settingsSave: String { "Tallenna" }
    public var keyCheckValid: String { "Avain toimii." }
    public var keyCheckInvalid: String { "Mummo ei voi käyttää tätä avainta." }
    public var keyCheckUnreachable: String { "Palveluun ei saatu yhteyttä." }
    public var secretShow: String { "Näytä" }
    public var secretHide: String { "Piilota" }

    public func updateAvailable(version: String) -> String {
        "Uudempi mummo on saatavilla: v\(version). Päivitä: brew upgrade --cask granny"
    }
    public var menuUpdateAvailable: String { "Päivitys saatavilla…" }
}
