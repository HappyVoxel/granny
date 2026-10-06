# Install guide

granny is not on the App Store. Homebrew is the community-testing path; the
source build is the full path (it also gives you the Safari extension).

## Direct download (no Homebrew)

Download [granny-macos.dmg](https://github.com/HappyVoxel/granny/releases/latest/download/granny-macos.dmg)
from the latest release, then drag granny into Applications. Not notarized yet:
first open needs right-click -> Open, or System Settings > Privacy & Security
> Open Anyway.

## Homebrew (Chrome-family browsers, no Xcode)

```bash
brew tap happyvoxel/tap
brew install --cask --no-quarantine granny
```

`--no-quarantine` skips the Gatekeeper right-click step; granny is ad-hoc
signed, not notarized yet. Already installed without it? Right-click the app
-> Open once, or `xattr -dr com.apple.quarantine /Applications/granny.app`.

The tap is a small repository (`HappyVoxel/homebrew-tap`) that holds
`Casks/granny.rb`. The cask file lives in this repo under
`packaging/homebrew/Casks/granny.rb`; the Release workflow copies it there on
every tag (see `.github/workflows/release.yml`).

After install:

1. **Launch granny** (Dock or Spotlight).
2. **Install the root helper**: granny menu -> *Install helper…*, approve the
   admin prompt once. Runs through the macOS admin dialog - no Terminal.
   Without it, every block/unblock asks for a password.
3. **Load the browser extension**: granny menu -> *Install browser
   extension…* - the dialog explains both paths and copies the extension to
   `~/Applications/granny-extension` (it also ships inside the app at
   `granny.app/Contents/Resources/extension`).
   - Chrome / Brave / Edge / Arc / Chromium: `chrome://extensions` ->
     Developer mode -> **Load unpacked** -> `~/Applications/granny-extension`.
   - Safari: needs the source build below; Safari extensions cannot be
     sideloaded.
4. **BYOK**: granny menu -> *Settings…* -> paste your OpenRouter key (and
   optionally a Laya or Jev classifier URL+key, and Langfuse keys). The
   extension pairs itself with the daemon - there is no token to paste.
5. **Say Allow** when macOS asks for notifications and for controlling
   Safari (the tab janitor).

### What Homebrew cannot do (by macOS design)

| Step | Why |
|---|---|
| Admin password for the helper | `/etc/hosts` and the sudoers entry need root; the app asks once |
| Browser extension toggle | Apple and Google require a human to enable extensions |
| Notification / Automation prompts | TCC consent is per-user and cannot be pre-approved |
| Notarization | needs an Apple Developer account; until then, `--no-quarantine` or right-click Open |

## From source (full setup, Safari included)

```bash
git clone https://github.com/HappyVoxel/granny.git
cd granny
./scripts/install.sh              # build + app + helper + extensions
./scripts/install.sh --dry-run    # show what it would do
```

Requirements: macOS 14+ and full Xcode. The installer builds the app, copies
it to `~/Applications`, installs the login agent, installs the root helper
(one password prompt) and detects every supported browser.

Two consent toggles remain, because Apple and Google require a human and no
script may press them:

- **Safari**: Settings > Extensions > tick "granny"
- **Chrome-family**: `chrome://extensions` > Load unpacked > `dist/granny-chrome`

Recommended third (Safari): Settings > Advanced > "Show features for web
developers", then Develop > "Allow JavaScript from Apple Events" - this lets
the tab janitor purge a tab's service-worker cache before closing it.

## First day

1. granny greets you on the first wake after 07:00. Write the list - every
   line is a bullet - and press *Write it down*.
2. Work. granny blocks the known entertainment at the network layer, judges
   everything else by content, and closes the tabs and apps that fail.
3. When the list is done, blocks lift until bedtime (23:00). They return at
   bedtime, and the day resets at 07:00.
4. "Today is my day off" is one confirming question away. She writes it down.

## Updating

granny checks GitHub Releases once a day and tells you (notification + a menu
item) when a newer version exists. Choosing **Update available…** in the menu
installs it: brew installs run `brew update && brew upgrade --cask granny`,
other copies download the release zip, verify its sha256 and swap themselves
in place - granny quits and reopens on the new version.

```bash
brew upgrade --cask granny   # the manual route, if you prefer
```

Source builds: `git pull && ./scripts/install.sh`.

Turn the check off in `~/.config/granny/config.json` with
`"checkForUpdates": false`. Signed-appcast auto-update (Sparkle) is a possible
later addition.

## Troubleshooting

**A site still loads after blocking.** Two known bypasses:
- *Service workers*: Facebook and Instagram are PWAs; a cached shell can
  survive the network block. The extension purges caches and unregisters the
  service worker on every block. Without the extension, clear it once:
  Safari > Settings > Privacy > Manage Website Data > remove the site.
- *iCloud Private Relay*: a relay tunnel opened before the block keeps
  working. granny blocks all six relay ingress hostnames; restart the tunnel
  with `killall networkserviceproxy` (no sudo needed) and relaunch the
  browser.

**No notifications.** System Settings > Notifications > granny > Allow.
Also check Focus / Do Not Disturb.

**The janitor does not close tabs.** System Settings > Privacy & Security >
Automation: granny must be allowed to control Safari. The in-tab cache purge
additionally needs Safari's *Allow JavaScript from Apple Events*.

**Everything asks for a password.** The helper is not installed: granny menu
-> *Install helper…*, or `sudo scripts/install-helper.sh` from the repo.
