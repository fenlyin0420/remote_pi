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
   `export PATH=$HOME/flutter/flutter/bin:$HOME/jdk-21.0.12.1+1/bin:$PATH`,
   `JAVA_HOME=$HOME/jdk-21.0.12.1+1`, `ANDROID_HOME=$HOME/Android/Sdk`
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
6. Pi-side (pi-extension) changes must also be made usable for the user: `npm pack` to
   produce a tgz, attach it to the same Release, then
   `cd ~/.pi/agent/npm && npm install ./remote-pi-<version>.tgz`.
   **Restarting supervisor kills every turn currently running in every room (including
   this session) — only remind the user to do it themselves; locally it is a system
   unit and sudo needs a password, so you can use `kill -TERM <supervisord pid>` and let
   systemd (`Restart=always`) bring it back up, but always send your reply first. See
   `remote-pi-extension-load-path`.**

## Current state

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
  `pi-extension/README.md`; implementation notes are in
  `.agents/memory/remote-pi-command-channel.md`.
- **The beta channel (`beta` flavor + the `app-beta` download site) is set up**: the
  first test build `1.5.12-beta.1`(+32) has been pushed to the beta channel (appId
  `work.jacobmoura.remotepi.beta`, coexisting with the production build). Changes:
  `app/android/app/build.gradle.kts` (flavor + `@string/app_name`),
  `rp-s3/selfhost/download_server.py` (the `app-beta` channel), merged into `dev`.

Don't use `agent_send` to report to Jarvis — report progress by replying to the user
directly in this session.
