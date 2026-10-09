# Parallel workspace

One of the remote channels between the phone App and Pi (tile name = this directory's
name). The global instructions (`~/AGENTS.md`) still apply; this file only adds context
specific to this workspace.

- The reader is on a phone screen: keep replies short, avoid big log/diff dumps; when
  content is long, write it to a file first and hand over the path.
- This directory serves this work unit only — put artifacts here, don't scatter them
  into `$HOME`.
- The coordinator is `~/remote` (agent name `Jarvis`): go there when cross-workspace
  coordination is needed.

## Repository and branches (fork rules)

| remote | repository | permission |
|---|---|---|
| `origin` | `fenlyin0420/remote_pi` (your own fork) | **the only push target** (`remote.pushDefault=origin` is set, so even a bare `git push` only lands here) |
| `upstream` | `jacobaraujo7/remote_pi` (original author) | read-only: **never push, never open a PR** |

| branch | purpose |
|---|---|
| `main` | pure mirror of upstream, **never write custom code here** (customization files such as this one are not on `main`) |
| `dev` | the long-lived trunk for all custom work — merge and release here day to day |
| `feat/...` `fix/...` | branch off `dev`, merge back into `dev` when done, then delete the branch |

Syncing upstream: `git fetch upstream` → first inspect `git log dev..upstream/main` /
`git diff dev upstream/main` → only if it looks good, run
`git switch dev && git merge upstream/main` (**never customize on `main`**).
`gh` is already `repo set-default`-ed to the fork (`gh` otherwise picks whichever remote
is named `upstream`, which would hit the original author's repository).

## Delivery (fixed process)

> All the details and the pitfalls live in
> `.agents/memory/remote-pi-in-app-update.md` (release steps / version numbering rules /
> signing / ZIP and JDK pitfalls) and `remote-pi-beta-channel.md` (the two channels).
> **Read them before releasing.**

**Two channels, two rhythms**: changes ship first as a **beta** (`-beta.N` version +
`beta` flavor, installable and coexisting with the production build), pushed to the beta
channel only. After the user has tested and confirmed it, build the **production**
release (clean version number + `prod` flavor) and push it to the production channel +
GitHub Release. **Do not skip the beta and go straight to production** (this was skipped
for 1.5.11 on 2026-09-27 and the user explicitly asked for it to be corrected).

1. Branch `feat/...`/`fix/...` off `dev`, get all tests + analyze/typecheck green, then
   merge back into `dev`.
2. Build the APK. Environment:
   `export PATH=$HOME/flutter/flutter/bin:$HOME/apps/jdk/21.0.12.1/bin:$PATH`,
   `JAVA_HOME=$HOME/apps/jdk/21.0.12.1`, `ANDROID_HOME=$HOME/Android/Sdk`
   (the ones under the system `/usr/lib/jvm` are JREs — no `javac`). Run it under
   `app/` (**`--flavor` is mandatory**; without it both flavors get built and the beta
   build picks up the version from pubspec):
   ```bash
   # Beta (push to the beta channel only, no GitHub release)
   REMOTE_PI_HOSTS=1.15.13.177 flutter build apk --release --flavor beta \
     --target-platform android-arm64 --build-name=1.5.12-beta.1 --build-number=32 \
     --dart-define=UPDATE_MANIFEST_URL=http://1.15.13.177:3210/downloads/app-beta/latest.json
   # Production
   REMOTE_PI_HOSTS=1.15.13.177 flutter build apk --release --flavor prod \
     --target-platform android-arm64 \
     --dart-define=UPDATE_MANIFEST_URL=http://1.15.13.177:3210/downloads/app/latest.json
   ```
   Artifacts: `build/app/outputs/flutter-apk/app-{beta,prod}-release.apk`.
   If either input is missing, the App installed on the phone has **no update channel**
   (the card always says "up to date") and no plaintext exception.
3. **Push to the download site** (this is the only thing the phone's update prompt looks
   at; for each channel the `version` in its `latest.json` must equal that APK's
   versionName and be greater than the installed version): scp the APK + manifest to
   cloud177, then `sudo install` into
   `/var/lib/remote-pi-downloads/{app,app-beta}/{RemotePi.apk,RemotePiBeta.apk,latest.json}`.
4. **All three checks are mandatory**: ①`strings lib/arm64-v8a/libapp.so` on the APK
   finds that channel's manifest URL; ②`aapt dump badging` shows the right
   versionName/applicationId (beta = `…remotepi.beta`); ③`curl -o /tmp/s.apk
   .../<channel>/<apk>` downloads with a sha256 matching the local file.
5. Once testing confirms it, cut the production release: push to `origin` (your own
   fork), create the Release (`--target <branch>`), write the title/body in English,
   name the APK `remote-pi-<version>-arm64-signed.apk`; afterwards self-check with
   `gh release view --json` + re-download and compare sha256. **Never push to
   `upstream` (the original author), never open a PR.**
6. Pi-side (pi-remote) changes: the local Pi loads the repo path package
   (`~/.pi/agent/settings.json` packages → `/home/fenlyin/Documents/GitHub/pi-remote/pi-remote`),
   so the user side is just `cd pi-remote && npm run build` (keeps the local patches in
   source) + restarting the supervisor. For other users: `npm pack` and attach
   `remote-pi-<version>.tgz` to the same Release.
   **Restarting supervisor kills every turn currently running in every room (including
   this session) — only remind the user to do it themselves; locally it is a system
   unit and sudo needs a password, so you can use `kill -TERM <supervisord pid>` and let
   systemd (`Restart=always`) bring it back up, but always send your reply first. See
   `remote-pi-remote-load-path`.**

## Current state

- **1.5.25 is released** (2026-10-09, on `dev`, prod `1.5.25` +74, sha
  `e0e510f3…`, Release `v1.5.25-ephemeral-rooms-arm64`): long-press a room
  tile → **Fork room** (same cwd, fresh temporary session, agent name `#N`
  auto-incremented over the rooms of that cwd), and phone-side room
  create/delete **never touch the daemon registry** anymore
  (`~/.pi/remote/daemons.json` is manual/terminal-only): create → supervisor
  `spawn` (ephemeral `pi --mode rpc` child — fresh session, never registered,
  no auto-restart on crash, dies with the supervisor); delete → `kill` the
  ephemeral by (cwd,name) → else **cycle** a registered daemon (`restart`, so
  the supervisor brings it straight back — a daemon is always-on) → else
  no-op. Betas `1.5.25-beta.1`(+71) → `beta.2`(+72) → `beta.3`(+73) were
  tested first; the two real bugs found on the way:
  **(a)** the relay routes a frame by the ROOM in its envelope and each room
  is served by exactly one Pi session, so create/delete now ride the acted-on
  tile's own room (`HomeViewModel.rideRoomFor`; the old `firstLiveRoom`
  handed the request to whichever session owned that room — including a
  terminal Pi still running the previous build, whose old register path
  answered 'Daemon already registered for cwd: …');
  **(b)** an ephemeral child got its `#N` name stripped by the config parser
  (`migrateAgentName` — a `#N` is a runtime lock artefact, never a config
  value), so it asked for the daemon's name and waited on the cwd lock
  forever: phone rooms now carry `REMOTE_PI_EPHEMERAL=1` and the lock
  auto-suffixes (`fenlyin` → `fenlyin#2`), and the supervisor passes the BASE
  name.
  Pi-side: new control ops `spawn`/`kill` (+ `kill` matches (cwd,name)) and
  optional `name` on `room_create`/`room_delete`; pi-remote **0.14.0** —
  **requires a supervisor restart to take effect** (never kill it yourself
  mid-session; a restart only refreshes supervisor-spawned daemons — an
  interactive TUI session keeps the extension it loaded until that terminal
  is restarted). Pi tests 939 pass, app 870 pass (`--concurrency=1`), analyze
  clean. Next prod code ≥ 75. See
  `.agents/memory/remote-pi-ephemeral-rooms.md`.
