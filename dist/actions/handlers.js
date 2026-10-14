/**
 * Plan/28 Wave B — typed action handlers.
 *
 * Each handler maps one `ClientMessage` action to a public Pi SDK call,
 * and replies with `action_ok` or `action_error`. Handlers take their
 * dependencies as parameters so the index.ts wiring is one-liner and
 * unit tests can pass fakes without touching global state.
 *
 * `models_list` lives next door because it shares the `ModelRegistry`
 * helper and the same wire vocabulary.
 *
 * SDK API surface used (see plan/28 Wave 0 for the full table):
 *
 *   - `ctx.compact()`            — non-blocking, fires `session_compact`
 *                                  event when done
 *   - `ctx.newSession()`         — only on `ExtensionCommandContext`;
 *                                  resolves with `{cancelled}` flag
 *   - `pi.setModel(model)`       — returns `false` if no auth configured
 *   - `pi.setThinkingLevel(lvl)` — synchronous
 *   - `ctx.getModel()`           — optional, undefined before first turn
 *   - `ModelRegistry.{refresh,getAvailable,find}` — see `registry.ts`
 */
/** Project a SDK `Model<Api>` onto the wire schema. Shared by list_models
 *  and the `current` echo, so both stay in lockstep. */
export function wireFromModel(model) {
    return {
        id: model.id,
        name: model.name,
        provider: model.provider,
        reasoning: model.reasoning,
        context_window: model.contextWindow,
        // Plan/30: vision = model accepts image input. `Model.input` is
        // `("text" | "image")[]` at runtime (confirmed against pi-ai). `?.` guards
        // a fake/partial model in tests → treated as text-only.
        vision: model.input?.includes("image") ?? false,
    };
}
// ── ack helpers ────────────────────────────────────────────────────────────
function ok(sender, msg, action) {
    sender.send({ type: "action_ok", in_reply_to: msg.id, action });
}
function fail(sender, msg, action, err) {
    const error = err instanceof Error ? err.message : String(err);
    sender.send({ type: "action_error", in_reply_to: msg.id, action, error });
}
/** Run a synchronous action with uniform success/failure replies. */
function runSync(sender, msg, action, body) {
    try {
        body();
        ok(sender, msg, action);
    }
    catch (e) {
        fail(sender, msg, action, e);
    }
}
/** Run an async action with uniform success/failure replies. */
async function runAsync(sender, msg, action, body) {
    try {
        await body();
        ok(sender, msg, action);
        return true;
    }
    catch (e) {
        fail(sender, msg, action, e);
        return false;
    }
}
export function handleSessionCompact(ctx, sender, msg) {
    runSync(sender, msg, "session_compact", () => {
        if (!ctx?.compact)
            throw new Error("compact unavailable (no active session ctx)");
        // Force the summary to English regardless of the conversation language —
        // the summary is surfaced to the app via the `compaction` message, which
        // is an English-only surface. `customInstructions` is appended to the SDK's
        // compaction prompt (best-effort: the model writes the summary).
        ctx.compact({
            customInstructions: "Always write the compaction summary in English, even if the conversation is in another language.",
            onError: (err) => reportCompactFailure(sender, err),
        });
    });
}
/**
 * Reports why a compaction was refused. `ctx.compact()` is fire-and-forget:
 * the `action_ok` reply only means "dispatched", so a failure has nowhere to
 * go but a pushed frame — and without one a refused `/compact` (a session too
 * small to compact, most often) looked exactly like a dead button.
 */
