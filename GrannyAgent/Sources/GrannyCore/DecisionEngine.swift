import Foundation

/// Orchestrates the tiers: rules, then (for ambiguous hosts and active
/// phases) Laya, then Jev (its own endpoint, or routed through OpenRouter),
/// then the OpenRouter model, then fail open. Verdicts from the model tiers
/// are cached per URL and cleared whenever the task list changes.
public actor DecisionEngine {
    public let config: GrannyConfig

    private let rules: RulesEngine
    private let openRouter: OpenRouterClient?
    private let jevViaOpenRouter: OpenRouterClient?
    private let laya: LayaClient?
    private let jev: LayaClient?
    private let trace: TraceClient
    private var cache: [String: Decision] = [:]

    public init(config: GrannyConfig, trace: TraceClient? = nil, session: URLSession = .shared) {
        self.config = config
        self.rules = RulesEngine(config: config)
        if let key = config.openRouterKey, !key.isEmpty {
            self.openRouter = OpenRouterClient(
                settings: .init(apiKey: key, model: config.model, language: config.language), session: session)
            // Jev is also hosted on OpenRouter: the fast classifier works
            // with nothing but an OpenRouter key.
            let jevModel = config.jevModel.trimmingCharacters(in: .whitespaces)
            self.jevViaOpenRouter = jevModel.isEmpty
                ? nil
                : OpenRouterClient(
                    settings: .init(apiKey: key, model: jevModel, language: config.language),
                    source: jevModel,
                    session: session)
        } else {
            self.openRouter = nil
            self.jevViaOpenRouter = nil
        }
        // Keyless hosts (the free Zaitlabs deployment) are fine with an
        // empty key; a URL is what enables the tier.
        if let url = config.layaURL, !url.isEmpty {
            self.laya = LayaClient(
                baseURL: url,
                apiKey: config.layaKey ?? "",
                language: config.language,
                model: config.layaModel,
                minConfidence: config.layaMinConfidence ?? LayaClient.confidenceGate,
                session: session)
        } else {
            self.laya = nil
        }
        // Jev is the fast-classifier fallback for users without a Laya
        // deployment: same System One wire, just another endpoint + key.
        if let url = config.jevURL, !url.isEmpty {
            self.jev = LayaClient(
                baseURL: url,
                apiKey: config.jevKey ?? "",
                language: config.language,
                source: "jev",
                session: session)
        } else {
            self.jev = nil
        }
        self.trace = trace ?? TraceClient(config: config.langfuse)
    }

    public func decide(url: String, title: String?, tasks: [TaskItem], phase: Phase) async -> Decision {
        await decide(context: PageContext(url: url, title: title), tasks: tasks, phase: phase)
    }

    /// The full workflow. Rules first; for ambiguous hosts the model tiers
    /// judge the page content. Content hosts without a title answer
    /// `need-context` so the extension can wait for the real title and ask
    /// again (with `force: true` as the timeout fallback).
    public func decide(context: PageContext, tasks: [TaskItem], phase: Phase, force: Bool = false) async -> Decision {
        // Only web pages are judged; Safari tabs like favorites:// or
        // about:blank must never reach the classifier.
        let scheme = URL(string: context.url)?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            return Decision(.allow, reason: "non-web scheme \(scheme ?? "none")", source: "rules")
        }

        if let decision = rules.evaluate(urlString: context.url, tasks: tasks, phase: phase) {
            // Focus audio passes whatever tier warned: a task's off-surface
            // URL must not nag while a study playlist plays.
            let final = Self.focusAudioRelief(decision, context: context)
            // Allow verdicts are the common case and stay untraced; block and
            // warn are the interesting rules outcomes (e.g. a Facebook tab).
            if final.action != .allow {
                trace.record(.init(
                    name: "decide",
                    traceName: "granny.decision",
                    input: [
                        "url": context.url,
                        "title": context.title ?? "",
                        "phase": phase.rawValue,
                        "tasks": tasks.filter { !$0.done }.map(\.title).joined(separator: "; "),
                    ],
                    output: ["action": final.action.rawValue, "reason": final.reason, "source": "rules"],
                    model: nil,
                    startedAt: Date(),
                    endedAt: Date()))
            }
            return final
        }

        let cacheKey = context.url.lowercased()
        if let cached = cache[cacheKey] { return cached }

        // Everything the rules did not resolve goes through the classifier
        // tiers - including unknown hosts, so granny actually watches new
        // sites instead of waving them through.
        if !force, !context.hasContentSignal, isContextHost(context.url) {
            return Decision(
                .needContext,
                reason: "content page without a title yet",
                source: "context")
        }

        // A context host that still has no readable title after the forced
        // retry must not sail through in work mode: answer warn so the
        // negotiable interstitial shows; the line names the content, never
        // the task list. Silence would be a bypass; only real content earns
        // a real verdict.
        if force, !context.hasContentSignal, isContextHost(context.url) {
            let unreadable = Decision(
                .warn,
                reason: "context host without a readable title",
                source: "context")
            return enrich(unreadable, context: context)
        }

        let started = Date()
        var input = [
            "url": context.url,
            "title": context.title ?? "",
            "channel": context.channel ?? "",
            "kind": context.kind ?? "",
            "phase": phase.rawValue,
            "tasks": tasks.filter { !$0.done }.map(\.title).joined(separator: "; "),
        ]

        var decision: Decision?
        var modelName = "none"
        var layaMiss: String?
        // Long-form video is the one case that gets the deep read: judging a
        // movie or vlog well - and negotiating instead of shutting it - needs
        // the title, channel and description. The fast classifier leads
        // everywhere else.
        if wantsDeepRead(context), let openRouter,
           let verdict = await openRouter.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = config.model
        }
        if decision == nil, let laya {
            let (verdict, miss) = await laya.decideDetailed(context: context, tasks: tasks, phase: phase)
            layaMiss = miss
            if let verdict {
                decision = enrich(verdict, context: context)
                modelName = config.layaModel ?? "laya/multilingual"
            }
        }
        if decision == nil, let jev, let verdict = await jev.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = "jev"
        }
        if decision == nil, let jevViaOpenRouter,
           let verdict = await jevViaOpenRouter.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = config.jevModel
        }
        if decision == nil, let openRouter,
           let verdict = await openRouter.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = config.model
        }

        var final = decision ?? Decision(
            .allow,
            reason: "ambiguous host but no model verdict; fail open",
            source: "failOpen")

        // A browsing surface on a context host (YouTube's front page, feeds,
        // channel pages) is where content gets chosen, not content itself:
        // at most a negotiable warn, never a dead end. The chosen video gets
        // its own verdict on navigation.
        if isContextHost(context.url), (context.kind ?? "").lowercased() == "youtube",
           final.action == .block {
            final = Decision(
                .warn,
                message: final.message,
                reason: "browsing surface: negotiable",
                source: final.source)
        }

        // Frequency, meditation and focus audio ("888 Hz abundance", rain,
        // lofi, study playlists) is music to work by, not entertainment: a
        // warn from any tier becomes an allow. A block stays a block - a
        // short or a game is not audio.
        final = Self.focusAudioRelief(final, context: context)

        // A verdict judged on a placeholder title ("YouTube") or none at all
        // must not be cached: it would stick the URL to that verdict for the
        // rest of the day, overlays included. The extension re-asks once the
        // real title lands.
        if decision != nil, context.hasContentSignal {
            cache[cacheKey] = final
        }

        // Why Laya was skipped, when it was: the pilot needs to see whether
        // the key, the endpoint or the confidence gate is the problem.
        if let layaMiss {
            input["layaMiss"] = layaMiss
        }

        trace.record(.init(
            name: "decide",
            traceName: "granny.decision",
            input: input,
            output: ["action": final.action.rawValue, "reason": final.reason],
            model: modelName,
            startedAt: started,
            endedAt: Date()))

        return final
    }

    private func isContextHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return config.contextHosts.contains { RulesEngine.hostMatches(host, $0) }
    }

    /// Long-form video is where a verdict must read the content, not just the
    /// URL: a movie or vlog is negotiable, and the model writes the line that
    /// explains why. Everything else takes the fast classifier.
    private func wantsDeepRead(_ context: PageContext) -> Bool {
        (context.kind ?? "").lowercased() == "video" && isContextHost(context.url)
    }

    /// A warn from any tier is relieved when the page is focus audio; block
    /// stays block.
    private static func focusAudioRelief(_ decision: Decision, context: PageContext) -> Decision {
        guard decision.action == .warn, isFocusAudio(context) else { return decision }
        return Decision(
            .allow,
            reason: "focus audio: compatible with work",
            source: decision.source)
    }

    /// Focus audio the grandchild works by: frequency/Hz tracks, meditation
    /// and sleep audio, rain and noise, lofi and study playlists. Titles like
    /// "You Will Become Super RICH ~ 888Hz" promise benefits but the form is
    /// audio, and listening is not a distraction.
    static func isFocusAudio(_ context: PageContext) -> Bool {
        let haystack = [context.title, context.channel]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return false }
        if haystack.range(of: #"\b\d{1,4}\s?hz\b"#, options: .regularExpression) != nil {
            return true
        }
        let tokens = [
            "frequency", "frequencies", "solfeggio", "binaural", "meditation",
            "meditative", "ambient", "lofi", "lo-fi", "white noise", "brown noise",
            "rain sounds", "nature sounds", "soundscape", "sound bath",
            "sleep music", "study music", "focus music", "music for studying",
            "music for work", "relaxing music", "healing music", "calm music",
        ]
        return tokens.contains { haystack.contains($0) }
    }

    /// Laya answers with a bare choice; fill in granny's line from templates
    /// so the interstitial never shows an empty message. A warn names the
    /// content, never the task list: it is the negotiation, not a shutdown.
    private func enrich(_ decision: Decision, context: PageContext) -> Decision {
        guard decision.message == nil else { return decision }
        var enriched = decision
        switch decision.action {
        case .block:
            let host = URL(string: context.url)?.host ?? context.url
            enriched.message = GrannyLines.blocked(host: host)
        case .warn:
            let title = (context.title ?? "").trimmingCharacters(in: .whitespaces)
            enriched.message = GrannyLines.negotiable(
                content: title.isEmpty ? (URL(string: context.url)?.host ?? context.url) : title)
        default:
            break
        }
        return enriched
    }

    public func parseIntake(text: String) async -> ParsedIntake? {
        guard let openRouter else { return nil }
        let started = Date()
        let intake = await openRouter.parseIntake(text: text)
        if let intake {
            trace.record(.init(
                name: "intake",
                traceName: "granny.intake",
                input: ["list": text],
                output: ["tasks": intake.tasks.map(\.title).joined(separator: "; "), "question": intake.question ?? ""],
                model: config.model,
                startedAt: started,
                endedAt: Date()))
        }
        return intake
    }

    public func clearCache() {
        cache.removeAll()
    }

    /// Waits for in-flight trace posts; short-lived processes call this
    /// before exiting.
    public func flushTraces(timeout: TimeInterval = 3) {
        trace.flush(timeout: timeout)
    }

    /// Traces an enforcement action (tab closed, app killed, block applied)
    /// as a `granny.action` span. Actions are low-frequency and high-signal,
    /// which is exactly what belongs in Langfuse.
    public func recordAction(_ name: String, input: [String: String], output: [String: String]) {
        trace.record(.init(
            name: name,
            traceName: "granny.action",
            input: input,
            output: output,
            model: nil,
            startedAt: Date(),
            endedAt: Date()))
    }
}
