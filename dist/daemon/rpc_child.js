import { execFileSync, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { defaultAgentName, loadLocalConfig } from "../session/local_config.js";
export const EXIT_DAEMON_FRESH_SESSION = 42;
/** Windows extensions `spawn` (without `shell`) can actually launch, in
 *  preference order: native `.exe` first, then the `.cmd`/`.bat` shims (run via
 *  cmd.exe). An extensionless `pi` is a Unix shell script Node CANNOT spawn on
 *  Windows — picking it yields `spawn … ENOENT` and the daemon shows "crashed". */
const WIN_EXECUTABLE_EXTS = [".exe", ".cmd", ".bat", ".com"];
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
export function resolvePiBin(piBin, plat = process.platform) {
    if (plat !== "win32")
        return piBin;
    if (piBin.includes("\\") || piBin.includes("/") || /\.[a-z0-9]+$/i.test(piBin))
        return piBin;
    try {
        const out = execFileSync("where", [piBin], { encoding: "utf8" });
        const lines = out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
        const runnable = lines.find((l) => WIN_EXECUTABLE_EXTS.some((ext) => l.toLowerCase().endsWith(ext)));
        const chosen = runnable ?? lines[0];
        if (chosen)
            return chosen;
    }
    catch {
        /* `where` unavailable or `pi` not found — fall back to the bare name */
    }
    return piBin;
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
export function resolvePiSpawn(piBin, plat = process.platform, nodeExe = process.execPath) {
    const resolved = resolvePiBin(piBin, plat);
    if (plat !== "win32")
        return { command: resolved, prefixArgs: [] };
    if (/\.(cmd|bat)$/i.test(resolved)) {
        const target = _npmShimTarget(resolved);
        if (target)
            return { command: nodeExe, prefixArgs: [target] };
    }
    return { command: resolved, prefixArgs: [] };
}
/**
 * Extract the JS entry an npm `.cmd` shim launches. npm shims invoke
 * `"%_prog%"  "%dp0%\<relative>\entry.js" %*`; we recover `<dir>\<relative>\entry.js`
 * (dir = the shim's own folder, i.e. `%dp0%`). Returns null when the shim
 * doesn't match the expected shape or the target is missing.
 */
export function _npmShimTarget(cmdPath) {
    let content;
    try {
        content = readFileSync(cmdPath, "utf8");
    }
    catch {
        return null;
    }
    const m = content.match(/"%dp0%\\([^"]+\.[cm]?js)"/i);
    if (!m)
        return null;
    const target = join(dirname(cmdPath), m[1]);
    return existsSync(target) ? target : null;
}
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
export function busyTransition(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch {
        return null;
    }
    const t = obj?.type;
    if (t === "message_start")
        return true;
    if (t === "message_end")
        return false;
    return null;
}
/**
 * Maps an RPC stdout line to an extension-UI event, or null. Only the fields a
 * consumer forwards are read; a malformed line is ignored like any other.
 *
 * `timeoutMs` is dropped on purpose: a notify needs no answer, and a dialog
 * request is the wrong thing to surface as a notification.
 */
export function parseUiEventLine(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch {
        return null;
    }
    const o = obj;
    if (o.type !== "extension_ui_request")
        return null;
    const ev = {};
    if (typeof o.id === "string")
        ev.id = o.id;
    if (typeof o.method === "string")
        ev.method = o.method;
    if (typeof o.message === "string")
        ev.message = o.message;
    if (o.notifyType === "info" || o.notifyType === "warning" || o.notifyType === "error") {
        ev.notifyType = o.notifyType;
    }
    return ev;
}
/** Parses an RPC `response` line into its id + the forwarded payload.
 *  Returns null for anything that isn't a response (events dominate the
 *  stream), so the id-correlation path stays cheap. */
export function parseResponseLine(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch {
        return null;
    }
    const o = obj;
    if (o.type !== "response")
        return null;
    const response = {};
    if (typeof o.command === "string")
        response.command = o.command;
    if (typeof o.success === "boolean")
        response.success = o.success;
    if (o.data !== undefined)
        response.data = o.data;
    if (typeof o.error === "string")
        response.error = o.error;
    return { id: typeof o.id === "string" ? o.id : undefined, response };
}
/** Parses a `get_state` RPC response line, returning its id + isStreaming. */
function parseGetStateResponse(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch {
        return null;
    }
    const o = obj;
    if (o.type !== "response" || o.command !== "get_state")
        return null;
    const data = o.data;
    return {
        id: typeof o.id === "string" ? o.id : undefined,
        isStreaming: typeof data?.isStreaming === "boolean" ? data.isStreaming : undefined,
    };
}
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
export function rpcSpawnArgs(extensionPath, sessionName, useContinue = true) {
    return [
        "--mode", "rpc",
        "--approve",
        ...(useContinue ? ["--continue"] : []),
        ...(sessionName ? ["--name", sessionName] : []),
        "-e", extensionPath,
    ];
}
export class RpcChild extends EventEmitter {
    opts;
    child = null;
    _state = "stopped";
    _startedAt = null;
    _restartCount = 0;
    /** True while a deliberate `stop()` is in flight. The process dies by
     *  signal (SIGTERM/SIGKILL), which would otherwise look like a crash and
     *  trip the supervisor's auto-restart — re-spawning a daemon the operator
     *  just stopped/removed. Gating `isCrash` on this makes a deliberate stop a
     *  clean exit (no restart). Reset on every `spawn()`. */
    _stopping = false;
    /** Next spawn should create a fresh session instead of --continue. */
    forceFreshSessionOnNextSpawn = false;
    /** Accumulates partial stdout lines while waiting for `\n`. */
    stdoutBuf = "";
    /** Passive busy flag derived from the RPC stream (message_start/end). Hint
     *  only; `refreshBusy` syncs it authoritatively via get_state.isStreaming. */
    _busy = false;
    /** In-flight `get_state` requests, keyed by request id. */
    _statePending = new Map();
    /** In-flight awaited RPC commands, keyed by request id (see `awaitCommand`). */
    _commandPending = new Map();
    constructor(opts) {
        super();
        this.opts = opts;
    }
    get state() { return this._state; }
    /** Passive busy hint from the stream. Prefer `refreshBusy()` for an
     *  authoritative check before acting on it (cron skip_if_busy). */
    get isBusy() { return this._busy; }
    get pid() { return this.child?.pid; }
    get restartCount() { return this._restartCount; }
    get uptimeMs() {
        return this._startedAt !== null ? Date.now() - this._startedAt : undefined;
    }
    /**
     * Spawn the child process. Idempotent for the same instance: a second
     * call while already running is a no-op.
     */
    spawn() {
        if (this.child)
            return;
        this._stopping = false; // fresh start — a later signal IS a real crash
        this._busy = false;
        this._state = "starting";
        const piTarget = resolvePiSpawn(this.opts.piBin ?? "pi");
        // Name the (single) daemon session after the daemon's configured
        // identity — but ONLY when a real agent name was configured (see the
        // `--name` note above: a bare folder basename must not be baked into
        // the session file). Prefer the supervisor-injected config; fall back
        // to the on-disk file.
        const cfg = this.opts.config ?? loadLocalConfig(this.opts.cwd);
        const sessionName = cfg.agent_name && cfg.agent_name !== defaultAgentName(this.opts.cwd)
            ? cfg.agent_name
            : undefined;
        const useContinue = !this.forceFreshSessionOnNextSpawn && !this.opts.freshSession;
        this.forceFreshSessionOnNextSpawn = false;
        // On Windows `prefixArgs` carries pi's cli.js (we spawn node directly); on
        // POSIX it's empty and `command` is `pi` itself.
        const args = [...piTarget.prefixArgs, ...rpcSpawnArgs(this.opts.extensionPath, sessionName, useContinue)];
        const env = {
            ...process.env,
            ...this.opts.env,
            // Mandatory daemon marker — `_cmdRoot` in index.ts can use this to
            // bail early if local config is missing (no wizard in RPC mode).
            REMOTE_PI_DAEMON: "1",
            // Phone room: no daemon singleton lock semantics (see
            // RpcChildOptions.ephemeral) — the lock may auto-suffix.
            ...(this.opts.ephemeral ? { REMOTE_PI_EPHEMERAL: "1" } : {}),
            // Inject the daemon config inline so the child needs no config file.
            ...(this.opts.config ? { REMOTE_PI_DIRECT_CONFIG: JSON.stringify(this.opts.config) } : {}),
        };
        const child = spawn(piTarget.command, args, {
            cwd: this.opts.cwd,
            env,
            stdio: ["pipe", "pipe", "pipe"],
            // Windows: suppress any console window the child might allocate. With the
            // node+cli.js path (resolvePiSpawn) there's no cmd.exe layer, but keep this
            // as belt-and-suspenders alongside the supervisor's hidden wscript launcher
            // (service-templates/task-launcher.vbs.template). No-op on POSIX.
            windowsHide: process.platform === "win32",
        });
        this.child = child;
        this._startedAt = Date.now();
        this._state = "running";
        child.stdout?.on("data", (chunk) => this._onStdout(chunk));
        child.stderr?.on("data", (chunk) => {
            // Forward stderr to our own stderr so `journalctl --user -u remote-pi-supervisord`
            // sees daemon logs (with cwd prefix for disambiguation).
            process.stderr.write(`[${this.opts.cwd}] ${chunk.toString()}`);
        });
        child.on("exit", (code, signal) => this._onExit(code, signal));
        child.on("error", (err) => {
            // spawn() itself failed (e.g. `pi` binary not found).
            this._state = "crashed";
            process.stderr.write(`[remote-pi-supervisord] spawn failed for ${this.opts.cwd}: ${String(err)}\n`);
            this.emit("exit", { code: null, signal: null, isCrash: true });
        });
        this.emit("spawn", { pid: child.pid });
    }
    /**
     * Sends a Pi RPC `prompt` command to the child's stdin. Fire-and-forget
     * — we don't wait for the response (response would be the success ack;
     * the actual agent output streams via the relay/UDS, not back through
     * stdout).
     *
     * Returns false if the child isn't running (caller decides how to report).
     */
    sendPrompt(text, requestId) {
        return this.sendCommand({ type: "prompt", message: text }, requestId);
    }
    /**
     * Sends any Pi RPC command to the child's stdin. Fire-and-forget; returns
     * false when the child isn't running. Use {@link awaitCommand} when the
     * caller needs the child's own answer (e.g. a command that may be rejected
     * by preflight).
     */
    sendCommand(command, requestId) {
        if (!this.child || !this.child.stdin || this._state !== "running")
            return false;
        const id = requestId ?? `sv-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
        try {
            this.child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
            return true;
        }
        catch {
            return false;
        }
    }
    /**
     * Sends a Pi RPC command and resolves with the matching `response` line
     * (correlated by the id we stamped). Resolves `null` on timeout, on a dead
     * child, or if the child exits first — callers treat "no answer" as
     * "delivered, unknown outcome" rather than a hard failure.
     */
    async awaitCommand(command, timeoutMs = 5000) {
        if (!this.child || !this.child.stdin || this._state !== "running")
            return null;
        const id = `sv-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this._commandPending.delete(id);
                resolve(null);
            }, timeoutMs);
            this._commandPending.set(id, {
                resolve: (res) => { clearTimeout(timer); resolve(res); },
            });
            try {
                this.child.stdin.write(JSON.stringify({ id, ...command }) + "\n");
            }
            catch {
                clearTimeout(timer);
                this._commandPending.delete(id);
                resolve(null);
            }
        });
    }
    /**
     * Asks the child to exit gracefully. Sends SIGTERM; if the child doesn't
     * exit within `timeoutMs`, escalates to SIGKILL. Resolves when the
     * `exit` event fires.
     */
    async stop(timeoutMs = 5000) {
        if (!this.child)
            return;
        this._stopping = true; // deliberate — the upcoming signal-exit is NOT a crash
        const child = this.child;
        return new Promise((resolve) => {
            const onExit = () => { resolve(); };
            this.once("exit", onExit);
            try {
                child.kill("SIGTERM");
            }
            catch { /* already dead */ }
            const t = setTimeout(() => {
                try {
                    child.kill("SIGKILL");
                }
                catch { /* race — already dead */ }
            }, timeoutMs);
            this.once("exit", () => clearTimeout(t));
        });
    }
    _onStdout(chunk) {
        this.stdoutBuf += chunk.toString();
        let nl;
        while ((nl = this.stdoutBuf.indexOf("\n")) >= 0) {
            const line = this.stdoutBuf.slice(0, nl);
            this.stdoutBuf = this.stdoutBuf.slice(nl + 1);
            if (!line.trim())
                continue;
            this._handleStdoutLine(line);
        }
    }
    _handleStdoutLine(line) {
        const t = busyTransition(line);
        if (t !== null)
            this._busy = t;
        const gs = parseGetStateResponse(line);
        if (gs && gs.id) {
            const pending = this._statePending.get(gs.id);
            if (pending) {
                clearTimeout(pending.timer);
                this._statePending.delete(gs.id);
                if (typeof gs.isStreaming === "boolean")
                    this._busy = gs.isStreaming;
                pending.resolve(this._busy);
            }
        }
        const resp = parseResponseLine(line);
        if (resp && resp.id) {
            const pending = this._commandPending.get(resp.id);
            if (pending) {
                this._commandPending.delete(resp.id);
                pending.resolve(resp.response);
            }
        }
        // The child's side of Pi's extension-UI channel rides the same stream:
        // consumers that care (the supervisor's stdout bridge) get it as a second
        // argument, everyone else keeps ignoring it.
        this.emit("stdout", line, parseUiEventLine(line) ?? undefined);
    }
    /**
     * Authoritative busy check: queries the child's `get_state` and syncs
     * `_busy` to `isStreaming`. Resolves the passive flag on timeout (no
     * response) or when the child isn't running. Used by the cron `skip_if_busy`
     * gate, where a false "not busy" would pile a prompt onto a live turn.
     */
    async refreshBusy(timeoutMs = 1500) {
        if (this._state !== "running" || !this.child?.stdin)
            return this._busy;
        const id = `gs-${Date.now()}-${Math.round(Math.random() * 1e6)}`;
        return new Promise((resolve) => {
            const timer = setTimeout(() => {
                this._statePending.delete(id);
                resolve(this._busy);
            }, timeoutMs);
            this._statePending.set(id, { resolve, timer });
            try {
                this.child.stdin.write(JSON.stringify({ id, type: "get_state" }) + "\n");
            }
            catch {
                clearTimeout(timer);
                this._statePending.delete(id);
                resolve(this._busy);
            }
        });
    }
    /** Test-only: feed a raw stdout line through the same handler. */
    _ingestStdoutForTest(line) {
        this._handleStdoutLine(line);
    }
    _onExit(code, signal) {
        // Daemon app-action `/new`: child exits with a private code, supervisor
        // restarts it, and the next spawn omits --continue once to create a fresh
        // session. Later restarts go back to --continue.
        if (code === EXIT_DAEMON_FRESH_SESSION)
            this.forceFreshSessionOnNextSpawn = true;
        // A deliberate stop() kills by signal — not a crash, so the supervisor
        // must NOT auto-restart it. Only an UNexpected exit counts as a crash.
        const isCrash = !this._stopping && (code !== 0 || signal !== null);
        this._state = isCrash ? "crashed" : "stopped";
        this.child = null;
        this._startedAt = null;
        this._busy = false;
        for (const p of this._statePending.values()) {
            clearTimeout(p.timer);
            p.resolve(false);
        }
        this._statePending.clear();
        for (const p of this._commandPending.values())
            p.resolve(null);
        this._commandPending.clear();
        this.emit("exit", { code, signal, isCrash });
    }
    /** Bumps the restart counter — called by the supervisor when it
     *  decides to re-spawn after a crash. Exposed so tests can drive it. */
    noteRestart() {
        this._restartCount += 1;
    }
}
//# sourceMappingURL=rpc_child.js.map