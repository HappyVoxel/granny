# Install guide

granny is not on the App Store. Homebrew is the quick path; the source build
adds the Safari extension.

## Homebrew

```bash
brew tap happyvoxel/tap
brew install --cask --no-quarantine granny
```

`--no-quarantine` skips the Gatekeeper step (granny is ad-hoc signed, not
notarized). Already installed without it? Right-click the app -> Open once, or
`xattr -dr com.apple.quarantine /Applications/granny.app`.

## Direct download

Grab [granny-macos.dmg](https://github.com/HappyVoxel/granny/releases/latest/download/granny-macos.dmg),
drag granny into Applications, and right-click -> Open the first time.

## After install

1. **Launch granny** and install the root helper: menu -> *Install helper…*,
   one admin prompt. Without it, every block asks for a password.
2. **Browser extension**: menu -> *Install browser extension…*.
   - Chrome / Brave / Edge / Arc: `chrome://extensions` -> Developer mode ->
     **Load unpacked** -> `~/Applications/granny-extension`.
   - Safari: needs the source build (below); Safari cannot sideload.
3. **Settings**: paste your OpenRouter key, optionally a Laya/Jev classifier
   URL+key and Langfuse keys. The extension pairs itself - no token to paste.
4. **Say Allow** when macOS asks about notifications and controlling Safari.

### What no installer can do

| Step | Why |
|---|---|
| Admin password for the helper | `/etc/hosts` and sudoers need root; the app asks once |
| Extension toggle | Apple and Google require a human |
| Notification / Automation prompts | TCC consent is per-user |
| Notarization | needs an Apple Developer account |

## From source (Safari included)

```bash
git clone https://github.com/HappyVoxel/granny.git
cd granny
./scripts/install.sh              # build + app + helper + extensions
./scripts/install.sh --dry-run    # show what it would do
```

Requirements: macOS 14+ and full Xcode. Two consent toggles remain, because
Apple and Google require a human:

- **Safari**: Settings > Extensions > tick "granny"
- **Chrome-family**: `chrome://extensions` > Load unpacked > `dist/granny-chrome`

For Safari's janitor purge, also enable Settings > Advanced > "Show features
for web developers", then Develop > "Allow JavaScript from Apple Events".

## First day

1. granny greets you after 07:00. Write the list - one bullet per line - and
   press *Write it down*.
2. Work. Known entertainment dies at the network layer, everything else is
   judged by content, failing tabs and apps are closed.
3. Done before bedtime: blocks lift until 23:00, return at bedtime, reset at
   07:00. "Today is my day off" is one confirming question away.

## Updating

granny checks GitHub Releases once a day and offers *Update available…* in the
menu: brew copies run `brew upgrade --cask granny`, others download the zip,
verify its sha256 and swap themselves in place.

```bash
brew upgrade --cask granny   # manual route
```

Source builds: `git pull && ./scripts/install.sh`. Turn the check off with
`"checkForUpdates": false` in `~/.config/granny/config.json`.

## Troubleshooting

**A site still loads.** Two known bypasses:
- *Service workers*: a cached PWA shell can survive the network block. The
  extension purges caches on every block; without it, clear the site once in
  Safari > Settings > Privacy > Manage Website Data.
- *iCloud Private Relay*: a tunnel opened before the block keeps working.
  `killall networkserviceproxy` (no sudo), then relaunch the browser.

**No notifications.** System Settings > Notifications > granny > Allow.

**The janitor does not close tabs.** System Settings > Privacy & Security >
Automation: allow granny to control Safari.

**Everything asks for a password.** Helper not installed: menu -> *Install
helper…*, or `sudo scripts/install-helper.sh`.
