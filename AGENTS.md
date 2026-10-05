# AGENTS.md

## What this is

Granny Agent: a strict macOS task enforcer - morning task intake, site
blocking while tasks are open, unlock as reward, day-off tracking, and a
browser extension that routes every navigation through granny. Read
`docs/ARCHITECTURE.md` before changing behaviour; it holds the settled
design, the phase status, and the decision log.

## Verification

Run before claiming any change works:

```
(cd GrannyAgent && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test)
bash tests/e2e-helper.sh      # helper binary against a sandbox hosts file
bash tests/e2e-agent.sh       # agent CLI + HTTP decision server
bash tests/e2e-extension.sh   # extension syntax, manifests, packaging
bash tests/e2e-safari.sh      # slow (~1 min): converter + unsigned xcodebuild
bash tests/e2e-safari-webdriver.sh  # real Safari via safaridriver (no Chrome)
bash tests/e2e.sh             # legacy Phase 0 shell prototype
```

`e2e-safari-webdriver.sh` drives the user's real Safari, so it reflects
Private Relay, service-worker caches, and DNS exactly as the user sees them.
It needs a one-time `safaridriver --enable` (admin password) or Safari >
Settings > Advanced > "Show features for web developers" > Develop > Allow
Remote Automation; when facebook "loads" it busts caches and reloads to tell
an offline-cache load from a real bypass.

Coverage: `cd GrannyAgent && swift test --enable-code-coverage`, then
`xcrun llvm-cov report` against
`.build/out/Products/Debug/GrannyCoreTests.xctest/Contents/MacOS/GrannyCoreTests`
with profile `.build/out/Products/Debug/codecov/default.profdata`. Keep
non-network logic in unit tests; the model tiers run through a stubbed
`URLProtocol`, never the live network. After a real `/etc/hosts` change,
flush the DNS cache or test results lie.

## Layout

```
GrannyAgent/                  Swift package
  Sources/GrannyCore/         rules, phases, hosts rendering, clients, traces
  Sources/granny-agent/       menubar app + CLI (--status/--decide/--serve)
  Sources/granny-helper/      root helper (apply/clear/render/strip/status)
  Tests/GrannyCoreTests/      unit tests, URLProtocol-stubbed network
extension/
  shared/                     one MV3 codebase: background, intercept, options
  chrome/ | safari/           manifests per browser
  safari/app/                 generated Xcode project (converter output)
scripts/                      install entrypoint, build/icon/app/helper/extension
                              installers, package-chrome, make-safari,
                              build-release, sync-env, proto.sh (legacy)
tests/                        e2e shell suites + legacy Phase 0 suite
docs/                         ARCHITECTURE.md (design), INSTALL.md (guide)
packaging/homebrew/Casks/     granny.rb for the HappyVoxel/homebrew-tap repo
.github/                      CI workflow, issue templates, logo
.agents/skills/               granny-swift review skill - the only real copy;
                              .claude/skills/granny-swift is a symlink to it
```

## Conventions

- Code, comments, docs, and commit messages: English. Conventional Commits.
- User-facing copy is English by default. A fresh install follows the
  machine's language (`Locale.preferredLanguages`) when granny speaks it,
  English otherwise; changing it is the language setting in Settings.
- All copy lives in `GrannyStrings` conformances (one struct per language,
  `GrannyCore/GrannyStrings.swift`); `GrannyLines` is the facade call sites
  use, `GrannyLanguage` maps the config's BCP-47 code (unknown codes fall
  back to English). Adding a language means adding a struct - the compiler
  lists every missing string. `GrannyVoice` resolves the per-language TTS
  voice; non-English languages pin Laya's multilingual checkpoint.
- Never commit secrets. The OpenRouter key and any Laya key live in
  `~/.config/granny/config.json` (mode 600) outside the repo. The Laya key in
  `~/.config/laya/env` must never be copied into this repo.
- Identifiers use `io.github.happyvoxel.granny` (HappyVoxel org, a happy lab;
  no personal branding anywhere).
- Test seams: every system interaction goes through a `GRANNY_*` env override
  (`GRANNY_CONFIG_FILE`, `GRANNY_STATE_DIR`, `GRANNY_HOSTS_FILE`,
  `GRANNY_ALLOW_NONROOT`, `GRANNY_SUDO`, `GRANNY_OSA_CMD`, `GRANNY_LAUNCHCTL`,
  `GRANNY_LAUNCH_AGENT`, `GRANNY_SKIP_DNS_FLUSH`, `GRANNY_TRACE_DEBUG`,
  `GRANNY_SHOW_WINDOW`, `GRANNY_OPEN`, `GRANNY_PKILL`, and the updater's tool
  paths `GRANNY_BREW`, `GRANNY_DITTO`, `GRANNY_SWAP_SHELL`). New system calls
  must get an override or the e2e suites cannot reach them.
- `/etc/hosts` is edited only between the `# GRANNY-BEGIN` / `# GRANNY-END`
  markers. The Swift renderer (`GrannyCore/HostsFile.swift`) is the single
  source of truth; `scripts/proto.sh` carries a legacy copy and must not grow
  new behaviour. Every domain is rendered twice, `127.0.0.1` and `::1` - an
  IPv4-only block is bypassed over IPv6 by any host with AAAA records (Meta's
  domains all carry them; TikTok's do not, which is why the webdriver suite
  caught it).
- The decision endpoint contract (`/decide`) is
  `url,title,channel,description,kind,force`; when adding a parameter, update
  `extension/shared/background.js`, `intercept.js`, and `DecisionServer`
  together - `tests/e2e-agent.sh` and `tests/e2e-extension.sh` check both
  ends. `GET /hello` is the tokenless loopback pairing endpoint the extension
  uses to fetch its token; keep it loopback-only.
- Hosts writes go through a temp file plus `rename`, chmod 644. Keep it
  that way - a truncating write can leave the machine DNS-dead.

## Gotchas

- The app target needs Xcode's toolchain: CommandLineTools alone cannot
  build SwiftUI macros. Prefix commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (scripts already
  do). `xcode-select` is untouched, so `xcodebuild` from PATH still fails.
- The Safari converter derives the host app bundle id from the app name;
  `scripts/make-safari.sh` patches the generated pbxproj afterwards so
  `ValidateEmbeddedBinary` passes. Do not hand-edit the generated project.
- LaunchAgents have no TTY: keep `granny-agent` free of interactive `sudo`
  prompts. It uses `sudo -n` against `/usr/local/libexec/granny/granny-helper`
  (installed by `scripts/install-helper.sh`, validated by `visudo`).
- iCloud Private Relay is the classic bypass: a tunnel established *before*
  the hosts block keeps working, because blocking the ingress only stops new
  tunnels. All six ingress hostnames are blocked by default; for a stale
  tunnel, `killall networkserviceproxy` (no sudo) and relaunch browsers, then
  verify with `lsof -nP -i -a -p $(pgrep -x networkserviceproxy)` showing no
  external connections. The reliable end state is Private Relay off in System
  Settings. (Troubleshooting: `docs/INSTALL.md`.)
- Safari's own stores (service workers, caches) cannot be cleared from
  outside Safari: TCC denies user *and root*. The purge must run inside the
  browser: the extension's `purgeOfflineData()`, the user's Manage Website
  Data pane, or the WebDriver suite. Do not burn time on root paths.
- The browser janitor (`Sources/granny-agent/BrowserJanitor.swift`) drives
  browsers through JXA (`/usr/bin/osascript -l JavaScript`). Browsers are
  discovered, not listed: LaunchServices names every app registered for
  http/https, and a shipped `*.sdef` means JXA can drive it - Safari plus the
  Chromium family, no code change per browser. Firefox has no AppleScript
  support and can never be swept; it gets one notice pointing at the
  extension. The first sweep of each browser triggers that browser's macOS
  Automation consent prompt; denied means the janitor goes quiet for that
  browser (one notification). The in-tab purge also needs "Allow JavaScript
  from Apple Events". Failures and the discovery list land in
  `<state dir>/janitor.log` (the login agent has no console). The app is
  ad-hoc signed, so every rebuild resets Automation grants and re-prompts.
- Releases are automated in `.github/workflows/release.yml`: every push to
  master runs the suites, then `scripts/next-version.sh` resolves the next
  version from Conventional Commits since the last tag (pre-1.0: patch per
  releasable merge, minor for breaking; docs/chore/ci merge releases
  nothing), builds `scripts/build-release.sh`'s zip and dmg (the dmg also
  ships under the stable name `granny-macos.dmg`, which the landing page's
  Download button links via `releases/latest/download`), publishes the GitHub
  release and updates the Homebrew tap when `TAP_GITHUB_TOKEN` is set. The
  cask lives in `packaging/homebrew/Casks/granny.rb` and is copied into
  `HappyVoxel/homebrew-tap` by that workflow. The workflow never pushes to
  master - the ruleset wants a pull request for that and GitHub Actions
  cannot be a bypass actor on a repository ruleset - so the version
  literals stay at the last released value; `tests/e2e-extension.sh` fails
  when the cask, the manifests and the two build scripts disagree.
- The app checks GitHub Releases once a day (`GrannyCore/UpdateChecker.swift`,
  `repository` constant - update it if the repo moves) and the menu's
  "Update available…" item installs it (`GrannyCore/UpdateInstaller.swift`,
  injectable session/command runner, `GRANNY_BREW`/`GRANNY_DITTO`/
  `GRANNY_SWAP_SHELL` overrides): brew-managed copies run `brew update &&
  brew upgrade --cask granny`, anything else
  downloads the release zip, verifies its published sha256, and queues a
  shell helper that waits for granny to quit, swaps the bundle and reopens
  it. `checkForUpdates` in the config turns the check off.
- Appearance is configured once at startup: `GrannyLines.configure(language:)`
  and `GrannyTheme.configure(appearance:)` are set in `GrannyContext.init`
  from the config; Settings saves and offers a relaunch. Views must read
  `GrannyTheme` colors, never literals.
- The Settings watchlists edit `entertainmentApps`, `blockedDomains` and
  `alwaysAllowedURLPrefixes` directly. A site row is a host:
  `GrannyCore/HostList.swift` hides the `www.` twin in display and re-expands
  on save (a bare host needs the twin because /etc/hosts has no wildcards).
  Removing a site from "blocked" is not "allowed": the classifier tiers can
  still block it - the allowed list is the real "look away" lever. Everything
  takes effect after relaunch, since the janitor, killer and engine capture
  the config at init.
- Task surfaces are editable from the task list (pencil icon ->
  `SurfaceEditorView`): `GrannyContext.setSurfaces` rewrites them through
  `TaskParser.normalizeSurface` (scheme dropped, moved domains canonicalised
  via `TaskParser.movedDomains`). Surfaces win over the block lists, so a
  task can legitimately open a blocked site; the janitor reads the same
  rules and leaves that tab alone.
- Chrome force-install via managed preferences is not built; the extension is
  loaded manually (unpacked). The fail-closed fallback in `background.js` is
  the safety net, not a substitute.
- Phase 0 hosts blocking covers whole domains plus DoH endpoints; YouTube
  Shorts specificity lives in the extension (rules tier).
