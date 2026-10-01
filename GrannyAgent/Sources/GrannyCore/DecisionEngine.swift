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
        if let url = config.layaURL, !url.isEmpty,
           let key = config.layaKey, !key.isEmpty {
            self.laya = LayaClient(baseURL: url, apiKey: key, language: config.language, session: session)
        } else {
            self.laya = nil
        }
        // Jev is the fast-classifier fallback for users without a Laya
        // deployment: same System One wire, just another endpoint + key.
        if let url = config.jevURL, !url.isEmpty,
           let key = config.jevKey, !key.isEmpty {
            self.jev = LayaClient(
                baseURL: url, apiKey: key, language: config.language, source: "jev", session: session)
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
            // Allow verdicts are the common case and stay untraced; block and
            // warn are the interesting rules outcomes (e.g. a Facebook tab).
            if decision.action != .allow {
                trace.record(.init(
                    name: "decide",
                    traceName: "granny.decision",
                    input: [
                        "url": context.url,
                        "title": context.title ?? "",
                        "phase": phase.rawValue,
                        "tasks": tasks.filter { !$0.done }.map(\.title).joined(separator: "; "),
                    ],
                    output: ["action": decision.action.rawValue, "reason": decision.reason, "source": "rules"],
                    model: nil,
                    startedAt: Date(),
                    endedAt: Date()))
            }
            return decision
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

        let started = Date()
        let input = [
            "url": context.url,
            "title": context.title ?? "",
            "channel": context.channel ?? "",
            "kind": context.kind ?? "",
            "phase": phase.rawValue,
            "tasks": tasks.filter { !$0.done }.map(\.title).joined(separator: "; "),
        ]

        var decision: Decision?
        var modelName = "none"
        if let laya, let verdict = await laya.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = "laya/multilingual"
        } else if let jev, let verdict = await jev.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = "jev"
        } else if let jevViaOpenRouter,
                  let verdict = await jevViaOpenRouter.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = config.jevModel
        } else if let openRouter, let verdict = await openRouter.decide(context: context, tasks: tasks, phase: phase) {
            decision = enrich(verdict, context: context)
            modelName = config.model
        }

        let final = decision ?? Decision(
            .allow,
            reason: "ambiguous host but no model verdict; fail open",
            source: "failOpen")

        if decision != nil { cache[cacheKey] = final }

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

    /// Laya answers with a bare choice; fill in granny's line from templates
    /// so the interstitial never shows an empty message.
    private func enrich(_ decision: Decision, context: PageContext) -> Decision {
        guard decision.message == nil else { return decision }
        var enriched = decision
        switch decision.action {
        case .block:
            let host = URL(string: context.url)?.host ?? context.url
            enriched.message = GrannyLines.blocked(host: host)
        case .warn:
            enriched.message = GrannyLines.warnGeneric
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
