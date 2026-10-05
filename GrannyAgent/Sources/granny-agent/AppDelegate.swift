import AppKit
import SwiftUI
import GrannyCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let context = GrannyContext()
    private let updater = UpdateInstaller()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Regular (not accessory): granny keeps a Dock icon, so hiding a
        // window never leaves her unreachable - click the icon to get the
        // greeting / task list back.
        NSApp.setActivationPolicy(.regular)
        Notifier.shared.start()
        buildMainMenu()
        context.scheduler.onGreetingNeeded = { [weak self] in
            self?.remindIntake()
        }
        context.scheduler.onStreakEvent = { [weak self] event in
            guard let self else { return }
            // The task list can be open across midnight; refresh the badge
            // before the notification lands.
            self.context.viewModel.refresh(from: self.context)
            switch event {
            case .kept(let count):
                postNotification(body: GrannyLines.streakUp(count: count))
            case .lost(let days):
                postNotification(body: GrannyLines.streakLost(days: days))
            }
        }
        context.start()
        setupStatusItem()
        observeWake()
        if context.needsSetupKey {
            postNotification(body: GrannyLines.setupKeyReminder)
        }
        // Settings' Relaunch marks the child so granny comes back with her
        // notebook on screen; a login-agent start stays quiet.
        if ProcessInfo.processInfo.environment[GrannyEnv.showWindow] == "1", window == nil {
            presentInitialWindow()
        }
    }

    /// Greeting while the day's list is still empty, the task list otherwise.
    private func presentInitialWindow() {
        let (state, phase) = context.snapshot()
        if phase == .awaitingTasks || state.tasks.isEmpty {
            presentGreeting(force: true)
        } else {
            presentTasks()
        }
    }

    /// An accessory app has no visible menu bar, but Edit key equivalents
    /// (Cmd+V and friends) only route through the main menu, so the greeting
    /// TextEditor needs one to accept paste.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Granny Agent", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Granny Agent", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    /// Opening an already-running accessory app again should always surface
    /// a window: the greeting while the day's list is still empty, the task
    /// list otherwise. Without this, a greeting missed at login is
    /// unreachable until the next day.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentInitialWindow()
        return true
    }

    /// The morning intake is a lock: while the day's list is unwritten
    /// granny may not be hidden, so Cmd+H is undone on the spot (the same
    /// notebook, not a fresh one - half-typed lines survive).
    func applicationDidHide(_ notification: Notification) {
        guard context.phase() == .awaitingTasks else { return }
        NSApp.unhide(nil)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "granny"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (state, phase) = context.snapshot()
        let streak = displayStreak(state: state)
        let title = "\(GrannyLines.statusPrefix): \(phase.rawValue)\(state.dayOff ? " \(GrannyLines.dayOffTag)" : "")\(streak >= 2 ? " · 🔥 \(streak)" : "")"
        let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        add(menu, "\(GrannyLines.tasksTitle)…", #selector(showTasks), "t")
        add(menu, GrannyLines.menuTodayList, #selector(showGreeting), "n")
        if state.dayOff {
            add(menu, GrannyLines.menuBackToWork, #selector(resumeWork), "d")
        } else {
            add(menu, GrannyLines.menuDayOff, #selector(takeDayOff), "d")
        }
        add(menu, GrannyLines.menuTestURL, #selector(testURL), "u")
        menu.addItem(.separator())
        add(menu, GrannyLines.menuSettings, #selector(showSettings), ",")
        add(menu, GrannyLines.menuInstallHelper, #selector(installHelper), "")
        add(menu, GrannyLines.menuInstallExtension, #selector(installExtension), "")
        add(menu, GrannyLines.menuOpenConfig, #selector(openConfig), "")
        if let update = context.availableUpdate {
            add(menu, "\(GrannyLines.menuUpdateAvailable) (v\(update.version))", #selector(installUpdate), "g")
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: GrannyLines.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func didWake() {
        context.scheduler.tick()
    }

    // MARK: - Actions

    @objc private func showTasks() { presentTasks() }
    @objc private func showGreeting() { presentGreeting(force: true) }
    @objc private func takeDayOff() { confirmDayOff() }
    @objc private func resumeWork() { context.clearDayOff() }

    @objc private func testURL() {
        let alert = NSAlert()
        alert.messageText = GrannyLines.testURLTitle
        alert.informativeText = GrannyLines.testURLBody
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://facebook.com"
        alert.accessoryView = field
        alert.addButton(withTitle: GrannyLines.judgeButton)
        alert.addButton(withTitle: GrannyLines.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let url = field.stringValue
        Task { [weak self] in
            guard let self else { return }
            let (state, phase) = self.context.snapshot()
            let decision = await self.context.engine.decide(url: url, title: nil, tasks: state.tasks, phase: phase)
            await MainActor.run {
                let result = NSAlert()
                result.messageText = "\(decision.action.rawValue) (\(decision.source))"
                result.informativeText = [decision.message, decision.reason]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
                result.runModal()
            }
        }
    }

    @objc private func installHelper() { context.installHelper() }

    /// Pilot onboarding for the extension: the dialog explains both consent
    /// paths, then opens the browser's extensions page or the packaged
    /// folder. Safari's final toggle is Apple's consent step, so it stays
    /// manual.
    @objc private func installExtension() {
        let alert = NSAlert()
        alert.messageText = GrannyLines.extensionInstallTitle
        alert.informativeText = GrannyLines.extensionInstallSteps
        alert.addButton(withTitle: GrannyLines.extensionOpenSettings)
        alert.addButton(withTitle: GrannyLines.extensionShowFolder)
        alert.addButton(withTitle: GrannyLines.cancelButton)
        switch alert.runModal() {
        case .alertFirstButtonReturn: openBrowserExtensionSettings()
        case .alertSecondButtonReturn: showExtensionFolder()
        default: break
        }
    }

    private func openBrowserExtensionSettings() {
        let browsers = [
            ("com.google.Chrome", "Google Chrome"),
            ("com.brave.Browser", "Brave Browser"),
            ("com.microsoft.edgemac", "Microsoft Edge"),
            ("company.thebrowser.Browser", "Arc"),
            ("org.chromium.Chromium", "Chromium"),
        ]
        for (bundleID, name) in browsers
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", name, "chrome://extensions"]
            try? process.run()
            return
        }
        // No Chromium-family browser installed: Safari's Extensions pane is
        // the only host, and macOS gives no deep link to it.
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            NSWorkspace.shared.openApplication(at: safari, configuration: .init(), completionHandler: nil)
        }
    }

    private func showExtensionFolder() {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("extension"),
              FileManager.default.fileExists(atPath: folder.path) else {
            showAlert(title: GrannyLines.extensionInstallTitle, body: GrannyLines.extensionFolderMissing)
            return
        }
        // `open -R` is the reliable reveal: NSWorkspace's file-viewer calls
        // did nothing on the pilot machines.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-R", folder.path]
        try? process.run()
    }

    @objc private func showSettings() {
        let view = SettingsView(
            config: context.config,
            onSave: { [weak self] updated in
                do {
                    try updated.save()
                    // The relaunch dialog must already speak the new language.
                    GrannyLines.language = updated.language
                    GrannyTheme.configure(appearance: updated.appearance)
                    self?.window?.close()
                    self?.offerRelaunch()
                } catch {
                    self?.showAlert(title: GrannyLines.configSaveFailed, body: error.localizedDescription)
                }
            },
            onCancel: { [weak self] in self?.window?.close() })
        show(view, title: GrannyLines.settingsTitle, styleMask: [.titled, .closable, .resizable, .miniaturizable])
        window?.setContentSize(NSSize(width: 520, height: 580))
        window?.minSize = NSSize(width: 480, height: 400)
        windowKind = .settings
    }

    private func offerRelaunch() {
        let alert = NSAlert()
        alert.messageText = GrannyLines.savedTitle
        alert.informativeText = GrannyLines.relaunchBody
        alert.addButton(withTitle: GrannyLines.relaunchNow)
        alert.addButton(withTitle: GrannyLines.relaunchLater)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    private func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "--env", "GRANNY_SHOW_WINDOW=1", bundleURL.path]
            try? process.run()
        }
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    @objc private func openConfig() { NSWorkspace.shared.open(GrannyPaths.configURL) }

    /// Installs the release behind the menu item: brew-managed copies are
    /// upgraded by brew, everything else swaps its bundle from the release
    /// zip. Either way granny comes back on the new version.
    @objc private func installUpdate() {
        guard let update = context.availableUpdate else { return }
        let confirm = NSAlert()
        confirm.messageText = GrannyLines.updateAvailable(version: update.version)
        confirm.informativeText = GrannyLines.updateConfirm(version: update.version)
        confirm.addButton(withTitle: GrannyLines.updateNowButton)
        confirm.addButton(withTitle: GrannyLines.cancelButton)
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        postNotification(body: GrannyLines.updateStarted(version: update.version))
        updater.install(version: update.version, currentBundle: Bundle.main.bundleURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.upgradedByBrew):
                self.relaunch()
            case .success(.willSwap):
                NSApp.terminate(nil)
            case .failure(let error):
                self.showAlert(title: GrannyLines.updateFailed, body: GrannyLines.updateFailure(error))
                NSWorkspace.shared.open(update.url)
            }
        }
    }

    // MARK: - Windows

    private enum WindowKind {
        case greeting
        case tasks
        case settings
    }

    /// What the current window holds. The intake lock needs it: a visible
    /// window is only proof of the notebook when it *is* the notebook.
    private var windowKind: WindowKind?

    /// How long the yellow button buys before the intake reminder returns.
    private static let intakeSnooze: TimeInterval = 5 * 60
    /// Set when the user minimizes the intake notebook; the reminder stays
    /// parked until it expires.
    private var intakeSnoozeUntil: Date?

    /// Keeps the intake notebook on screen while the day's list is still
    /// unwritten. The notebook itself is left alone - re-presenting every
    /// tick would wipe half-typed lines and steal focus - while a closed
    /// window, an empty Today list (the last task was dropped, or the day
    /// rolled over), comes back as the notebook. Settings counts as open:
    /// it was reached from the greeting, and the notebook returns when it
    /// closes. The yellow button parks the reminder for `intakeSnooze`.
    private func remindIntake() {
        guard let window else {
            presentGreeting(force: true)
            return
        }
        if window.isMiniaturized {
            let deadline = intakeSnoozeUntil ?? Date().addingTimeInterval(Self.intakeSnooze)
            intakeSnoozeUntil = deadline
            guard Date() >= deadline else { return }
            intakeSnoozeUntil = nil
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard window.isVisible else {
            intakeSnoozeUntil = nil
            presentGreeting(force: true)
            return
        }
        intakeSnoozeUntil = nil
        if windowKind != .greeting, windowKind != .settings {
            presentGreeting(force: true)
        }
    }

    private func presentGreeting(force: Bool = false) {
        guard force || !context.store.state.greeted else { return }
        context.markGreeted()
        let view = GreetingView(
            needsSetup: context.needsSetupKey,
            needsHelper: !context.helperInstalled,
            carried: context.store.state.carried.map(\.title),
            streak: displayStreak(state: context.store.state),
            onOpenSettings: { [weak self] in
                self?.window?.orderOut(nil)
                self?.showSettings()
            },
            onInstallHelper: { [weak self] in self?.context.installHelper() },
            onSave: { [weak self] text in
                self?.window?.close()
                self?.context.submitTasks(text) { [weak self] question in
                    self?.presentChallenge(question)
                }
            },
            onDayOff: { [weak self] in
                self?.window?.close()
                self?.confirmDayOff()
            })
        show(view, title: GrannyLines.windowTitle, styleMask: [.titled, .miniaturizable, .resizable])
        window?.setContentSize(NSSize(width: 530, height: context.needsSetupKey ? 540 : 480))
        window?.minSize = NSSize(width: 520, height: 420)
        windowKind = .greeting
        // AppKit makes the Stage Manager behaviors mutually exclusive, so
        // the green button's standard expand glyph (only full-screen-capable
        // windows get it) has a price: during the intake lock, when the
        // notebook *is* the point, it opts into full screen and may take the
        // stage. Outside the lock it keeps .canJoinAllApplications, like the
        // task list and settings, and never displaces the current app set.
        if context.phase() == .awaitingTasks {
            window?.level = .floating
            window?.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        } else {
            window?.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications]
        }
    }

    private func presentTasks() {
        context.viewModel.refresh(from: context)
        let view = TaskListView(
            viewModel: context.viewModel,
            onToggle: { [weak self] id in self?.context.toggle(taskID: id) },
            onMarkAllDone: { [weak self] in self?.context.markAllDone() },
            onAdd: { [weak self] text in self?.context.addTask(text) },
            onUpdateSurfaces: { [weak self] id, surfaces in
                self?.context.setSurfaces(taskID: id, surfaces: surfaces)
            },
            onRemove: { [weak self] id in self?.context.removeTask(taskID: id) },
            onResumeWork: { [weak self] in self?.context.clearDayOff() },
            onOpenSettings: { [weak self] in
                self?.window?.orderOut(nil)
                self?.showSettings()
            })
        show(view, title: GrannyLines.tasksTitle, styleMask: [.titled, .closable, .miniaturizable, .resizable])
        window?.setContentSize(NSSize(width: 530, height: 500))
        window?.minSize = NSSize(width: 520, height: 420)
        windowKind = .tasks
    }

    private func presentChallenge(_ question: String) {
        let alert = NSAlert()
        alert.messageText = GrannyLines.challengeTitle
        alert.informativeText = question
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: GrannyLines.answerButton)
        alert.addButton(withTitle: GrannyLines.cancelButton)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        context.answerChallenge(field.stringValue)
    }

    private func confirmDayOff() {
        let alert = NSAlert()
        alert.messageText = GrannyLines.grannyAsks
        alert.informativeText = GrannyLines.dayOffConfirm()
        alert.addButton(withTitle: GrannyLines.agreeButton)
        alert.addButton(withTitle: GrannyLines.backButton)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        context.setDayOff()
    }

    private func show<Content: View>(_ view: Content, title: String, styleMask: NSWindow.StyleMask) {
        window?.close()
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: styleMask.union(.fullSizeContentView),
            backing: .buffered,
            defer: false)
        newWindow.title = title
        newWindow.appearance = GrannyTheme.windowAppearance
        // Transparent so the glass backdrop (or the parchment below macOS 26)
        // shows through instead of an opaque slab. fullSizeContentView lets
        // that backdrop reach under the titlebar, so the top bar is tinted
        // like the rest of the window instead of showing the desktop raw.
        newWindow.isOpaque = false
        newWindow.backgroundColor = .clear
        // The system titlebar keeps its own scroll-edge material: settings'
        // scroll view passes under it, and a fully transparent bar would let
        // the text collide with the title.
        newWindow.titlebarAppearsTransparent = false
        newWindow.contentView = NSHostingView(rootView: view)
        newWindow.setContentSize(newWindow.contentView?.fittingSize ?? NSSize(width: 560, height: 420))
        newWindow.center()
        // A summoned window belongs to the space the user is on and stays
        // there: floating/all-spaces made granny ride along every Space and
        // stay above whatever app the user switched to. `.moveToActiveSpace`
        // brings her to the current Space when summoned from another one,
        // and `.canJoinAllApplications` keeps Stage Manager from replacing
        // the current app's window set - granny opens beside Terminal, not
        // in place of it. (Implying full-screen auxiliary, it is exclusive
        // with .fullScreenAuxiliary.)
        newWindow.level = .normal
        newWindow.collectionBehavior = [.moveToActiveSpace, .canJoinAllApplications]
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        newWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }
}
