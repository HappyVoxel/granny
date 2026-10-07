import Foundation

/// The one place call sites read granny's voice from. The actual strings
/// live in `GrannyStrings` conformances (one per language); this façade
/// selects the language and forwards every member, so views never care
/// which language is active.
public enum GrannyLines {
    // Read from the engine's background tasks and written by Settings on the
    // main thread: the switch and the read both take the lock.
    private static let lock = NSLock()
    private static var _strings: any GrannyStrings = EnglishStrings()
    private static var currentLanguage: GrannyLanguage = .en

    public static var strings: any GrannyStrings {
        lock.lock()
        defer { lock.unlock() }
        return _strings
    }

    /// The active language code ("en", "vi", "fi"). Setting it re-selects
    /// the strings; unknown codes fall back to English.
    public static var language: String {
        get { currentLanguage.rawValue }
        set { configure(language: newValue) }
    }

    public static func configure(language: String) {
        let resolved = GrannyLanguage(code: language) ?? .en
        lock.lock()
        defer { lock.unlock() }
        currentLanguage = resolved
        _strings = resolved.strings
    }

    // Intake
    public static var greeting: String { strings.greeting }
    public static var greetHint: String { strings.greetHint }
    public static var saved: String { strings.saved }
    public static var challengeFallback: String { strings.challengeFallback }

    // Verdicts
    public static var warnGeneric: String { strings.warnGeneric }
    public static func negotiable(content: String) -> String {
        strings.negotiable(content: content)
    }
    public static var shorts: String { strings.shorts }
    public static func blocked(host: String) -> String { strings.blocked(host: host) }
    public static func offSurface(task: String) -> String { strings.offSurface(task: task) }
    public static func surfaceAllow(task: String) -> String { strings.surfaceAllow(task: task) }

    // Enforcement
    public static func killApp(name: String, task: String? = nil) -> String { strings.killApp(name: name, task: task) }
    public static func closedTab(url: String) -> String { strings.closedTab(url: url) }
    public static func browserControlDenied(browser: String) -> String {
        strings.browserControlDenied(browser: browser)
    }
    public static func browserNotScriptable(browser: String) -> String {
        strings.browserNotScriptable(browser: browser)
    }
    public static var helperMissing: String { strings.helperMissing }
    public static var helperInstalled: String { strings.helperInstalled }
    public static var helperInstallerMissing: String { strings.helperInstallerMissing }
    public static var extensionInstallTitle: String { strings.extensionInstallTitle }
    public static var extensionInstallSteps: String { strings.extensionInstallSteps }
    public static var extensionOpenSettings: String { strings.extensionOpenSettings }
    public static var extensionShowFolder: String { strings.extensionShowFolder }
    public static var extensionFolderMissing: String { strings.extensionFolderMissing }
    public static func decisionServerFailed(port: Int) -> String {
        strings.decisionServerFailed(port: port)
    }

    // Day cycle
    public static var sleepNag: String { strings.sleepNag }
    public static func reward(bedtime: Int) -> String { strings.reward(bedtime: bedtime) }
    public static func dayOffConfirm() -> String { strings.dayOffConfirm() }
    public static var dayOffDone: String { strings.dayOffDone }
    public static var dayOffCancelled: String { strings.dayOffCancelled }
    public static var backToWork: String { strings.backToWork }

    // Setup
    public static var setupHint: String { strings.setupHint }
    public static var setupKeyReminder: String { strings.setupKeyReminder }
    public static var openSettingsButton: String { strings.openSettingsButton }
    public static var helperHint: String { strings.helperHint }
    public static var installHelperButton: String { strings.installHelperButton }
    public static var appearanceHint: String { strings.appearanceHint }

    // Window titles
    public static var windowTitle: String { strings.windowTitle }
    public static var settingsTitle: String { strings.settingsTitle }
    public static var tasksTitle: String { strings.tasksTitle }
    public static var notebookLabel: String { strings.notebookLabel }
    public static var tasksNotebookLabel: String { strings.tasksNotebookLabel }

