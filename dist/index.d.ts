#!/usr/bin/env node
/**
 * pi-remote — remote-pi slash commands + AgentBridge wiring
 *
 * Exported as ExtensionFactory (default export) to be loaded by Pi SDK:
 *   pi -e $(pwd)/dist/index.js
 *
 * State machine:  idle → started → paired
 *   /remote-pi start   connects to relay (idle → started)
 *   /remote-pi pair    shows QR for new peers (started, async → paired via auto-listener)
 *   /remote-pi stop    closes everything (any → idle)
 *
 * Pairing (post plano 06 — sem Noise XX):
 *   App envia inner `pair_request` (id, token, device_name) sobre canal opaco.
 *   Pi valida o token via qrSession.consumeToken, salva peer em peers.json
 *   {name, remote_epk, paired_at} e responde com `pair_ok` (ou `pair_error`).
 *   `ct` é base64(JSON.stringify(inner)) — sem cifra, sem MAC.
 *
 * Reconexão de peer conhecido:
 *   Se uma mensagem chega em estado `started` vinda de um epk presente em
 *   peers.json, o auto-listener promove direto pra `paired` sem novo
 *   pair_request, criando o PlainPeerChannel e roteando a mensagem.
 *
 * Architecture note — why we don't use AgentBridge directly here:
 *   AgentBridge.beforeToolCallHook is designed to be passed to createAgentSession().
 *   Inside an extension Pi already owns the AgentSession, so we can't re-bind
 *   beforeToolCall after the fact. The equivalent is pi.on("tool_call", …) which
 *   fires BEFORE execution and supports { block: true }.
 *   AgentBridge (src/session/agent_bridge.ts) remains the tested, mockable unit
 *   for integration tests.
 */
