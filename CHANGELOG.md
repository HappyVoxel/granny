# Changelog

All notable changes to this project are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-01

The first working cut: strict enough to use, honest about its limits.

### Added

- Morning intake notebook with bullets, LLM parsing, allowed URL surfaces and
  challenge questions for vague tasks
- Three-tier decision engine: rules, Laya (or Jev when Laya is not
  configured), DeepSeek fallback - content-aware, cached per URL
- `/etc/hosts` blocking with DoH and iCloud Private Relay ingress blocking,
  applied by a root helper with a NOPASSWD sudoers entry
- Browser extension (Safari + Chrome MV3): warn/block overlays, service
  worker and cache purge on block, tokenless pairing with the daemon, hard
  list fallback when the daemon is down
- Browser janitor: closes blocked tabs in Safari and the whole Chromium
  family (discovered automatically, no code change per browser), purges their
  offline caches first, never touches YouTube except Shorts; Firefox gets one
  notice pointing at the extension
- App killer: entertainment apps closed on launch and swept every 5 s
- Day cycle: reward when the list is done, re-block at bedtime, reset at
  wake, day off with a confirming question
- Carry-over: unfinished tasks return to the next morning's notebook, the
  greeting asks to eat that frog first, and carried tasks wear a frog mark
- Task surfaces are editable: the pencil on a task row opens an editor for
  its allowed URLs (the patterns the rules let through before the block
  lists), so a wrong machine-generated surface is fixed without re-adding
  the task
- Settings watchlists: manage the apps granny closes, the blocked sites and
  the allowed sites in Settings (apps picked with the native app chooser;
  site rows collapse the `www.` twin) - no hand-editing the config file
- Appearance setting (System / Dark / Light), and a Settings gear in the
  Today notebook so Settings is one click away
- Key fields in Settings: an eye to reveal a secret, and a live provider
  check after a paste - green tick for a working key, red cross for a
  rejected one (OpenRouter, Laya, Jev); Langfuse keys get the eye too
- Language setting: English, Tiếng Việt and Suomi, each with its own TTS
  voice and warm granny copy; non-English pins Laya's multilingual
  checkpoint
- Update nag: a daily GitHub Releases check that notifies with the one-line
  upgrade and adds an "Update available" menu item (`checkForUpdates` config)
- Langfuse tracing over OTLP v4 (`granny.decision` / `granny.action`)
- BYOK Settings window: OpenRouter, Laya/Jev, Langfuse, language, speech
- Release workflow: tag `v*` builds the archive, publishes the GitHub
  release, and updates the Homebrew tap
- Homebrew cask for community testing
- Hardening from a full code review: a corrupt config file is kept aside
  (`config.json.corrupt-*`) instead of being overwritten with defaults, an
  out-of-range `decidePort` falls back to the default instead of crashing,
  the tab janitor uses the real phase (not a hardcoded one), entertainment
  apps that refuse the graceful quit are forced down after 3 s, the helper
  aborts rather than renaming a hosts file it could not chmod, and the
  extension overlay speaks Finnish

### Changed

- User-facing copy is English by default. A fresh install follows the Mac's
  language when granny speaks it, English otherwise (previously Vietnamese
  by default); the extension UI follows the browser language the same way

### Fixed

- Relaunching from Settings now reopens the notebook instead of leaving
  granny windowless until the Dock icon is clicked
- Settings: pointing hand on every control (language, appearance, hours,
  watchlist headers); the whole watchlist header toggles now, and glass
  cards keep a stable hairline outline while scrolling

[0.1.0]: https://github.com/HappyVoxel/granny-agent/releases/tag/v0.1.0
