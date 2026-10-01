---
name: granny-swift
description: Review Swift/SwiftUI changes in granny for repo conventions, testability, and the decision-tier invariants. Use when reading, writing, or reviewing Swift code in this repository.
---

Review Swift and SwiftUI code for correctness, repo conventions, and the
invariants that have caused real bugs. Report only genuine problems - do not
nitpick or invent issues.

Review process:

1. **Core vs app split.** Logic belongs in `GrannyCore` (no AppKit, testable);
   the app target keeps views, window wiring and process calls. Flag logic in
   `granny-agent/` that should be a pure function in core.
2. **User-facing strings.** Every string comes from `GrannyLines` with both
   languages. Flag hardcoded copy in views or context code.
3. **Test seams.** Every system interaction goes through a `GRANNY_*`
   environment override (`GRANNY_HOSTS_FILE`, `GRANNY_SUDO`, `GRANNY_OSA_CMD`,
   `GRANNY_LAUNCHCTL`, `GRANNY_SKIP_DNS_FLUSH`, `GRANNY_CONFIG_FILE`,
   `GRANNY_STATE_DIR`, `GRANNY_ALLOW_NONROOT`, `GRANNY_PFCTL`...). A new
   `Process()` call without an override breaks the e2e suites - flag it.
4. **Decision-tier invariants.**
   - Rules are deterministic and fast; no network, no AI in `RulesEngine`.
   - The classifier tiers never close tabs: the janitor closes only on
     rules-level block verdicts. Flag any path where a classifier verdict
     reaches `closeTabAndPurge`.
   - `need-context` is never cached; verdicts are cached per URL.
   - Non-http(s) schemes are never judged.
   - YouTube tabs are never closed except Shorts.
5. **Hosts safety.** `/etc/hosts` is edited only between the GRANNY markers,
   only via `HostsFile`, written temp-file-plus-rename, mode 644.
6. **UI conventions.** Colors/typography from `GrannyTheme`; no hardcoded
   colors; dark old-money look; windows are cream-esque dark, serif type.
7. **Concurrency.** `DecisionEngine` is an actor; callers `await`. Flag
   blocking `Process` calls on the main thread.

Output format: one finding per line, `path:line: severity: problem. fix.`
Severity in {high, medium, low}. End with a short prioritized summary.
Skip files with no issues.
