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
import type { ClientMessage, ServerMessage, WireModel } from "../protocol/types.js";
/**
 * Structural subset of the SDK's `Model<Api>` interface (defined in
 * `@earendil-works/pi-ai`, which is a transitive dep — not re-exported by
 * `@earendil-works/pi-coding-agent`'s main entry). Capturing just the
 * fields we touch keeps the handler decoupled from the SDK's full Model
 * surface and avoids a direct dep on `pi-ai`.
 */
export interface SdkModelLike {
    id: string;
    name: string;
    provider: string;
    reasoning: boolean;
    contextWindow: number;
    /** Plan/30: accepted input modalities. The SDK's `Model.input` is
     *  `("text" | "image")[]`; we read `includes("image")` for the `vision`
     *  flag. Optional here so tests can omit it (treated as text-only). */
    input?: ("text" | "image")[];
}
type Model<_TApi = unknown> = SdkModelLike;
/**
 * Minimal channel surface needed to reply. Mirrors `PlainPeerChannel`'s
 * `.send` signature; tests pass an array-backed fake.
 */
export interface ActionReplySender {
    send(msg: ServerMessage): void;
}
/**
 * Narrow shape of the `ExtensionAPI` surface action handlers actually
 * call. Lets the test layer stub just these without rebuilding the full
 * SDK type (which has 30+ methods we don't use here).
 */
export interface ActionPi {
    setModel(model: Model<any>): Promise<boolean>;
    setThinkingLevel(level: import("../protocol/types.js").ThinkingLevel): void;
}
/**
 * Narrow shape of the per-call context. Drawn from the union of
 * `ExtensionContextActions` (compact, getModel) and
 * `ExtensionCommandContextActions` (newSession), since index.ts caches
 * the most-recent ctx and that's typically the command one.
 *
 * All fields are optional so a missing method (e.g. when only a plain
 * `ExtensionContext` was seen) becomes a typed `action_error` instead of
 * a runtime TypeError.
 */
/**
 * Structural subset of the SDK's `CompactOptions` — only what remote-pi passes.
 *
 * `onError` is the important one: `ctx.compact()` is fire-and-forget, so
 * without it a refused compaction (a session too small to compact, most often)
 * was indistinguishable from a button that does nothing.
 */
export interface ActionCompactOptions {
    customInstructions?: string;
    onComplete?: (result: unknown) => void;
    onError?: (error: Error) => void;
}
export interface ActionCtx {
    compact?: (options?: ActionCompactOptions) => void;
    /**
     * Starts a new session. `withSession` is the SDK's blessed hook for
     * post-replacement work: it receives a FRESH, command-capable ctx bound to
     * the new session. The SDK marks any ctx captured BEFORE this call stale, so
     * callers must re-capture via `withSession` rather than reuse the old ctx.
     */
    newSession?: (options?: {
        withSession?: (ctx: ActionCtx) => Promise<void>;
    }) => Promise<{
        cancelled: boolean;
    }>;
    /**
     * Continues a different stored session (the session picker, plan/59).
     * `withSession` re-captures the command-capable ctx bound to the
     * target session — the SDK marks the pre-call ctx stale, so callers
     * MUST re-capture rather than reuse it. Command-ctx only, like
     * `newSession`.
     */
    switchSession?: (sessionPath: string, options?: {
        withSession?: (ctx: ActionCtx) => Promise<void>;
    }) => Promise<{
        cancelled: boolean;
    }>;
    getModel?: () => Model<any> | undefined;
    /**
     * Live session registry from Pi's extension ctx. Includes providers/models
     * registered dynamically via `pi.registerProvider(...)`, unlike the fallback
     * disk-backed registry remote-pi can build on its own.
     */
    modelRegistry?: ActionModelRegistry;
}
/**
 * Minimal shape of the registry surface. Maps 1:1 onto `ModelRegistry`
 * but lets tests fake catalogs without instantiating the real one.
 */
export interface ActionModelRegistry {
    refresh(): void;
    getAvailable(): Model<any>[];
    find(provider: string, modelId: string): Model<any> | undefined;
}
/** Project a SDK `Model<Api>` onto the wire schema. Shared by list_models
 *  and the `current` echo, so both stay in lockstep. */
export declare function wireFromModel(model: Model<any>): WireModel;
type SessionCompactMsg = Extract<ClientMessage, {
    type: "session_compact";
}>;
type SessionNewMsg = Extract<ClientMessage, {
    type: "session_new";
}>;
type ModelSetMsg = Extract<ClientMessage, {
    type: "model_set";
}>;
type ThinkingSetMsg = Extract<ClientMessage, {
    type: "thinking_set";
}>;
type ListModelsMsg = Extract<ClientMessage, {
    type: "list_models";
}>;
export declare function handleSessionCompact(ctx: ActionCtx | null, sender: ActionReplySender, msg: SessionCompactMsg): void;
/**
 * Reports why a compaction was refused. `ctx.compact()` is fire-and-forget:
 * the `action_ok` reply only means "dispatched", so a failure has nowhere to
 * go but a pushed frame — and without one a refused `/compact` (a session too
 * small to compact, most often) looked exactly like a dead button.
 */
export declare function reportCompactFailure(sender: ActionReplySender, err: unknown): void;
export declare function handleSessionNew(ctx: ActionCtx | null, sender: ActionReplySender, msg: SessionNewMsg, onReplaced?: (freshCtx: ActionCtx) => void): Promise<boolean>;
export declare function handleThinkingSet(pi: ActionPi, sender: ActionReplySender, msg: ThinkingSetMsg): void;
export declare function handleModelSet(pi: ActionPi, ctx: ActionCtx | null, reg: ActionModelRegistry, sender: ActionReplySender, msg: ModelSetMsg, onPersist?: (provider: string, modelId: string) => void, onModelSet?: (model: {
    provider: string;
    id: string;
    name?: string;
}) => void): Promise<void>;
export declare function handleListModels(ctx: ActionCtx | null, reg: ActionModelRegistry, sender: ActionReplySender, msg: ListModelsMsg): void;
export {};
