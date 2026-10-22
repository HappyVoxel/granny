# Architecture

Status: implemented (app, helper, both extension packages). The decisions
below are settled; change one with a note here plus its reason, not silently.
"Deferred" means designed, deliberately not built yet - see the list at the
end.

## Product

Granny Agent is a strict daily task enforcer for macOS. Granny asks for the
day's tasks, blocks entertainment while they are open, grills you when you
claim to be done, and unlocks distractions only after she is satisfied. She
keeps a log and comments on your day offs. The one other time the block
lifts is a pomodoro break the user earned by finishing a deep-work round:
while it runs granny advises instead of enforcing, and the block comes back
on its own when the break ends.

## Day cycle

1. First wake/login after 07:00 - the app window comes to the front (not
   closable until the task list is entered) plus a notification.
2. Intake: you type the list; granny parses it into tasks with
   `allowed_surfaces` and challenges vague entries.
3. Blocks on. Work.
4. Mark each task done; granny asks follow-up questions ("is this report
   specific?"). When all tasks are done she confirms.
5. Reward: blocks lift until bedtime (default 23:00). At bedtime the blocks
   return; after 23:00 granny also nags about sleep.
6. 07:00 next day resets to step 1. Unfinished tasks carry into the new
   day: the greeting names them and nudges to eat the frog first, and the
   intake writes them into the new notebook with a frog mark. A day that
   ends with no frogs banked grows the **streak** (shown from two clean
   days); a day off freezes it, a frog or a day granny never saw breaks it.

**Day off**: a button on the greeting screen and in the menubar. Granny asks
one confirming question, then no blocks and no tasks for the day; the day is
logged and commented on later. Day off beats the bedtime re-block. The flag
is not one-way: writing a task (intake or Add task) cancels it - a day off
has no tasks by definition - and while it is on the menubar item and the
notebook header both offer "Back to work".

## Components

- **GrannyAgent** (Swift, SwiftUI, Dock + menubar) - menubar + windows, task
  UI, wake detection (`NSWorkspace.didWakeNotification`), login item via
  `SMAppService`, local HTTP endpoint on `127.0.0.1` (token header) for the
  browser extension.
- **GrannyHelper** (small root CLI, installed once) - applies and clears the
  hosts block. The app runs it through `sudo -n`; the NOPASSWD sudoers entry
  is validated by `visudo` and covers exactly this binary's `apply`/`clear`.
  A socket daemon was designed and dropped: hosts survive reboots, and the
  sudoers route is auditable in one file. The app cannot undo blocks by
  itself.
- **Browser extension** (MV3, one codebase, packaged for Chrome and Safari) -
  intercepts navigation (`document_start` plus history hooks for SPA), asks
  the daemon for a verdict, and shows the interstitial on warn/block. It
  pairs itself through `GET /hello` (tokenless on loopback, hands over the
  token and port), so nobody pastes a token; the options page only overrides
  a non-default port. On `block` it also purges the origin's Cache Storage
  and unregisters its service workers, so PWA shells (Facebook, Instagram)
  cannot survive on offline cache.
- **Decision engine** (inside GrannyAgent) - see below. Laya and the
  OpenRouter model are pluggable tiers, off by default for OSS.
- **Pomodoro tomato** (in GrannyAgent) - the notebook's bottom-left corner.
  A click starts a 25-minute deep-work round; the breaks follow on their own
  (5 minutes, and 15 every fourth round). The fruit's colour is the stage,
  the countdown sits on the fruit, and the single number outside it counts
  today's instances of that stage - "the 3rd short break", "the 1st long
  break" - so no digit needs a legend. Durations and the cadence are config;
  the counters live in the day state, so midnight starts the tomato over.

## Interception and decisions

Every navigation goes through granny in phases; the verdict never comes from
the domain alone.

**Phase 1 - rules (local, microseconds).** Default-deny for entertainment
domains in work mode; a task's `allowed_surfaces` opens exactly those paths
(e.g. `facebook.com/adsmanager/*` for an ads task; the feed stays blocked);
YouTube shorts and the curated red-flag patterns are blocked (adult, games,
gambling, streaming); always-allowed prefixes (music.youtube.com) pass. Most
navigations end here.

**Phase 2 - context (content pages).** Hosts in `contextHosts` (YouTube) are
judged by content, not URL. At document start the page title does not exist
yet (or is the browser's placeholder, "YouTube"), so the engine answers
`need-context`; the extension shows "Ngoại đang xem cháu định làm gì…",
waits for the real title/channel/description (<= 2.5 s), then asks again. On
timeout it retries with `force=1` and whatever context exists. SPA
navigation that still carries the previous page's title is treated the same
way: the extension blanks it rather than letting the previous video's
verdict get cached for the new one. If the forced retry still has no
readable title, the engine answers `warn` - an unreadable page never
sails through in work mode, and the negotiable interstitial shows instead.
A verdict judged without a content signal is never cached.

**Phase 3 - fast classifier: Laya first, Jev as the fallback.** Laya is the
self-hosted deployment; Jev is TypeSafe's hosted service (reachable through
OpenRouter as `typesafe/jev-router`, or through TypeSafe's own API with a
URL/key). The engine tries Laya, and only when it is missing or down does it
fall to Jev, then to the model tier - so OSS users without a Laya deployment
still get fast classifier verdicts. Everything the rules did not resolve
goes here, unknown hosts included, so granny actually watches new sites
instead of waving them through. One `choice` question (allow/warn/block)
over the page context and the open tasks, gated on `answer_confidence`
(>= 0.6). Fast and cheap; it cannot write prose, so granny's line comes from
templates.

**Phase 4 - the model tier (OpenRouter).** Fallback when the classifier
is unavailable or not confident (structured JSON output). The model is
whatever the user picks in Settings from the provider's live catalogue
(`GET /api/v1/models`, fetched, never hardcoded); DeepSeek V4.1 Flash is
only the default, and a `provider` config field keeps the door open for
more providers. The model is the
core for what needs generation: granny's explanations, the challenge
questions at intake, and the future chat ("đôi co với ngoại"). A YouTube
watch page (`kind=video` on a context host, real title) takes this deep read
first, before the fast tiers: movies and vlogs are negotiable, so the
verdict has to read the title/channel, and the negotiation line has to name
the content, never the task list. Movies, series and vlogs answer `warn`;
shorts, gaming, streams, pranks and endless feeds stay `block`. A `warn`
interstitial offers two buttons - close the tab, or continue immediately.

Verdicts are cached per URL (`need-context` is never cached). On `block`,
the extension also purges the origin's Cache Storage and unregisters its
service workers, so a blocked site cannot reload itself from an offline
cache (Facebook and Instagram web apps register service workers - and macOS
TCC blocks even root from clearing Safari's stores from outside, which is
why the purge has to run inside the browser). If the daemon is unreachable
the extension fails closed on the hard list. Task model:
`Task { title, purpose, allowed_surfaces[], done }` - a task unlocks
surfaces, never whole domains.

**Tracing.** Classifier verdicts (Laya/DeepSeek), rules-level block and warn
verdicts, and enforcement actions (`tab-closed`, `app-killed`,
`block-applied`, `block-cleared`) land in Langfuse as `granny.decision` /
`granny.action` spans. Plain allow verdicts stay untraced - they are the
common case and would drown the signal.

## Reward, modes, and enforcement

- After confirm: blocks lift until bedtime; 23:00 re-blocks; 07:00 resets.
- Day off: no blocks all day.
- Hard-block ethos: friction and delay, not security. The machine owner can
  always bypass with sudo; the design makes it loud and annoying instead.
- Also enforced outside the browser: entertainment apps (config
  `entertainmentApps`; Instagram, TikTok, Facebook, Steam, Epic, Roblox by
  default) are closed on launch **and swept every 15 s while blocks are
  active**, so apps already running when work starts get closed too. Granny's
  line names the open task ("Đang làm dở «…» mà mở Facebook à?"). Browser
  tabs are the **browser janitor**'s job: every 5 s it reads the open tab
  URLs of every running browser it can drive - discovered through
  LaunchServices and an AppleScript-dictionary check, so Safari and any
  Chromium-family browser are covered without code changes, while Firefox
  (no AppleScript support) gets one notice pointing at the extension -
  closes the ones the rules call blocked, and - when the browser's "Allow
  JavaScript from Apple Events" is granted - runs the purge script inside
  the tab first, so the service worker and Cache Storage of that origin are
  gone before the tab closes.
  YouTube is exempt (research tool): the janitor never closes a YouTube tab
  except Shorts, and YouTube's content-level moderation (movie vs music vs
  study material) stays with the extension's overlays.
