import { EventEmitter } from "node:events";
import type { DaemonState, RpcCommandWire, RpcResponseWire } from "./control_protocol.js";
import { type LocalConfig } from "../session/local_config.js";
/**
 * Wrapper around a `pi --mode rpc -e <extension>` child process for the
 * supervisor.
 *
 * Lifecycle:
 *   - `spawn()` boots the child with the daemon's cwd + `REMOTE_PI_DAEMON=1`
 *     env so the extension knows to skip the interactive wizard.
 *   - `sendPrompt(text)` writes a Pi RPC `prompt` command to stdin.
 *   - The child's stdout (Pi RPC events) is currently consumed line-by-line
 *     and ignored — wave 2 only needs fire-and-forget. Later waves can
 *     surface the events back through the supervisor's status op.
 *   - Exit/crash fires `exit` event with `{code, signal, isCrash}` so the
 *     supervisor can decide whether to auto-restart.
 *
 * Each `RpcChild` instance maps 1:1 to a registry entry (single cwd).
 * The supervisor owns the map of these and addresses them by `id`.
 */
export interface RpcChildOptions {
    /** Path to the `pi` binary. Defaults to "pi" (must be on PATH). */
    piBin?: string;
    /** Absolute path to the remote-pi `dist/index.js` to load as -e. */
    extensionPath: string;
    /** Working directory for the spawned process. Determines which local
     *  config the extension reads. */
    cwd: string;
    /** Additional env vars merged on top of `process.env` + the mandatory
     *  `REMOTE_PI_DAEMON=1`. */
    env?: NodeJS.ProcessEnv;
    /**
     * Daemon config injected into the child via `REMOTE_PI_DIRECT_CONFIG`
     * (JSON inline) instead of a per-cwd `.pi/remote-pi/config.json` file. The
     * supervisor builds this from the registry. When set, the child reads it
     * env-first (see `loadLocalConfig`) and no config file is needed. Also the
     * source of the `--name` for the session. Falls back to the on-disk config
     * when omitted.
     */
    config?: LocalConfig;
    /**
     * Never pass `--continue` — every spawn starts a BRAND-NEW session file
     * instead of resuming the cwd's most recent one. This is the ephemeral
     * (phone-forked) room case: the fork must not inherit the conversation of
     * the daemon/interactive session that already lives in this cwd.
     */
    freshSession?: boolean;
    /**
     * Phone-created throwaway room (ephemeral). Marks the child with
     * `REMOTE_PI_EPHEMERAL=1` so the extension treats the cwd lock like an
     * interactive agent — it auto-suffixes (`name#2`, `name#3`, …) instead of
     * waiting for a same-folder daemon to exit — and never takes over a
     * same-named peer on the broker.
     */
    ephemeral?: boolean;
}
export interface RpcChildExitEvent {
    code: number | null;
    signal: NodeJS.Signals | null;
    /** True when exit was not clean (non-zero or signal). */
    isCrash: boolean;
}
export declare const EXIT_DAEMON_FRESH_SESSION = 42;
/**
 * Resolve the `pi` executable for `spawn` (plan/40, decision C). On Windows a
 * bare `pi` is actually `pi.cmd`/`pi.ps1`, and `spawn` won't find it without an
 * extension → resolve the real path via `where` (rather than `shell:true`,
 * which risks shell injection). An explicit path or an already-suffixed name is
 * used as-is. POSIX returns the name unchanged. Best-effort: if `where` fails,
 * fall back to the bare name (spawn will surface ENOENT honestly).
 *
 * `where` lists every match in PATH order, which on pi-node installs puts the
 * extensionless `pi` (a shell script) BEFORE `pi.cmd`. Naively taking the first
 * line spawns the unrunnable script → ENOENT → "crashed". So we prefer a result
 * with a real Windows executable extension and only fall back to the first line.
 */
export declare function resolvePiBin(piBin: string, plat?: NodeJS.Platform): string;
/** What to pass to `spawn`: the executable and any args to prepend before the
 *  caller's args. On POSIX (and for `.exe`) `prefixArgs` is empty. */
