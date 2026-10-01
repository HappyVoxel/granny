import AppKit
import Foundation
import GrannyCore

/// Watches the open tabs of every supported browser while blocks are active:
/// closes entertainment tabs and, when the browser allows it, purges the tab
/// origin's service workers and Cache Storage first - so a PWA shell
/// (Facebook, Instagram) cannot come back after the tab is gone.
///
/// Closes on **rules-level blocks only** (hard list, red-flag patterns,
/// Shorts). The classifier tiers deliberately do not close tabs: Laya's
/// false positives on work tools (Langfuse, YouTube, Perplexity) taught us
/// that closing is too destructive for a probabilistic verdict. Content
/// moderation beyond the rules stays with the extension's overlays.
///
/// Uses JavaScript for Automation through /usr/bin/osascript. The browsers
/// are discovered, not listed: LaunchServices names every app registered to
/// open http/https, and an app that ships an AppleScript dictionary (*.sdef)
/// is one JXA can drive - that covers Safari and the whole Chromium family
/// (Chrome, Brave, Edge, Vivaldi, ...) with no code change per browser. The
/// first sweep of each browser triggers macOS' Automation consent prompt
/// ("Granny Agent wants to control ..."); denying it only disables the
/// janitor for that browser, nothing else. A browser without a dictionary
/// (Firefox) cannot be driven at all - granny says so once and points at the
/// extension. The in-tab cache purge additionally needs "Allow JavaScript
/// from Apple Events" (Safari: Develop menu; Chrome: View > Developer);
/// without it the janitor still closes tabs but cannot purge their origins.
final class BrowserJanitor {
    private struct Browser {
        let name: String
        let bundleID: String
        var chromium: Bool { bundleID != "com.apple.Safari" }
    }

    private let config: GrannyConfig
    private let tasksProvider: () -> [TaskItem]
    private let phaseProvider: () -> Phase
    var onSweep: (([String]) -> Void)?
    var onError: ((String) -> Void)?

    /// Tab sweep cadence.
    private static let sweepInterval: TimeInterval = 5
    /// A shipped AppleScript dictionary marks a browser JXA can drive.
    private static let scriptableBundleExtension = ".sdef"
    /// osascript's "not authorized to send Apple events" exit code.
    private static let notAuthorizedError = "-1743"
    /// Grace period for the in-tab purge before the close.
    private static let purgeDelaySeconds: Double = 1.2

    private var timer: Timer?
    private var warnedBrowsers: Set<String> = []
    private var notifiedUnscriptable: Set<String> = []
    private var failedBrowsers: Set<String> = []
    private var lastDiscovery = ""
    private var lastStderr = ""
    private var sweeping = false

    init(
        config: GrannyConfig,
        tasksProvider: @escaping () -> [TaskItem],
        phaseProvider: @escaping () -> Phase
    ) {
        self.config = config
        self.tasksProvider = tasksProvider
        self.phaseProvider = phaseProvider
    }