- The Chrome extension is loaded unpacked for now; force-install via managed
  preferences is deferred until release (see Deferred).

## Configuration and state

- `~/.config/granny/config.json` (mode 600, never in the repo): OpenRouter
  key, model slug, wake/bedtime hours, language, speech, optional Laya
  URL/key, optional Langfuse keys, the local API token and port, and the
  user's own timetable (`schedule`: time, label, tag per slot) and the palette
  those tags point at (`tags`: id, optional name, colour). A slot's `kind` is
  the legacy key older files wrote; it still decodes into `tag`. Missing
  fields fall back to defaults, so old config files never break.
- State (the day's tasks, day-off flag, greeted flag, the streak with its
  last chain day, today's pomodoro counter and the clock time of today's
  first finished round) lives at
  `~/Library/Application Support/granny/state.json` and rolls over at
  midnight. The rollover also appends one line to `state.json.log` beside it
  (date, first round, rounds, tasks done/open, day off): that append-only log
  is the only memory granny has across days, and the source of the weekly
  line.
- The HTTP decision endpoint binds 127.0.0.1 only and requires the token
  header; the extension's options page holds the same port and token.

## Phases

| Phase | Deliverable | Status |
|---|---|---|
| 0 | shell prototype: hosts block, dialog intake, LaunchAgent | done (`scripts/proto.sh`, kept as legacy) |
| 1a | Swift app: greeting window, OpenRouter brain, day off, reward scheduler, root helper | done |
| 1b | Extension: interception via daemon, rules + DeepSeek tiers, Chrome package | done |
| 1c | Safari package | done (`scripts/make-safari.sh` + converter patched bundle id) |
| 2 | hardening | partial - see deferred list |

