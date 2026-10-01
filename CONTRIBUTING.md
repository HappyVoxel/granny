# Contributing to granny

## Setup

Requirements: macOS 14+, full Xcode (the app target needs its SwiftUI macro
toolchain). Optional: [SwiftLint](https://github.com/realm/SwiftLint) for
style checks.

Fork the repo on GitHub, then:

```bash
git clone https://github.com/<your-fork>/granny.git && cd granny
scripts/build-app.sh        # builds dist/granny.app
(cd GrannyAgent && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test)
```

The app is a SwiftPM package under `GrannyAgent/`; the browser extension is
plain MV3 JavaScript under `extension/`; everything installable is a script
under `scripts/`.

Run the full verification before opening a PR:

```bash
(cd GrannyAgent && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test)
bash tests/e2e-helper.sh
bash tests/e2e-agent.sh
bash tests/e2e-extension.sh
```

`tests/e2e-safari.sh` and `tests/e2e-safari-webdriver.sh` are slower and need
extra setup (Xcode project build; `safaridriver --enable` once); CI runs the
fast suites, run the slow ones locally when your change touches Safari
packaging or the janitor.

## Code Style

The short version:

- Code, comments, docs and commits in English; user-facing strings come from
  a `GrannyStrings` conformance (one struct per language, selected through
  `GrannyLines`) - never hardcode copy in a view
- Logic lives in `GrannyCore` (testable, no AppKit); the app target keeps
  views, window wiring and process calls
- Every system interaction goes through a `GRANNY_*` environment override so
  the e2e suites can reach it
- No force unwraps in new code; explicit `private` where possible
- `/etc/hosts` is edited only between the `# GRANNY-BEGIN` / `# GRANNY-END`
  markers, only by `GrannyCore/HostsFile.swift`

## Commits

[Conventional Commits](https://www.conventionalcommits.org/), single line,
no body.

```
feat: add jev fallback for the classifier tier
fix: stop the bullet handler recreating a deleted bullet
docs: explain the safari janitor
```

## Branch Naming

Branch off `master`:

- `feat/brew-cask`
- `fix/janitor-youtube`
- `docs/install-guide`

## Pull Requests

One logical change per PR. Checklist:

- [ ] Tests added or updated (`swift test` for core logic, e2e for scripts)
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] Docs updated in `docs/` if behaviour changed
- [ ] User-facing strings added to every `GrannyStrings` conformance (the
      compiler lists what a new language still needs)
- [ ] No new system call without a `GRANNY_*` override

## Releases

Releases are automated. Push a tag and the `Release` workflow does the rest:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow runs the full test set first, then syncs the version literals
(scripts, manifests, cask) and commits them to `master`, builds
`dist/release/granny-<version>.zip` + its sha256, creates the GitHub release
with generated notes, and updates `HappyVoxel/homebrew-tap` - the tap step
needs a `TAP_GITHUB_TOKEN` secret (fine-grained, Contents: read and write on
the tap repo); without it the workflow publishes the release and prints a
warning, and the cask must be updated by hand.

The cask source of truth is `packaging/homebrew/Casks/granny.rb` in this
repo; the workflow copies it into the tap. Keep the version and sha256 fields
in sync with the release when updating manually.

## Adding a Language

Granny speaks through `GrannyStrings` (`GrannyCore/GrannyStrings.swift`): one
conformance per language, selected by `GrannyLanguage` from the config's
language code (BCP-47, region dropped; unknown codes fall back to English).

1. Add a case to `GrannyLanguage` with its `displayName` (the language's own
   name, e.g. "Suomi") and return the new struct from `strings`.
2. Add the struct: copy `EnglishStrings` and translate every member - the
   compiler lists what is missing.
3. Voice: add a preferred voice name to `GrannyVoice.preferredNames`
   (check `say -v '?'`); without one, granny takes any voice of that locale.
4. Model tiers: non-English languages pin Laya's multilingual checkpoint
   automatically; add a message-language variant to
   `OpenRouterClient.decisionSystemPrompt(language:)` if the model should
   write in the new tongue.
5. Tests: `GrannyLanguageTests` spot-checks each language speaks its own
   tongue; `GrannyVoiceTests` covers the voice fallback chain.

## Project Layout

```
GrannyAgent/           Swift package (SwiftPM)
  Sources/GrannyCore/    rules, phases, hosts rendering, clients, traces
  Sources/granny-agent/  menubar app, window UI, janitor, killer, server
  Sources/granny-helper/ root helper (apply/clear/render/strip/status)
  Tests/GrannyCoreTests/ unit tests, URLProtocol-stubbed network
extension/             one MV3 codebase: shared/, chrome/, safari/
scripts/               install, build, package, release, sync-env
tests/                 e2e shell suites
docs/                  architecture and install guide
packaging/homebrew/    the Homebrew cask shipped via the tap
```

## Adding a Decision Rule

Rules are the fast tier and must stay deterministic: they live in
`GrannyCore/Rules.swift` and are covered by `RulesTests`. If a case needs
judgement rather than a lookup, it belongs to the classifier tier, not to
the rules - and the janitor never closes a tab on a classifier verdict.

## Reporting Bugs

Open a [GitHub issue](https://github.com/HappyVoxel/granny/issues) with:

- macOS version
- granny version (menu -> Settings, or the release tag)
- What granny did and what you expected
- The relevant lines from `~/.config/granny/config.json` (redact keys)

## License

Contributions are licensed under the [GNU Affero General Public License v3.0 (AGPLv3)](LICENSE).