- **1.5.24 is released** (2026-10-09, on `dev`, prod `1.5.24` +70, sha
  `5b9af1ad…`): the room info panel (ⓘ) has a **Sessions** entry — a picker
  page listing the stored sessions of the room's cwd (`SessionManager.list`;
  first message / count / date / current badge), tapping one (after a
  confirm) continues that session: the picker pops immediately, the switch
  fires in the background, and the app re-requests the room history at
  +1.5 s / +6 s (`resyncRoom`) as a backstop — because the switch tears down
  the relay and the Pi's `action_ok` + replay broadcast are usually lost in
  the teardown (beta.1 hung on the 15 s timeout for exactly this; user
  reported, fixed in beta.2 / merge `d00f8ca5`). Wire: `session_list`/
  `session_switch` + `sessions_list` + `WireSession` (daemon rooms via RPC
  `switch_session` — supervisor whitelist; interactive via
  `ctx.switchSession`). Same release ships the **session-replacement
  reset**: `session_start` with a `previousSessionFile` different from the
  one that seeded the mirror clears the buffer, re-seeds from the target's
  `getBranch()`, and broadcasts a replay — `/new`/`/resume`/`/fork` in the
  terminal no longer leave stray thinking blocks (the originally reported
  bug). pi-remote **0.13.0** (`remote-pi-0.13.0.tgz`, sha `f78cb39c…`) —
  **requires a Pi/supervisor restart to take effect**. Prod channel +
  Release `v1.5.24-session-picker-arm64` (APK + tgz, self-checked);
  beta.1 (+68) / beta.2 (+69) were tested by the user first. Pi tests 927
  pass, app 856 pass (`sync_attachment_test` flake passes at
  `--concurrency=1`), analyze clean. Next prod code ≥ 71. See
  `.agents/memory/remote-pi-session-picker.md`.