    func start() {
        sweep()
        let timer = Timer(timeInterval: Self.sweepInterval, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Closes every open tab the rules call blocked, in every running browser.
    /// Runs off the main thread; a sweep never overlaps itself.
    func sweep() {
        let phase = phaseProvider()
        // Read the task list here, on the main thread, before handing the
        // work to a background task.
        let tasks = tasksProvider()
        guard phase.blocksActive, !sweeping else { return }
        sweeping = true
        Task { [weak self] in
            guard let self else { return }
            var closed: [String] = []
            let browsers = self.discoverBrowsers()
            let discovered = browsers.map { "\($0.name)[\($0.bundleID)]" }.joined(separator: ", ")
            if discovered != self.lastDiscovery {
                self.lastDiscovery = discovered
                self.log("discovered: \(discovered.isEmpty ? "(none)" : discovered)")
            }
            for browser in browsers {
                closed.append(contentsOf: self.sweepBrowser(browser, phase: phase, tasks: tasks))
            }
            self.sweeping = false
            if !closed.isEmpty {
                self.onSweep?(closed)
            }
        }
    }

    private func sweepBrowser(_ browser: Browser, phase: Phase, tasks: [TaskItem]) -> [String] {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty
        else { return [] }
        let rules = RulesEngine(config: config)
        var closed: [String] = []
        for tab in openTabs(browser) {
            // Web pages only: favorites://, about:blank and friends are
            // browser furniture, not content.
            let scheme = URL(string: tab.url)?.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { continue }

            // YouTube is a research tool: tabs stay (except Shorts).
            if janitorNeverCloses(urlString: tab.url) { continue }

            if let decision = rules.evaluate(urlString: tab.url, tasks: tasks, phase: phase),
               decision.action == .block,
               closeTabAndPurge(browser, url: tab.url) {
                closed.append(tab.url)
            }
        }
        return closed
    }

    // MARK: - Discovery

    /// Every app LaunchServices can open a web page with, deduped by bundle
    /// id (the same browser can appear twice, e.g. installed plus a mounted
    /// disk image). A shipped *.sdef means JXA can drive it; anything else
    /// (Firefox) cannot be driven and gets one notice per run.
    private func discoverBrowsers() -> [Browser] {
        let probe = URL(string: "https://example.com")!
        var seen = Set<String>()
        var browsers: [Browser] = []
        for appURL in NSWorkspace.shared.urlsForApplications(toOpen: probe) {
            guard let bundle = Bundle(url: appURL),
                  let id = bundle.bundleIdentifier,
                  seen.insert(id).inserted else { continue }
            let name = appURL.deletingPathExtension().lastPathComponent
            if isScriptable(bundle) {
                browsers.append(Browser(name: name, bundleID: id))
            } else if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
                      notifiedUnscriptable.insert(id).inserted {
                onError?(GrannyLines.browserNotScriptable(browser: name))
            }
        }
        return browsers
    }

    private func isScriptable(_ bundle: Bundle) -> Bool {
        guard let resources = bundle.resourceURL?.path else { return false }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []
        return entries.contains { $0.hasSuffix(Self.scriptableBundleExtension) }
    }

    // MARK: - AppleScript (JavaScript for Automation)

    private func openTabs(_ browser: Browser) -> [(url: String, title: String)] {
        let script = """
        function run(argv) {
          var B = Application(argv[0]);
          if (!B.running()) return '[]';
          var tabs = [];
          B.windows().forEach(function (w) {
            w.tabs().forEach(function (t) {
              try {
                var u = t.url();
                if (u) tabs.push({ url: u, title: t.name() || '' });
              } catch (e) {}
            });
          });
          return JSON.stringify(tabs);
        }
        """
        guard let output = runOsascript(script, arguments: [browser.name], browserName: browser.name),
              let data = output.data(using: .utf8),
              let raw = JSON.decode([[String: String]].self, from: data) else {
            // Log the first failure per browser, not one line every 5 s.
            if failedBrowsers.insert(browser.bundleID).inserted {
                log("openTabs \(browser.name): failed\(lastStderr.isEmpty ? "" : " - \(lastStderr)")")
            }
            return []
        }
        failedBrowsers.remove(browser.bundleID)
        return raw.compactMap { entry in
            guard let url = entry["url"] else { return nil }
            return (url: url, title: entry["title"] ?? "")
        }
    }

    private func closeTabAndPurge(_ browser: Browser, url: String) -> Bool {
        // The purge runs inside the page (only it can touch its origin's
        // service workers and caches); the close waits a moment for it.
        // Tabs are matched per window and closed back to front, so the
        // index-based references stay valid while the loop closes them.
        let purge = "(function(){try{navigator.serviceWorker.getRegistrations().then(function(rs){rs.forEach(function(r){r.unregister()})})}catch(e){}try{caches.keys().then(function(ks){ks.forEach(function(k){caches.delete(k)})})}catch(e){}return 'purged'})()"
        let script = """
        function run(argv) {
          var B = Application(argv[0]);
          if (!B.running()) return '[]';
          var target = argv[1];
          var purge = argv[2];
          var chromium = argv[3] === '1';
          var closed = [];
          B.windows().forEach(function (w) {
            var tabs = w.tabs();
            for (var i = tabs.length - 1; i >= 0; i--) {
              var t = tabs[i];
              var u = null;
              try { u = t.url(); } catch (e) {}
              if (u !== target) continue;
              try {
                if (chromium) t.execute({ javascript: purge });
                else t.doJavaScript(purge);
                delay(\(Self.purgeDelaySeconds));
              } catch (e) {}
              try {
                t.close();
                closed.push(u);
              } catch (e) {}
            }
          });
          return JSON.stringify(closed);
        }
        """
        let arguments = [browser.name, url, purge, browser.chromium ? "1" : "0"]
        guard let output = runOsascript(script, arguments: arguments, browserName: browser.name) else {
            log("close \(browser.name) \(url): failed\(lastStderr.isEmpty ? "" : " - \(lastStderr)")")
            return false
        }
        let ok = output.contains(url)
        log("close \(browser.name) \(url): \(ok ? "closed" : "not found")")
        return ok
    }

    private func runOsascript(
        _ script: String,
        arguments: [String] = [],
        browserName: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script] + arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain both pipes before waiting: a full pipe would block osascript
        // forever and the janitor with it.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: outData, encoding: .utf8)
        if process.terminationStatus != 0 {
            let message = String(data: errData, encoding: .utf8) ?? ""
            lastStderr = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !warnedBrowsers.contains(browserName),
               message.contains(Self.notAuthorizedError) || message.lowercased().contains("not allowed") {
                warnedBrowsers.insert(browserName)
                onError?(GrannyLines.browserControlDenied(browser: browserName))
            }
            return nil
        }
        return output
    }

    /// Append-only trail in the state directory: this runs inside a login
    /// agent with no console, so failures have to land somewhere.
    private func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(message)\n"
        let url = GrannyPaths.stateDir.appendingPathComponent("janitor.log")
        try? FileManager.default.createDirectory(at: GrannyPaths.stateDir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
