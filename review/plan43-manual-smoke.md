# Plan 43 manual smoke checklist

Goal: verify Android app steering while a Pi turn is already `Working...`.

## Built artifact

- Debug APK: `app/build/app/outputs/flutter-apk/app-debug.apk`
- SHA-256 at build time: `311e2bb3f9452544dbc1ac497492160856a17a346f61920a804a39fab4206e1e`

## 1. Install / run

When the phone is connected again:

```bash
cd app
flutter install --debug -d <device-id>
# or keep logs attached:
flutter run -d <device-id>
```

If Flutter defaults to release and fails with `app-release.apk does not exist`, use the explicit debug form above.

## Smoke attempt notes

- 2026-06-10: first Android steering attempt hit Pi SDK busy-prompt error:
  `Agent is already processing. Specify streamingBehavior ('steer' or 'followUp')...`.
- Root cause: the app correctly sent `streaming_behavior: "steer"`, but the
  extension downgraded it to a normal message when its mirrored `_currentTurnId`
  was missing. That can happen after reconnect/late attach or any turn started
  without an active owner.
- Fix: every app-originated SDK handoff now includes `{ deliverAs: "steer" }`.
  The SDK ignores this while idle, but requires it if a turn is already running.
  If no mirrored turn id exists, the extension seeds a fallback id for later
  chunks/done. As a defensive fallback, any app `user_message` received while
  the room is already working is also echoed with steering semantics even if the
  wire field is missing.
- Rebuild run: `cd pi-remote && corepack pnpm build`.

## 2. Single-owner steering smoke

1. Start Pi with the updated `pi-remote` build, then reload/restart Pi so it
   loads the rebuilt `pi-remote/dist`.
2. Open the paired Android room.
3. Send a prompt that keeps the agent working long enough to steer.
   - Example: ask it to inspect multiple files or perform a multi-step analysis.
4. While Android shows `Working...`, type a correction/instruction in the composer.
5. Send it.
6. Expected:
   - text input is enabled while working;
   - typed text sends as a user bubble;
   - the active assistant streaming bubble is not reset to empty;
   - Stop is still reachable by clearing the typed text if needed;
   - the agent incorporates the steering instruction when Pi SDK timing allows;
   - no app crash or extension listener crash.

Result: `[x] pass  [ ] fail`  Notes: User verified from Android that app steering works after patching the installed `~/.pi/agent/npm/node_modules/remote-pi/dist` package and restarting the paired Pi process (`Mesh name: remote_pi`, relay connected).

## 3. Stale working edge

1. If the app appears working but the Pi turn has already ended, send text.
2. Expected:
   - extension still passes `{ deliverAs: "steer" }` defensively;
   - the SDK treats it as a normal prompt when idle;
   - the reply streams normally instead of being dropped.

Result: `[ ] pass  [ ] fail`  Notes:

## 4. Stop after steering

1. Start a working turn.
2. Send one steering message.
3. Clear the composer text if needed and tap Stop.
4. Expected:
   - Stop cancels the original active turn;
   - no steering bubble is deleted after confirmation;
   - app exits working.

Result: `[ ] pass  [ ] fail`  Notes:

## 5. Multi-owner smoke (optional)

1. Open same room from two phones.
2. Start a working turn.
3. Send steering text from phone A.
4. Expected:
   - phone A and B each show the steering user bubble once;
   - neither phone resets the active assistant bubble;
   - Stop from either owner still cancels the active turn.

Result: `[ ] pass  [ ] fail`  Notes:
