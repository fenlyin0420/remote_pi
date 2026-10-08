import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";

/**
 * Stable 8-character hex id for a daemon, derived from the cwd it manages.
 *
 * Derivation: `sha256(realpath(cwd))` truncated to 8 hex chars (32 bits ≈
 * 4 billion). Collision risk is negligible at fleet sizes a single user
 * will ever have (<1000 daemons), and 8 hex characters are short enough
 * to type on the CLI (`/remote-pi send a1b2c3d4 "..."`).
 *
 * Same scheme as `roomIdForCwd` in `src/rooms.ts` — but we use hex
 * instead of base64url so the id has no `_`/`-` (cleaner double-click
 * selection in terminals).
 *
 * Symlinks resolve to a single canonical id via `realpath`, so
 * `/Users/x/Movies` and `/Users/x/link-to-Movies` map to the same daemon.
 * Falls back to the raw path when realpath fails (cwd doesn't exist —
 * shouldn't happen in production but covers test sandboxes).
 *
 * plan/41 audit (2026-06-08): this stays **per-cwd** (no name axis). The
 * multiagent-per-folder model (plan/38/41) applies to the App↔Pi room and the
 * mesh address; a *supervisor daemon* is **one per cwd** by design — the
 * registry keys exactly one entry per cwd (`registry.ts`), so a daemon id never
 * needs the name to disambiguate. Decision: leave `daemonIdForCwd` cwd-only.
 */
export function daemonIdForCwd(cwd: string): string {
  let target: string;
  try {
    target = realpathSync(cwd);
  } catch {
    target = cwd;
  }
  return createHash("sha256").update(target).digest("hex").slice(0, 8);
}