import type { ExtensionContext, ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { ClientMessage, SessionHistoryEvent, WireCommand } from "./protocol/types.js";
import { PlainPeerChannel } from "./transport/peer_channel.js";
export type RemoteState = "idle" | "started";
/** Relay connectivity as seen by an RPC client (Cockpit). Derived from
 *  `_state` + `_relay`: "disconnected" = relay off (idle); "connected" = live
 *  WS; "reconnecting" = was on, WS dropped, retrying. Surfaced via the
 *  `remote-pi:relay-state` custom message (see `_emitRelayState`). */
export type RelayConnectivity = "connected" | "reconnecting" | "disconnected";
/** Sentinel prefix for a transparent control message an RPC client sends on the
 *  `prompt` channel (stdin). The `input` hook intercepts it, runs the action,
 *  and swallows it (`action:"handled"`) so it never becomes an LLM turn or a
 *  transcript entry. Starts with NUL so it can't collide with real user input
 *  and doesn't begin with "/" (which would route to the command parser). */
export declare const CTRL_PREFIX = "\0remote-pi-ctrl:";
/** Test seam: forget queued images between cases. */
export declare function _resetPendingToolImagesForTest(): void;
/** Test seam: land uploads in a temp dir instead of `~/.pi/remote/uploads`. */
export declare function _setUploadDirForTest(dir?: string): void;
type BufferMsg = {
    role: "user" | "assistant" | "toolResult" | string;
    content?: unknown;
    timestamp?: number;
    toolCallId?: string;
    toolName?: string;
    isError?: boolean;
    usage?: {
        input?: number;
        output?: number;
    };
    /** Plan/32: pre-compaction token count, set on the synthetic
     *  `role:"compaction"` marker pushed in `session_compact`. */
    tokensBefore?: number;
    /** LOCAL (fenlyin): model that produced this message. Assistant messages
     *  carry it from the session file / SDK (raw model id, resolved to a
     *  friendly name at map time when `provider` is present). User messages
     *  never carry one — the per-row model caption identifies the model that
     *  generated the reply, which is meaningless on your own message. */
    model?: string;
    /** LOCAL (fenlyin): provider of `model` (raw ids only — marks the value as
     *  un-resolved so the mapper can resolve it against the model registry). */
    provider?: string;
    /** LOCAL (fenlyin): wall-clock duration of each reasoning block of this
     *  assistant message, in content order. Measured live from the SDK's
     *  `thinking_start`/`thinking_end` (see the message_update hook) and
     *  attached here so a `session_history` replay can report the same timings
     *  the app already showed live. Absent for messages seeded from the session
     *  file — the app then just omits the timer. */
    thinkingDurations?: number[];
};
type MeshEnvelope = {
    id: string;
    from: string;
    re: string | null;
    body: unknown;
};
/** Test-only override of the message buffer. */
/**
 * Test-only: emulate what `/remote-pi` does on the returning-user path
 * (join the local mesh, then start the relay) without touching the FS for
 * a `localConfigExists()` lookup. Lets tests bring the relay up without
 * mocking the wizard or the local config storage.
 *
 * Typed loosely to accept any ctx shape with `ui.notify` + `cwd` — the
 * unit tests use minimal mocks that don't satisfy the full
 * `ExtensionContext` interface.
 */
export declare function _connectForTest(ctx: unknown): Promise<void>;
/** Test-only: tear everything down (mirrors `/remote-pi stop`). */
export declare function _stopForTest(ctx: unknown): Promise<void>;
/** Test-only: read/reset the `_disposed` flag. Production clears it only when
 *  a host reuses this module for a replacement session; tests share one module
 *  across cases, so they also reset it to avoid cross-test pollution. */
export declare function _getDisposedForTest(): boolean;
export declare function _setDisposedForTest(v: boolean): void;
/** Test-only: reset the once-per-session auto-init gate so session_start re-runs it. */
export declare function _resetAutoInitedForTest(): void;
/** Test-only: set the auto-init gate for lifecycle replacement tests. */
export declare function _setAutoInitedForTest(value: boolean): void;
/** Test-only: true when this instance holds a live local-mesh node. */
export declare function _hasMeshNodeForTest(): boolean;
/** Test-only: drive the current real SelfRevoke producer through one sweep. */
export declare function _checkSelfRevokeForTest(): Promise<void>;
/** Test-only: the effective (possibly `#N`-suffixed) name the cwd-lock reserved. */
export declare function _getLockedNameForTest(): string | null;
/** Test-only: release + clear the cwd lock (the lock normally survives stop). */
export declare function _resetCwdLockForTest(): void;
/**
 * Test-only: relay-only startup, no UDS mesh join. Replaces the old
 * `remote-pi relay start` handler that some tests captured to bring up
 * the relay in isolation (e.g. ping/pong tests that don't care about the
 * agent-network broker).
 */
export declare function _startRelayForTest(ctx: unknown): Promise<void>;
/** Test-only: public marker for canceled-keypair cache regression checks. */
export declare function _getCachedPublicKeyForTest(): string | null;
/** Test-only: force the context-usage debounce clock so a publish is allowed. */
export declare function _setLastContextPublishForTest(ts: number): void;
/** Test-only: the throwaway ModelRegistry factory used when the host
 *  registry is stale for the room's provider (fresh daemon room in a
 *  multi-room supervisor process). */
declare let _testThrowawayRegistryFactory: ((auth: unknown) => {
    find: (p: string, m: string) => {
        contextWindow?: number;
    } | undefined;
    refresh: () => void;
}) | null;
export declare function _setThrowawayRegistryFactoryForTest(factory: typeof _testThrowawayRegistryFactory): void;
/** Test-only: the contextWindow resolver (live model → host registry →
 *  throwaway registry). */
export declare function _resolveContextLimitForTest(ctx: unknown): number | undefined;
/** Test-only: allow re-running the one-shot history seed. */
export declare function _resetHistorySeedForTest(): void;
export declare function _setMessageBufferForTest(msgs: unknown[]): void;
/** Test-only accessor: returns a defensive copy of the buffer. */
export declare function _getMessageBufferForTest(): unknown[];
/** Test-only override of session started timestamp. */
export declare function _setSessionStartedAtForTest(ts: number | null): void;
/** Test-only: reset the cached model name (between tests). */
export declare function _setCurrentModelForTest(name: string | undefined): void;
/** Test-only: read the active turn id used for plain `cancel` routing. */
export declare function _getCurrentTurnIdForTest(): string | null;
export declare function _getPendingSteerIdsForTest(text: string): string[];
/** Test-only: override the bound AgentSession so a spy can capture the
 *  content handed to `sendUserMessage` (plan/30 multimodal ingest). */
export declare function _setPiForTest(pi: unknown): void;
/** Test-only: set the captured command ctx the `session_switch` interactive
 *  leg calls `switchSession` on. */
export declare function _setLastCtxForTest(ctx: unknown): void;
/** Test-only: anchor the `is_current` flag on `session_list` + the
 *  session-replacement detection to a known file. */
export declare function _setLastKnownSessionFileForTest(file: string | null): void;
/** Test-only: exposes pending lock-wait timer state. */
export declare function _hasPendingLockWaitForTest(): boolean;
export declare const THINKING_EVENT_MAX_CHARS = 16384;
/** Prefills `_messageBuffer` with the resumed session's messages (once per process). */
export declare function _seedMessageBufferFromSession(ctx: unknown): void;
/** Test-only: exposes pending reconnect timer state. */
export declare function _hasPendingReconnect(): boolean;
/**
 * Public state-snapshot helper. Returns the derived UX state, not the raw
 * `_state` enum: the W2D refactor collapsed the internal machine to
 * `idle | started` and made `paired` a derived metric
 * (`_activePeers.size > 0`). Tests and the footer keep the three-state
 * mental model via this getter.
 */
export declare function _getState(): "idle" | "started" | "paired";
/** Test-only: number of owners currently attached via PlainPeerChannel. */
export declare function _getActivePeerCountForTest(): number;
/** Test-only: true if a specific peer (base64 std) has an attached channel. */
export declare function _hasActivePeerForTest(appPeerIdStd: string): boolean;
/**
 * Handle a transparent control command from an RPC client (Cockpit), received
 * as a `CTRL_PREFIX`-tagged input the `input` hook swallowed. Toggles the relay
 * WITHOUT leaving the local mesh (relay-only: `_cmdStart` up / `_goIdle` down),
 * then emits the fresh state. `relay:status` just re-emits (no change) so the
 * client can sync its button after (re)attaching to the RPC stream.
 */
export declare function _handleControl(cmd: string): Promise<void>;
/**
 * Per-owner disconnect callback. Fires when one specific owner's channel
 * detaches (e.g. relay told us the peer is gone). Other owners' channels
 * keep running — relay stays "started".
 *
 * Exported so tests can trigger the disconnect path for a specific peer.
 *
 * Backward-compat: a no-arg call (legacy tests / pre-W2D callers) falls
 * back to detaching the most recently attached peer, mirroring the old
 * singleton semantics.
 */
export declare function _onPeerDisconnect(appPeerId?: string): void;
declare const extension: ExtensionFactory;
export default extension;
/** Test-only entry point for verifying mesh-to-agent delivery semantics. */
export declare function _deliverMeshMessageToAgentForTest(env: MeshEnvelope): void;
export declare function _routeClientMessageFrom(sender: PlainPeerChannel, msg: ClientMessage, ctx: Pick<ExtensionContext, "abort">): void;
/** Where a slash command can run. `tui` = recognised but not reachable from
 *  the phone, listed only so the app's palette can say so honestly. */
export type CommandScope = "all" | "daemon" | "tui";
export interface BuiltinCommand {
    name: string;
    description: string;
    scope: CommandScope;
}
/**
 * Pi's builtin slash commands, annotated with what remote-pi does about each,
 * plus one addition.
 *
 * The 22 `BUILTIN_SLASH_COMMANDS` the TUI ships are all here, so a name a user
 * knows from the desktop always gets a real answer rather than "unknown".
 * `/thinking` is remote-pi's own entry: the TUI reaches that setting with a
 * keybinding, but the app already drives the same typed action from its
 * segmented control, so refusing the name would be gratuitous.
 *
 * Scope `all` means the phone can run it in any room — those are exactly the
 * SDK surfaces the app already drives as typed actions (`session_compact`,
 * `session_new`, `model_set`, `thinking_set`). `/clone` and `/export` would
 * work over RPC but produce server-side objects the phone can't act on, and
 * `/quit`, `/login`, `/settings`… are TUI surfaces; all of those are `tui`.
 */
export declare const BUILTIN_COMMANDS: readonly BuiltinCommand[];
/** Hard cap on the shell output we mirror. The relay frame budget is shared
 *  with the whole session, so an accidental `cat` of a huge file must not
 *  starve it. */
export declare const BASH_OUTPUT_MAX_CHARS = 64000;
/** Splits "/name some args" into its parts. Null when the text isn't a slash
 *  command, is a bare "/", or carries no name at all. Exported for tests. */
export declare function _splitSlashCommand(text: string): {
    name: string;
    args: string;
} | null;
/** Everything the app may offer in its `/` palette, with per-room support. */
export declare function _commandsForSession(daemonMode?: boolean): WireCommand[];
/**
 * Strips what would break the app's text layout out of shell output: C0/C1
 * control characters (keeping tab/newline/return), DEL, and unpaired
 * surrogates. Pi's own bash tool sanitizes the same way before rendering;
 * the helper isn't part of the SDK's public entry, so this is a local copy of
 * the rules that matter for a text card.
 */
export declare function _sanitizeShellOutput(text: string): string;
/**
 * Renders a finished shell command as the text of its `bash` card. stdout and
 * stderr are merged in arrival order like Pi's own bash output, and a non-zero
 * exit (or a killed process) gets a trailer so the phone can see the outcome
 * without a second field on the wire.
 */
export declare function _formatBashResult(stdout: string, stderr: string, code: number, killed: boolean): string;
/**
 * Backward-compatible shim for legacy callers + tests that didn't track
 * a specific sender channel. Routes to the most recently attached owner,
 * mirroring the pre-W2D singleton behavior.
 */
export declare function routeClientMessage(msg: ClientMessage, ctx: Pick<ExtensionContext, "abort">): void;
/**
 * Maps SDK AgentMessage[] (UserMessage / AssistantMessage / ToolResultMessage)
 * into the flat SessionHistoryEvent[] shape consumed by the app.
 *
 * Caveats (see report): in_reply_to of agent_message is the *last* user_input
 * id seen in a linear scan — fine for typical conversational flow but not
 * a perfect reconstruction of multi-turn ordering when tools interleave.
 * Stable id for user_input is `sync_<timestamp>`.
 */
export declare function _mapAgentMessagesToEvents(messages: BufferMsg[], resolveModel?: (provider: string, modelId: string) => string): SessionHistoryEvent[];
/**
 * `remote-pi restart-supervisor` — restarts the `pi-supervisord` PROCESS
 * (not the daemons). The supervisor is a long-running Node process with no
 * hot-reload, so after a `dist` rebuild the old code keeps running until the
 * process is restarted. The Cockpit "Restart supervisor" button shells out to
 * this; the OS-specific restart lives here so the app stays cross-platform.
 *
 * Restarting the supervisor re-spawns every daemon as a side effect. Exits 0
 * on success, non-zero on failure (the Cockpit detects failure by exit code).
 */
/** One step of a restart sequence. `ignoreFailure` steps (e.g. `schtasks /End`
 *  when the task isn't running) don't abort the sequence. */
export interface RestartStep {
    cmd: string;
    args: string[];
    ignoreFailure?: boolean;
}
/** Pure: the OS command sequence that restarts the supervisor service, or null
 *  when the platform isn't supported. Most platforms are 1 step; Windows is 2
 *  (`schtasks /End` then `/Run`). Exported for tests. */
export declare function _restartSupervisorCommand(platform: NodeJS.Platform, uid: number): RestartStep[] | null;
/**
 * Read-only probe of the local UDS broker for the mesh roster, backing
 * `remote-pi peers`. Opens a raw connection to `sockPath`, sends a single
 * unregistered `list_peers` request, and resolves with the peer names from the
 * broker's reply (local UDS peers + cross-PC `<pc>:<peer>` entries).
 *
 * The probe deliberately does NOT register as a peer: the broker answers
 * observer probes without assigning a name or broadcasting peer_joined/left
 * (see Broker._tryObserverProbe), so a shell query never perturbs the mesh —
 * no phantom peer flashes in anyone's roster, local or cross-PC.
 *
 * Resolves null when no broker is reachable (connection refused / no socket
 * file — i.e. no Pi or daemon is leading the mesh on this machine), or on
 * timeout, so the caller can print an "offline" message instead of an empty
 * roster.
 */
export declare function probeListPeers(sockPath: string, timeoutMs?: number): Promise<string[] | null>;