    // Task list
    public static var saveButton: String { strings.saveButton }
    public static var dayOffButton: String { strings.dayOffButton }
    public static var resumeWorkButton: String { strings.resumeWorkButton }
    public static var markAllDoneButton: String { strings.markAllDoneButton }
    public static var tasksEmpty: String { strings.tasksEmpty }
    public static var addTaskButton: String { strings.addTaskButton }
    public static var addTaskPlaceholder: String { strings.addTaskPlaceholder }
    public static var addTaskConfirm: String { strings.addTaskConfirm }
    public static var cancelButton: String { strings.cancelButton }
    public static var taskAdded: String { strings.taskAdded }
    public static func carryOver(tasks: [String]) -> String { strings.carryOver(tasks: tasks) }
    public static var carriedBadge: String { strings.carriedBadge }
    public static var streakHelp: String { strings.streakHelp }
    public static func streakUp(count: Int) -> String { strings.streakUp(count: count) }
    public static func streakLost(days: Int) -> String { strings.streakLost(days: days) }

    // Status line
    public static var statusAwaiting: String { strings.statusAwaiting }
    public static var statusWorking: String { strings.statusWorking }
    public static var statusRewarded: String { strings.statusRewarded }
    public static var statusDayOff: String { strings.statusDayOff }
    public static var statusNight: String { strings.statusNight }

    // Menu
    public static var menuTodayList: String { strings.menuTodayList }
    public static var menuDayOff: String { strings.menuDayOff }
    public static var menuBackToWork: String { strings.menuBackToWork }
    public static var menuTestURL: String { strings.menuTestURL }
    public static var menuSettings: String { strings.menuSettings }
    public static var menuInstallHelper: String { strings.menuInstallHelper }
    public static var menuInstallExtension: String { strings.menuInstallExtension }
    public static var menuOpenConfig: String { strings.menuOpenConfig }
    public static var menuQuit: String { strings.menuQuit }
    public static var statusPrefix: String { strings.statusPrefix }
    public static var dayOffTag: String { strings.dayOffTag }

    // Dialogs
    public static var savedTitle: String { strings.savedTitle }
    public static var relaunchBody: String { strings.relaunchBody }
    public static var relaunchNow: String { strings.relaunchNow }
    public static var relaunchLater: String { strings.relaunchLater }
    public static var configSaveFailed: String { strings.configSaveFailed }
    public static var testURLTitle: String { strings.testURLTitle }
    public static var testURLBody: String { strings.testURLBody }
    public static var judgeButton: String { strings.judgeButton }
    public static var challengeTitle: String { strings.challengeTitle }
    public static var answerButton: String { strings.answerButton }
    public static var grannyAsks: String { strings.grannyAsks }
    public static var agreeButton: String { strings.agreeButton }
    public static var backButton: String { strings.backButton }