- **1.5.23 is released** (2026-10-08, on `dev`): an image a tool produces — a
  `computer_screen` screenshot, a diagram a tool read — now renders **inside that
  tool's call card** instead of as a card floating under the call. The Pi encodes
  every image block of a successful, non-nested tool call to its own attachment
  store (a tool that reuses `shot.png` would otherwise make an old card show the
  newest picture), and remembers the history half at `message_end` so a re-sync
  keeps the live order; `tool_call_id` is additive, so an older app keeps the old
  separate card. App-side tests: the card is folded into the matching tool row
  and sits **outside** the fold (`embedded`, no second frame/file header); an
  attachment whose tool row is not in the history slice falls back to its own
  card. Beta `1.5.23-beta.1` (+66) was tested by the user; prod `1.5.23` (+67)
  pushed to the production channel, Release `v1.5.23-tool-images-arm64` (APK +
  `remote-pi-0.12.0.tgz`, the Pi side of this change → restart the supervisor).
  See `.agents/memory/remote-pi-tool-image-auto-cards.md`. Next beta will be
  `1.5.24-beta.1`, next prod code ≥ 68.
- **1.5.22 is released** (2026-10-04, branch `fix/viewer-theme`, merged into
  `dev` + deleted): the full-screen file viewer ("show all", or tapping an image
  card) no longer forces a black page. A text file follows the app theme
  (background, chrome, spinner, error color) and renders through `AgentMarkdown`
  — themed code cards, real links, selectable — while an image keeps the black
  backdrop it is read against (the user chose exactly that split). The ugly part
  had a second root cause: the viewer had no `codeBuilder` and the hand-rolled
  `ColorScheme` left `surfaceContainerHighest` at Material's *light* default, so
  gpt_markdown drew a white table header and a white "Copy code" slab onto the
  black page in dark mode — the chat's tables were fixed with it (see
  `.agents/memory/remote-pi-colorscheme-light-defaults.md`). Beta
  `1.5.22-beta.1` (+64) was tested by the user; prod `1.5.22` (+65) pushed to the
  production channel, Release `v1.5.22-viewer-theme-arm64` (APK only — no
  pi-remote change).
- **1.5.21 is released** (2026-10-03, branch `feat/thinking-auto`, merged + deleted):
  the Quick Actions thinking picker gained **auto** (session-level; Pi resolves it
  per request from the task complexity). The app now parses `auto` from
  `room_meta` (before, the unknown string fell back to medium, so a room that
  reported auto showed medium), and pi-remote 0.11.0 seeds `auto` on a
  genuinely new session — probing support first (set, read back) and falling back
  to medium only when the running build clamps it away, so rooms on older Pi
  builds are unaffected. Beta `1.5.21-beta.1`(+62) was tested by the user
  (confirmed: the picker shows auto and the level sticks across reconnects);
  prod `1.5.21`(+63) pushed to the production channel, Release
  `v1.5.21-thinking-auto-arm64` (APK + `remote-pi-0.11.0.tgz`, installed into
  `~/.pi/agent/npm`).