## Deferred (designed, not built)

- **Chrome force-install via managed preferences.** Extension is loaded
  unpacked and kept on by the user; the fail-closed fallback (hard list) is
  the safety net. Add the managed-prefs writer to the helper when the
  extension is released.
- **pf / reboot-proof daemon.** Hosts survive reboots by themselves; DoH
  endpoints are blocked in the same hosts list, which kills the easy bypass.
  pf stays reserved for a real bypass problem.
- **MITM proxy.** Extension-only interception leaves non-browser HTTP apps
  unchecked; accept for now, revisit if an app becomes a problem.
- **Chat with granny.** Traces already flow to Langfuse; a chat window is a
  UI over the same client plus state context. The tracing layer is the
  foundation, so this is additive.
- **TTS is off by default.** `say -v Linh` is wired (config
  `speechEnabled`); Piper/cloud voices are a config value later, not a
  rewrite.

## Decision log

- **OpenRouter model**: `deepseek/deepseek-v4.1-flash` - slug verified
  against the live model list; supports structured outputs.
- **Jev**: `typesafe/jev-router` exists on OpenRouter but is a
  model/reasoning router, not the System One classifier wire format; latency
  unverified. Nothing builds on it.
- **Laya**: the primary page classifier when configured (fast decisions,
  calibrated confidence). Its value is speed and the privacy path (URLs stay
  on local infrastructure); it answers with a bare choice, so messages come
  from templates. DeepSeek remains the fallback and the generation core.
  The endpoint is whatever System One host the user pastes - base URL or
  the full `/systemone` the console key page hands out - with an optional
  model override; a keyless host (the free Zaitlabs deployment) works with
  an empty key. Hosts differ on the confidence field name
  (`answer_confidence` on the console, `confidence` on Zaitlabs) and on the
  scale, so the gate is configurable and defaults to 0.6.
- **Jev**: TypeSafe's hosted System One service, the classifier fallback for
  when Laya is missing or down. Reachable two ways: through OpenRouter
  (`typesafe/jev-router`, needs only the OpenRouter key) or through
  TypeSafe's own API (Jev URL + key). Laya is the self-hosted one; Jev is
  not self-hosted.
- **Langfuse v4 / OTLP**: organizations created on or after 2026-09-16 cannot
  use the legacy `/api/public/ingestion` or `/api/public/traces` APIs (410
  `LEGACY_API_UNAVAILABLE_FOR_NEW_ORGANIZATION`). TraceClient posts OTLP
  JSON to `/api/public/otel/v1/traces` with
  `x-langfuse-ingestion-version: 4`; reads for evaluation go through
   `GET /api/public/v2/observations?...&fields=core,basic,io,model,trace_context`
   (the `langfuse-cli` wraps this).
- **Day off is reversible**: writing a task cancels the day off and the
  menubar toggles back to work. Before this, the flag was one-way: a task
  remembered after the day-off ritual left the blocks off with open work.