    // Settings
    public static var settingsSubtitle: String { strings.settingsSubtitle }
    public static var settingsAIGroup: String { strings.settingsAIGroup }
    public static var settingsOpenRouterKey: String { strings.settingsOpenRouterKey }
    public static var settingsModel: String { strings.settingsModel }
    public static var settingsProvider: String { strings.settingsProvider }
    public static var settingsModelSearch: String { strings.settingsModelSearch }
    public static var settingsModelsUnavailable: String { strings.settingsModelsUnavailable }
    public static var settingsAICaption: String { strings.settingsAICaption }
    public static var settingsClassifierGroup: String { strings.settingsClassifierGroup }
    public static var settingsLayaURL: String { strings.settingsLayaURL }
    public static var settingsLayaKey: String { strings.settingsLayaKey }
    public static var settingsLayaGetKey: String { strings.settingsLayaGetKey }
    public static var settingsJevModel: String { strings.settingsJevModel }
    public static var settingsJevURL: String { strings.settingsJevURL }
    public static var settingsJevKey: String { strings.settingsJevKey }
    public static var settingsClassifierCaption: String { strings.settingsClassifierCaption }
    public static var settingsTracingGroup: String { strings.settingsTracingGroup }
    public static var settingsHost: String { strings.settingsHost }
    public static var settingsPublicKey: String { strings.settingsPublicKey }
    public static var settingsSecretKey: String { strings.settingsSecretKey }
    public static var settingsLanguageGroup: String { strings.settingsLanguageGroup }
    public static var settingsSpeaksLabel: String { strings.settingsSpeaksLabel }
    public static var settingsLanguageCaption: String { strings.settingsLanguageCaption }
    public static var settingsAppearanceGroup: String { strings.settingsAppearanceGroup }
    public static var settingsThemeLabel: String { strings.settingsThemeLabel }
    public static var settingsThemeSystem: String { strings.settingsThemeSystem }
    public static var settingsThemeDark: String { strings.settingsThemeDark }
    public static var settingsThemeLight: String { strings.settingsThemeLight }
    public static var settingsDayGroup: String { strings.settingsDayGroup }
    public static var settingsWakeHour: String { strings.settingsWakeHour }
    public static var settingsBedtime: String { strings.settingsBedtime }
    public static var settingsSpeechToggle: String { strings.settingsSpeechToggle }
    public static var settingsListsGroup: String { strings.settingsListsGroup }
    public static var settingsAppsLabel: String { strings.settingsAppsLabel }
    public static var settingsAppsCaption: String { strings.settingsAppsCaption }
    public static var settingsAppsAdd: String { strings.settingsAppsAdd }
    public static var settingsBlockedSitesLabel: String { strings.settingsBlockedSitesLabel }
    public static var settingsAllowedSitesLabel: String { strings.settingsAllowedSitesLabel }
    public static var settingsAllowedSitesCaption: String { strings.settingsAllowedSitesCaption }
    public static var settingsSitePlaceholder: String { strings.settingsSitePlaceholder }
    public static var settingsAddSite: String { strings.settingsAddSite }
    public static var settingsRemoveEntry: String { strings.settingsRemoveEntry }
    public static var surfacesEditTitle: String { strings.surfacesEditTitle }
    public static var surfacesCaption: String { strings.surfacesCaption }
    public static var surfacesPlaceholder: String { strings.surfacesPlaceholder }
    public static var taskEditEyebrow: String { strings.taskEditEyebrow }
    public static var taskEditTitleLabel: String { strings.taskEditTitleLabel }
    public static var taskEditPurposeLabel: String { strings.taskEditPurposeLabel }
    public static var taskEditCaption: String { strings.taskEditCaption }
    public static var taskEditHelp: String { strings.taskEditHelp }
    public static var taskEditAskGranny: String { strings.taskEditAskGranny }
    public static var taskEditAskGrannyHelp: String { strings.taskEditAskGrannyHelp }
    public static var dropTaskHelp: String { strings.dropTaskHelp }
    public static var settingsSave: String { strings.settingsSave }
    public static var keyCheckValid: String { strings.keyCheckValid }
    public static var keyCheckInvalid: String { strings.keyCheckInvalid }
    public static var keyCheckUnreachable: String { strings.keyCheckUnreachable }
    public static var secretShow: String { strings.secretShow }
    public static var secretHide: String { strings.secretHide }
    public static func updateAvailable(version: String) -> String { strings.updateAvailable(version: version) }
    public static var menuUpdateAvailable: String { strings.menuUpdateAvailable }
    public static func updateConfirm(version: String) -> String { strings.updateConfirm(version: version) }
    public static func updateStarted(version: String) -> String { strings.updateStarted(version: version) }
    public static var updateNowButton: String { strings.updateNowButton }
    public static var updateFailed: String { strings.updateFailed }

    /// The failure alert speaks the user's language: map the installer's
    /// error to its localized line.
    public static func updateFailure(_ error: Error) -> String {
        guard let error = error as? UpdateInstaller.UpdateError else {
            return error.localizedDescription
        }
        switch error {
        case .download(let status): return strings.updateFailedDownload(status: status)
        case .checksum: return strings.updateFailedChecksum
        case .unpack: return strings.updateFailedUnpack
        case .notWritable: return strings.updateFailedWritable
        case .brewFailed(let output): return strings.updateFailedBrew(output: output)
        case .tool: return strings.updateFailedGeneric
        }
    }
}