- **Room management (`SPEC-room-management.md`) is delivered** (merged into `dev` and
  released with the 1.5.x series; PR #199 to the original author is still open, so
  don't delete its head branch `pr/room-management`). The spec is kept for reference —
  no need to redo it.
- **The phone command channel is delivered** (merged into `dev`; 0.8.0 / App 1.5.11+31),
  Release `v1.5.11-commands-arm64` (APK + `remote-pi-0.8.0.tgz`). 1.5.11 has been
  pushed to the production channel and verified, and supervisor was restarted (the
  `op:"rpc"` path works).
  The phone composer supports `/slash` (daemon rooms run extension commands / skills /
  templates over the RPC channel, the rest are mapped by hand) and `!shell` (local
  shell, renders a bash card; `!!` output does not enter the model context).
  Design docs: the "Canal de comandos" section of `PROTOCOL.md` +
  `pi-remote/README.md`; implementation notes are in
  `.agents/memory/remote-pi-command-channel.md`.
- **The beta channel (`beta` flavor + the `app-beta` download site) is set up**: the
  first test build `1.5.12-beta.1`(+32) has been pushed to the beta channel (appId
  `work.jacobmoura.remotepi.beta`, coexisting with the production build). Changes:
  `app/android/app/build.gradle.kts` (flavor + `@string/app_name`),
  `rp-s3/selfhost/download_server.py` (the `app-beta` channel), merged into `dev`.
- **1.5.18 is released** (2026-10-01, plan/42): the room top bar shows the model
  name (device name dropped), and the session-info dialog has a Context row
  (`42% (168k / 400k tokens)`). Beta `1.5.18-beta.3`(+53) tested by the user; prod
  `1.5.18`(+54) pushed to the production channel, Release
  `v1.5.18-context-usage-arm64` (APK + `remote-pi-0.10.0.tgz`). Pi-extension 0.10.0
  publishes `room_meta.context` on turn_end (30 s debounce, est. prompt chars/4 vs
  model contextWindow — SDK API is `ctx.sessionManager.getBranch()`, NOT
  `ctx.session`); the relay passes `context` through hello / room_meta_update /
  snapshots (selfhosted relay 2026-10-01 rebuild, `~/relay-src/relay`).
- **1.5.20 is released** (2026-10-02): in-app update downloads upgraded — the
  progress bar now moves in real time (emitted per whole percent), interrupted
  downloads resume where they stopped (APK cached as `RemotePi-<version>.apk`,
  `Range`/206 + dio append; a 200 reply means no Range support → clean retry),
  and the finished APK is published to the phone's public Downloads folder
  (MediaStore, `MediaSaver.saveApk`) under the version-stamped name. The
  download server gained Range/206 support (`rp-s3/selfhost/download_server.py`,
  deployed to cloud177). Beta `1.5.20-beta.1`(+57) + a throwaway
  `1.5.20-beta.2`(+60) were tested by the user (resume verified); prod
  `1.5.20`(+61) pushed to the production channel, Release
  `v1.5.20-update-downloads-arm64` (APK only — no pi-remote change in this
  release). The throwaway packages were reverted: prod channel = 1.5.20 prod,
  beta channel = 1.5.20-beta.1. Next beta will be `1.5.21-beta.1`, next prod
  code ≥ 62.
- **1.5.19 is released** (2026-10-02): composer fixes (Enter always inserts a
  newline; keyboard no longer reopens returning from Settings/info panel;
  tap blank chat space to close the keyboard; gear button stays visible while
  typing) + the room top-bar model name now updates immediately on a switch, and
  a new session/room starts at the default thinking level (medium) again. Beta
  `1.5.19-beta.2`(+56) was tested first. Prod `1.5.19`(+55) pushed to the
  production channel, Release `v1.5.19-composer-model-labels-arm64`
  (APK + `remote-pi-0.10.2.tgz`). Pi-extension 0.10.1 resolves the friendly model
  display name at connect (registry `refresh()` before `find()` — local custom
  providers like llama.cpp/vLLM show e.g. `Qwen3.8-27B`, not the raw id); 0.10.2
  resets the thinking level to the SDK default on a genuinely new session/room
  (the SDK persists every `setThinkingLevel` into the global settings, so a new
  session otherwise inherited the last picked level — see
  `.agents/memory/remote-pi-thinking-level-default.md`).

Don't use `agent_send` to report to Jarvis — report progress by replying to the user
directly in this session.