export function reportCompactFailure(sender, err) {
    const detail = err instanceof Error ? err.message : String(err);
    sender.send({
        type: "error",
        code: "command_failed",
        message: `/compact failed: ${detail}`,
    });
}
export async function handleSessionNew(ctx, sender, msg, onReplaced) {
    // Returns true only when a fresh session was actually created. index.ts
    // keys the Pi-side reset (clear _messageBuffer, restamp _sessionStartedAt,
    // fan out an empty session_history) off this signal — a `cancelled`/errored
    // new-session must NOT reset, so we return runAsync's success boolean.
    return runAsync(sender, msg, "session_new", async () => {
        if (!ctx?.newSession)
            throw new Error("newSession unavailable (no command ctx yet)");
        // newSession marks the caller's captured ctx (index.ts's `_lastCtx`) STALE
        // — reusing it later throws "stale after session replacement" (the
        // compact-after-New-session crash). `withSession` hands back a fresh,
        // command-capable ctx bound to the new session; forward it via onReplaced
        // so the caller re-captures and keeps later actions off the stale ctx.
        const result = await ctx.newSession({
            withSession: async (freshCtx) => { onReplaced?.(freshCtx); },
        });
        // `cancelled: true` happens when the SDK's hook chain vetoes the new
        // session (e.g. an extension's `session_before_switch` returned a
        // refusal). Surface as a typed error rather than silent success.
        if (result.cancelled)
            throw new Error("cancelled by extension hook");
    });
}
export function handleThinkingSet(pi, sender, msg) {
    runSync(sender, msg, "thinking_set", () => {
        pi.setThinkingLevel(msg.level);
    });
}
export async function handleModelSet(pi, ctx, reg, sender, msg, onPersist, onModelSet) {
    await runAsync(sender, msg, "model_set", async () => {
        // Prefer Pi's LIVE session registry when available so the app sees models
        // registered dynamically by extensions via `pi.registerProvider(...)`.
        // Fall back to remote-pi's own disk-backed registry when no ctx exists.
        const liveReg = ctx?.modelRegistry ?? reg;
        // Refresh first so a model just-added via `/login` is visible.
        liveReg.refresh();
        const model = liveReg.find(msg.provider, msg.model_id);
        if (!model) {
            throw new Error(`model "${msg.provider}/${msg.model_id}" not in registry`);
        }
        const success = await pi.setModel(model);
        if (!success)
            throw new Error("no auth configured for this model");
        // Publish the switch EXPLICITLY. The SDK's `model_select` event — the
        // only thing the extension's room_meta fan-out has listened to — is
        // suppressed by `modelsAreEqual(previousModel, nextModel)`, so switching
        // to the model the session already runs emits nothing and the app's
        // cached room model (stale after a restart or a terminal switch) is
        // never corrected, no matter how often the user re-picks the same
        // model. `onModelSet` re-publishes the room_meta model unconditionally.
        onModelSet?.(model);
        // `pi.setModel` only sets the LIVE model — it does NOT persist. Without
        // this, a model picked from the app reverts to the saved default on the
        // next Pi/daemon restart (the TUI persists because AgentSession.setModel
        // writes the default; this path doesn't). `onPersist` writes the new
        // default so the app's choice survives. Best-effort — the caller's writer
        // must not throw, so a failed settings write never fails the model change.
        onPersist?.(model.provider, model.id);
    });
}
export function handleListModels(ctx, reg, sender, msg) {
    // refresh() can throw if `models.json` is malformed — wrap in try so the
    // app gets an explicit error reply instead of a silent drop.
    try {
        // Prefer Pi's LIVE session registry when available so the app sees models
        // registered dynamically by extensions via `pi.registerProvider(...)`.
        // Fall back to remote-pi's own disk-backed registry when no ctx exists.
        const liveReg = ctx?.modelRegistry ?? reg;
        liveReg.refresh();
        const models = liveReg.getAvailable().map(wireFromModel);
        const current = ctx?.getModel?.();
        sender.send({
            type: "models_list",
            in_reply_to: msg.id,
            models,
            current: current ? wireFromModel(current) : undefined,
        });
    }
    catch (e) {
        sender.send({
            type: "error",
            in_reply_to: msg.id,
            code: "internal_error",
            message: e instanceof Error ? e.message : String(e),
        });
    }
}
//# sourceMappingURL=handlers.js.map