export interface PiSpawnTarget {
    command: string;
    prefixArgs: string[];
}
/**
 * Resolve `pi` to a directly-spawnable target (plan/40). On Windows `pi` is an
 * npm `.cmd` shim, which modern Node refuses to `spawn` without `shell:true`
 * (EINVAL, post CVE-2024-27980). Wrapping it in `cmd.exe` would (a) add a layer
 * that orphans the real `node` on kill and (b) complicate stdio — both fatal for
 * a long-lived RPC daemon the supervisor must stop/restart cleanly. Instead we
 * parse the shim to recover the underlying `node <cli.js>` and spawn that
 * directly: one process, clean signals, clean stdio.
 *
 * Falls back to the bare resolved path when not a parseable shim (e.g. a real
 * `pi.exe`, or POSIX) so `spawn` surfaces any real error honestly.
 */
export declare function resolvePiSpawn(piBin: string, plat?: NodeJS.Platform, nodeExe?: string): PiSpawnTarget;
/**
 * Extract the JS entry an npm `.cmd` shim launches. npm shims invoke
 * `"%_prog%"  "%dp0%\<relative>\entry.js" %*`; we recover `<dir>\<relative>\entry.js`
 * (dir = the shim's own folder, i.e. `%dp0%`). Returns null when the shim
 * doesn't match the expected shape or the target is missing.
 */
export declare function _npmShimTarget(cmdPath: string): string | null;
/**
 * Maps an RPC stdout line to a busy-state transition: `message_start` → true
 * (a message is streaming), `message_end` → false. Other lines → null (no
 * change). Pure + exported for tests.
 *
 * NOTE (plan/39 detail 1): the Pi RPC stream has NO turn-level event — only
 * per-message start/end (and `response{command:"prompt"}` is emitted at
 * PREFLIGHT, i.e. turn START, not end). So this passive flag reflects
 * "a message is being produced right now"; the authoritative turn-busy signal
 * is `get_state.isStreaming` (see `RpcChild.refreshBusy`).
 */
export declare function busyTransition(line: string): boolean | null;
/** A notification the child sent on Pi's extension-UI channel.
 *
 * `ctx.ui.notify()` is how extension commands answer when they are not the TUI
 * (there it prints in the footer). The SDK marks it "fire and forget", so the
 * daemon is the only place that can carry it back out: nothing else in the
 * chain looks at the child's stdout. */
export interface RpcUiEvent {
    /** The request's own id (`crypto.randomUUID()` for a notify). */
    id?: string;
    method?: string;
    message?: string;
    notifyType?: "info" | "warning" | "error";
}
/**
 * Maps an RPC stdout line to an extension-UI event, or null. Only the fields a
 * consumer forwards are read; a malformed line is ignored like any other.
 *
 * `timeoutMs` is dropped on purpose: a notify needs no answer, and a dialog
 * request is the wrong thing to surface as a notification.
 */
export declare function parseUiEventLine(line: string): RpcUiEvent | null;
/** Parses an RPC `response` line into its id + the forwarded payload.
 *  Returns null for anything that isn't a response (events dominate the
 *  stream), so the id-correlation path stays cheap. */
export declare function parseResponseLine(line: string): {
    id?: string;
    response: RpcResponseWire;
} | null;
/**
 * CLI args for the daemon's `pi --mode rpc` child.
 *
 * `--continue` is the key bit: it resumes the **most recent** session for the
 * cwd (`SessionManager.continueRecent`, non-interactive — unlike `--resume`
 * which opens a picker). Without it every supervisor restart spun up a brand
 * new session file, piling up thousands of JSONLs per folder. With it, a
 * restart REUSES the one session; the app's `/new` (session_new) still rolls
 * it over to a fresh one, which the next restart then continues. First boot
 * (no prior session) just creates the first one.
 *
 * `--name <sessionName>`, when given, pins the session's display name to the
 * daemon's identity (its `agent_name`) so every restart shows up under the
 * same stable name in the picker/app instead of an auto-generated one. The
 * daemon's name is set at registration (`remote-pi create <cwd> --name "…"`).
 * Only a REAL configured name is pinned — a bare folder basename is the Pi's
 * default identity, and `--name` bakes it into the session file as a
 * `session_info` entry, which then masks the session's first-message title
 * in the app (picker and room labels show `name` over `firstMessage`).
 * Omitted when no real name resolves, so the arg list stays minimal.
 *
 * `--approve` is mandatory for a daemon (pi ≥0.79 project trust): RPC mode is
 * non-interactive, so without an override Pi resolves an untrusted project
 * folder (any folder with `.pi/` or CLAUDE.md/AGENTS.md) to NOT trusted and
 * silently skips its `.pi/settings.json` (model/provider/keys), instructions,
 * resources and project extensions — the daemon then comes up with no model
 * and fails on the first turn. The operator already authorized this folder by
 * registering/launching a daemon in it, so `--approve` (trust-for-this-run) is
 * the correct non-interactive stance. (Does NOT affect the separate "extension
 * loaded twice" conflict, which comes from the extension being BOTH installed
 * in ~/.pi/agent/extensions or cwd/.pi/extensions AND passed via `-e`.)
 */
