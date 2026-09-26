// Plan/57b — Capture other extensions' `ctx.ui.notify()` calls in-process.
//
// Why this exists rather than a bridge over the daemon's stdin/stdout:
//
// Pi builds ONE extension UI context per session and hands that same object to
// every extension (`runner.js`: `ctx.ui` is a getter over a single `uiContext`).
// A `pi --mode rpc` daemon renders each UI call as an `extension_ui_request`
// frame on ITS OWN stdout (see `modes/rpc/rpc-mode.js`), whose only reader is
// the supervisor. Getting that notification back to the phone therefore needed
// a second journey INTO the child — and the only command that reaches an
// extension from stdin is `prompt`, which the SDK turns into a user message and
// answers with a full model turn. Every variant of that design either fed the
// notification to the model or silently died.
//
// In-process capture skips the round trip entirely: wrapping `notify` on the
// shared context means another extension's notification arrives here as a plain
// function call. Nothing is injected, nothing is parsed out of a stream, and no
// turn is started.
//
// This is deliberately NOT the same object as the pi-ask bridge: this capture
// can fail open without harming ask_user, and (unlike the pi-ask contract,
// which is a documented cross-process event bus) it depends on Pi's internal
// sharing of the UI context. Both halves are therefore kept separable.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage } from "./protocol/types.js";

/** The slices of Pi's UI context this capture touches. */
interface UiContextLike {
  notify?: (message: string, type?: string) => void;
  select?: unknown;
  confirm?: unknown;
  input?: unknown;
}

/** Marks a context we already wrapped. Symbol-keyed so it cannot collide with
 *  anything an extension (or Pi) puts on the object, and non-enumerable so a
 *  spread/`Object.keys` walk elsewhere never trips over it. */
const WRAPPED = Symbol.for("remote-pi.ui-notify-capture");

export interface UiNotifyCapture {
  /** Number of notifications forwarded since the last reset (diagnostics/tests). */
  readonly forwardedCount: number;
  /** True once a usable shared context was found and wrapped. */
  readonly armed: boolean;
  /** Restore the original `notify` and stop forwarding. */
  dispose(): void;
}

/**
 * Wrap the session's shared `notify` so notifications raised by ANY extension
 * reach the paired app, then still reach the desktop UI.
 *
 * Idempotent per context: Pi shares one context across all extensions, so a
 * second call would wrap our own wrapper and double-send.
 *
 * Returns `null` only when the API exposes no `on` (nothing to hook).
 */
export function createUiNotifyCapture(
  pi: ExtensionAPI,
  broadcast: (msg: ServerMessage) => void,
  onForwarded?: (message: string) => void,
): UiNotifyCapture | null {
  if (typeof pi.on !== "function") return null;

  let wrapped: { ctx: UiContextLike; original: (message: string, type?: string) => void } | null =
    null;
  let count = 0;
  const unsubscribes: Array<() => void> = [];

  const arm = (ctx: unknown): void => {
    const ui = (ctx as { ui?: UiContextLike } | null | undefined)?.ui;
    if (!ui || typeof ui.notify !== "function") return;
    if ((ui as Record<symbol, unknown>)[WRAPPED]) return; // already ours
    const original = ui.notify.bind(ui);
    wrapped = { ctx: ui, original };
    const replacement = (message: string, type?: string): void => {
      // Forward first (the app must not depend on the desktop UI being alive),
      // then hand off unchanged so the TUI keeps behaving exactly as before.
      try {
        const text = typeof message === "string" ? message : String(message);
        if (text) {
          count += 1;
          broadcast({
            type: "extension_ui_request",
            id: `notify-${Date.now()}-${count}`,
            method: "notify",
            message: text,
            ...(type ? { notify_type: normaliseType(type) } : {}),
          });
          onForwarded?.(text);
        }
      } catch {
        // Never let a relay problem swallow someone else's notification.
      }
      original(message, type);
    };
    ui.notify = replacement;
    Object.defineProperty(ui, WRAPPED, { value: true, enumerable: false });
  };

  // Which hook actually fires is mode-dependent, and getting this wrong makes
  // the whole capture silently inert: under `pi --mode rpc` (every daemon child)
  // only `session_start` is raised — `input` never happens. Interactive and
  // print modes do raise `input`. Register both; `arm()` is idempotent per
  // context, so the first delivery wins and the second is a no-op.
  try {
    const off: unknown = pi.on("input", (_event: unknown, ctx: unknown) => {
      arm(ctx);
    });
    if (typeof off === "function") unsubscribes.push(off as () => void);
  } catch {
    // A host that rejects the hook leaves the capture unarmed; the bridge stays
    // inert rather than throwing on load.
  }
  try {
    const off: unknown = pi.on("session_start", (_event: unknown, ctx: unknown) => {
      arm(ctx);
    });
    if (typeof off === "function") unsubscribes.push(off as () => void);
  } catch {
    // As above: never let a rejected hook break extension load.
  }

  return {
    get forwardedCount() {
      return count;
    },
    get armed() {
      return wrapped !== null;
    },
    dispose() {
      for (const off of unsubscribes) {
        try {
          off();
        } catch {
          /* best effort */
        }
      }
      unsubscribes.length = 0;
      if (wrapped) {
        wrapped.ctx.notify = wrapped.original;
        wrapped = null;
      }
    },
  };
}

/** Pi's notify types are info | warning | error; anything else is reported as
 *  informational rather than as a level the app cannot render. */
function normaliseType(type: string): "info" | "warning" | "error" {
  return type === "warning" || type === "error" || type === "info" ? type : "info";
}