- **Negotiable long-form video**: a movie, series or vlog is `warn` with a
  line naming the content (never the task list) plus two buttons (close the
  tab / continue immediately), not a block; shorts, gaming, streams,
  pranks and feeds hard-block. A YouTube watch page gets the model tier
  first, because the fast classifier cannot write that line and the verdict
  has to read the title/channel. A placeholder title ("YouTube") always asks
  for context instead of deciding.
- **Streak**: a day banks only when it ends with tasks all done, a round
  paid and no frog carried; day off freezes the chain, a day granny never saw
  breaks it, and
   the flame shows from two clean days on (Duolingo's first-day flame felt
   like noise next to the frog reminder). Counting happens at rollover, so
   the badge can include today the moment its tasks are done; notifications
   fire only for displayed streaks, growing or dying.
- **Pomodoro**: the timer is the technique's, the drawing is granny's. One
  counter (`finished` rounds) decides both the number beside the tomato and
  the break the round earns, so the two can never disagree. A finished round
  hands over to its break on its own (the pomofocus default) while the next
  deep-work round waits for a click - granny must not start a 25-minute round
  while nobody is at the desk. The countdown is a deadline in memory, not a
  persisted second: a relaunch starts the tomato over instead of resuming a
  stale round, and no disk write happens per tick. Pausing is the whole
  control set; a misclick costs one frozen round, not a lost day. The bell
  rings three times (one system sound vanishes under music or a meeting), the
  click that answers it silences it, and the banner behind it opens granny at
  the notebook - the tomato is what the click is for.
- **The reward is paid with a round**: ticked boxes buy nothing. `rewarded`
  needs every task done *and* one finished deep-work round that day, so a
  morning of clicking the list - or adding one spare task and ticking it -
  no longer opens the whole day. That was the gap: the reward cost nothing,
  so the first thing the day bought was the thing that ended it. One
  predicate (`DayState.rewarded`) decides the phase, the streak and the
  reward line, so the four ends cannot disagree; a running break still lifts
  the block through `blocksEnforced`, unaffected. `firstRoundAt` records when
  the first round landed, and the rollover writes the finished day to
  `state.json.log` as append-only JSON lines, deduped by date, unreadable
  lines skipped. The coach's line is three numbers - days logged, days with a
  first round, spread between the earliest and the latest start - and it
  stays silent below three logged days, because one bad morning is not a
  pattern. Deliberately not a timetable: no slots, no per-task start times,
  the phase clock stays the schedule and the log measures when you actually
  sat down.
- **Time blocking is advice, not enforcement**: the timetable is a template in
  the config, and a task carries at most one `slotID` - proposed at intake from
  the task's words (whole-word match, because "kỹ năng" contains "ăn"), stored
  so the hour cannot drift under the task, and movable in one click. The
  scheduler speaks the task of the current slot once per day, and only for a
  slot that has work pinned to it: eleven reminders a day is how a coach gets
  muted. A task finished outside its hour still counts - granny is strict, not
  petty - and she says so once per task (`nudgedOffSlot`). Blocks stay on the
  phase clock: a slot never touches `blocksEnforced`, because a second truth
  there would put the hosts, `/decide`, the janitor and the killer back in
  disagreement. Late is never punished retroactively; the day log carries it,
  and the weekly line is where the pattern shows.

- **Loopback is allowed unconditionally**: the rules tier answers
  `localhost` (and `*.localhost`), `127.0.0.0/8`, `::1` and `0.0.0.0` with
  an allow before any phase or allowlist check, so a dev server never
  reaches a model tier - one judged loopback a distraction and blocked it.
  The boundary stops at the LAN: private, link-local and `.local` addresses
  are still judged, because a NAS or Plex box there is a real time sink.
- **A running pomodoro break lifts the block**: enforcement follows the work
  interval the user chose, not the phase clock. One pure predicate,
  `blocksEnforced(phase:run:running:)` in `GrannyCore`, is the truth behind
  the hosts scheduler, the tab janitor, the app killer and `/decide` - which
  short-circuits to an allow (`source: "break"`) before any rule, cache or
  model tier, in the same four-key wire format, so the extension needs no
  change. Only a *running, earned* break lifts: `running` is the live
  in-memory flag, never persisted, so pausing, a relaunch mid-break and an
  expiry while granny was down all block; a break stage is unreachable
  without a finished round, and the night block never lifts. The block
  returns within one tick of the break's end, because the scheduler's apply
  path re-applies whenever the hosts are clear. A break clears the hosts, so
  `killall -x networkserviceproxy` runs once on the lifted -> enforced
  transition (seam `GRANNY_KILLALL`): a Private Relay tunnel opened during a
  break cannot outlive the block that follows it.