export declare function rpcSpawnArgs(extensionPath: string, sessionName?: string, useContinue?: boolean): string[];
export declare class RpcChild extends EventEmitter {
    private readonly opts;
    private child;
    private _state;
    private _startedAt;
    private _restartCount;
    /** True while a deliberate `stop()` is in flight. The process dies by
     *  signal (SIGTERM/SIGKILL), which would otherwise look like a crash and
     *  trip the supervisor's auto-restart — re-spawning a daemon the operator
     *  just stopped/removed. Gating `isCrash` on this makes a deliberate stop a
     *  clean exit (no restart). Reset on every `spawn()`. */
    private _stopping;
    /** Next spawn should create a fresh session instead of --continue. */
    private forceFreshSessionOnNextSpawn;
    /** Accumulates partial stdout lines while waiting for `\n`. */
    private stdoutBuf;
    /** Passive busy flag derived from the RPC stream (message_start/end). Hint
     *  only; `refreshBusy` syncs it authoritatively via get_state.isStreaming. */
    private _busy;
    /** In-flight `get_state` requests, keyed by request id. */
    private readonly _statePending;
    /** In-flight awaited RPC commands, keyed by request id (see `awaitCommand`). */
    private readonly _commandPending;
    constructor(opts: RpcChildOptions);
    get state(): DaemonState;
    /** Passive busy hint from the stream. Prefer `refreshBusy()` for an
     *  authoritative check before acting on it (cron skip_if_busy). */
    get isBusy(): boolean;
    get pid(): number | undefined;
    get restartCount(): number;
    get uptimeMs(): number | undefined;
    /**
     * Spawn the child process. Idempotent for the same instance: a second
     * call while already running is a no-op.
     */
    spawn(): void;
    /**
     * Sends a Pi RPC `prompt` command to the child's stdin. Fire-and-forget
     * — we don't wait for the response (response would be the success ack;
     * the actual agent output streams via the relay/UDS, not back through
     * stdout).
     *
     * Returns false if the child isn't running (caller decides how to report).
     */
    sendPrompt(text: string, requestId?: string): boolean;
    /**
     * Sends any Pi RPC command to the child's stdin. Fire-and-forget; returns
     * false when the child isn't running. Use {@link awaitCommand} when the
     * caller needs the child's own answer (e.g. a command that may be rejected
     * by preflight).
     */
    sendCommand(command: RpcCommandWire, requestId?: string): boolean;
    /**
     * Sends a Pi RPC command and resolves with the matching `response` line
     * (correlated by the id we stamped). Resolves `null` on timeout, on a dead
     * child, or if the child exits first — callers treat "no answer" as
     * "delivered, unknown outcome" rather than a hard failure.
     */
    awaitCommand(command: RpcCommandWire, timeoutMs?: number): Promise<RpcResponseWire | null>;
    /**
     * Asks the child to exit gracefully. Sends SIGTERM; if the child doesn't
     * exit within `timeoutMs`, escalates to SIGKILL. Resolves when the
     * `exit` event fires.
     */
    stop(timeoutMs?: number): Promise<void>;
    private _onStdout;
    private _handleStdoutLine;
    /**
     * Authoritative busy check: queries the child's `get_state` and syncs
     * `_busy` to `isStreaming`. Resolves the passive flag on timeout (no
     * response) or when the child isn't running. Used by the cron `skip_if_busy`
     * gate, where a false "not busy" would pile a prompt onto a live turn.
     */
    refreshBusy(timeoutMs?: number): Promise<boolean>;
    /** Test-only: feed a raw stdout line through the same handler. */
    _ingestStdoutForTest(line: string): void;
    private _onExit;
    /** Bumps the restart counter — called by the supervisor when it
     *  decides to re-spawn after a crash. Exposed so tests can drive it. */
    noteRestart(): void;
}
