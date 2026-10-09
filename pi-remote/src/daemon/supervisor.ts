import { existsSync, mkdirSync, unlinkSync } from "node:fs";
import { createConnection, createServer, type Server, type Socket } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { addDaemon, listDaemons, migrateRegistryNames, normalizeCwd, removeDaemon } from "./registry.js";
import { daemonIdForCwd } from "./id.js";
import { roomIdFor } from "../rooms.js";
import { defaultAgentName, migrateAgentName, type LocalConfig } from "../session/local_config.js";
import { ipcAddress, usesNamedPipe } from "../session/ipc.js";
import { EXIT_DAEMON_FRESH_SESSION, RpcChild, type RpcChildExitEvent, type RpcChildOptions, type RpcUiEvent } from "./rpc_child.js";
import {
  type ControlReply,
  type ControlRequest,
  type CronJobView,
  type DaemonInfo,
  type RpcCommandWire,
  encodeReply,
  parseRequest,
} from "./control_protocol.js";
import { Cron } from "croner";
import {
  addJob as addCronJob,
  getJob as getCronJob,
  listJobs as listCronJobs,
  nextRunFor,
  recordRun,
  removeJob as removeCronJob,
  setJobEnabled,
  validateSchedule,
  type CronJob,
  type NewJobInput,
} from "./cron_registry.js";
import { appendCronLog, readCronLog, type CronResult } from "./cron_log.js";

/**
 * Central process that owns the daemon fleet (plan/26).
 *
 * Responsibilities:
 *   - Spawn one `pi --mode rpc` child per registry entry. Track them in
 *     `_children: Map<id, RpcChild>`.
 *   - Auto-restart crashed children with exponential backoff
 *     (1s, 5s, 30s, 5min). Give up after 4 attempts to avoid log spam
 *     when the agent is misconfigured.
 *   - Listen on `~/.pi/remote/supervisor.sock` for `ControlRequest`s from
 *     the `remote-pi` CLI. Each connection: 1 request → 1 reply → close.
 *   - Graceful shutdown on SIGTERM/SIGINT: stop all children + unlink
 *     the UDS file so a next supervisor can bind cleanly.
 *
 * The supervisor itself is the only long-running process the user
 * installs as a system service (plan/26 W3 will generate the unit/plist).
 * If it crashes, systemd/launchd restarts it; on restart it re-reads
 * the registry and re-spawns everything.
 */

const SUPERVISOR_SOCK_NAME = "supervisor.sock";

/** Backoff schedule for auto-restart after a crash. After exhausting, the
 *  child stays in `crashed` state until manual `restart_all` or fresh
 *  registry add. Keeps logs sane when the agent dies on every boot. */
const RESTART_BACKOFFS_MS = [1_000, 5_000, 30_000, 5 * 60_000];

/**
 * Pi RPC verbs the supervisor forwards through `op: "rpc"`.
 *
 * Allow-list rather than deny-list on purpose: this is a remote-controlled
 * door into a live agent process, so a caller bug must not be able to reach
 * verbs nobody vetted. Every verb here is either session inspection or a
 * session-shaping action the mobile app already exposes elsewhere. Long-running
 * verbs (`bash`) are deliberately absent — they need a streaming channel, not a
 * request/response round-trip.
 */
const RPC_PASSTHROUGH: ReadonlySet<string> = new Set([
  "prompt",
  "compact",
  "new_session",
  "clone",
  "set_session_name",
  // Session picker (plan/59): the daemon continues a different stored
  // session for the same cwd. Session-shaping like `new_session`; the
  // child answers at preflight.
  "switch_session",
  "get_state",
  "get_commands",
  "get_session_stats",
]);

/** How long `op: "rpc"` waits for the child's `response` line by default.
 *  Every allowed verb answers at preflight (the agent's own output streams on
 *  the relay), so a few seconds is generous. */
const RPC_DEFAULT_TIMEOUT_MS = 4_000;
const RPC_MAX_TIMEOUT_MS = 30_000;

function supervisorSockPath(): string {
  const root = process.env["REMOTE_PI_HOME"] || homedir();
  // POSIX → ~/.pi/remote/supervisor.sock; Windows → per-user named pipe (plan/40).
  return ipcAddress("supervisor", join(root, ".pi", "remote", SUPERVISOR_SOCK_NAME));
}

/** Thrown by `start()` when another live supervisor already holds the UDS.
 *  Prevents a second supervisor from orphaning the first's children. */
export class SupervisorAlreadyRunningError extends Error {
  constructor(public readonly sockPath: string) {
    super(
      `Another pi-supervisord is already running (UDS held at ${sockPath}). ` +
      "Refusing to start a second instance. Use `remote-pi daemon …` to control it, " +
      "or stop the running one first.",
    );
    this.name = "SupervisorAlreadyRunningError";
  }
}

/** Probes whether a live supervisor is accepting connections on `path`.
 *  Resolves true if the connect succeeds (a listener is there), false on
 *  ECONNREFUSED / ENOENT (stale socket file from a crashed supervisor). */
function _probeSupervisor(path: string): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const sock = createConnection({ path });
    const done = (alive: boolean) => {
      sock.removeAllListeners();
      sock.destroy();
      resolve(alive);
    };
    const timer = setTimeout(() => done(false), 1_000);
    sock.once("connect", () => { clearTimeout(timer); done(true); });
    sock.once("error", () => { clearTimeout(timer); done(false); });
  });
}

export interface SupervisorOptions {
  /** Absolute path to remote-pi's dist/index.js — passed as -e to each
   *  spawned `pi`. Defaults to the location relative to where this file
   *  is bundled (so the supervisor finds itself). */
  extensionPath: string;
  /** Override the `pi` binary path. Defaults to "pi" on PATH. */
  piBin?: string;
}

/** Pure decision for `fireJob` (plan/39) — picks the action from the daemon's
 *  liveness/busy state + the job's flags. Tested in isolation for all 4 ramos. */
export type FireAction = "send" | "wake_and_send" | "skip_down" | "skip_busy";
export function decideFireAction(o: {
  running: boolean;
  busy: boolean;
  wake: boolean;
  skipIfBusy: boolean;
}): FireAction {
  if (!o.running) return o.wake ? "wake_and_send" : "skip_down";
  if (o.skipIfBusy && o.busy) return "skip_busy";
  return "send";
}

interface ChildSlot {
  id: string;
  cwd: string;
  child: RpcChild;
  restartTimer: ReturnType<typeof setTimeout> | null;
  restartAttempt: number;
  /** Phone-created (forked) room: not in the daemon registry, never
   *  auto-restarted, absent from `list`/`status`. */
  ephemeral?: boolean;
  /** The agent name this child came up as — used to find an ephemeral slot
   *  by (cwd, name) when its announced suffix differs from the predicted
   *  one (the cwd lock may pick a neighbouring `#N`). */
  name?: string;
}

export class Supervisor {
  private server: Server | null = null;
  private readonly children = new Map<string, ChildSlot>();
  /** Live croner schedules, keyed by cron job id (plan/39). */
  private readonly cronJobs = new Map<string, Cron>();
  /** Ephemeral (phone-created) rooms, keyed by their relay room_id.
   *  NEVER in the daemon registry (`daemons.json`) and never in `list` —
   *  the phone's create/delete never touches the manual daemon config. */
  private readonly ephemeral = new Map<string, ChildSlot>();
  private shuttingDown = false;

  constructor(private readonly opts: SupervisorOptions) {}

  /** Bind the control UDS + spawn all registered daemons. */
  async start(): Promise<void> {
    this._mkdirParent();
    // Backfill folder-derived names into legacy registry entries (pre-name
    // field) so every daemon has a stable name to inject via env.
    migrateRegistryNames();
    await this._bindUds();
    this._spawnAllFromRegistry();
    // Cron (plan/39): schedule all enabled jobs, then run any missed catchup.
    this._reconcileCron();
    this._runCatchup();
  }

  /** Graceful shutdown: stop all children, close UDS. */
  async stop(): Promise<void> {
    this.shuttingDown = true;
    // Stop all cron schedules (plan/39) so no fire races with teardown.
    for (const c of this.cronJobs.values()) c.stop();
    this.cronJobs.clear();
    // Ephemeral (phone) rooms die with the supervisor — no registry to
    // re-spawn them from.
    await Promise.all([...this.ephemeral.values()].map((s) => s.child.stop()));
    this.ephemeral.clear();
    // Cancel pending restart timers first so they don't race with stop().
    for (const slot of this.children.values()) {
      if (slot.restartTimer !== null) {
        clearTimeout(slot.restartTimer);
        slot.restartTimer = null;
      }
    }
    await Promise.all([...this.children.values()].map((s) => s.child.stop()));
    this.children.clear();
    await new Promise<void>((resolve) => {
      if (!this.server) return resolve();
      this.server.close(() => resolve());
    });
    this.server = null;
    // Best-effort: clear the socket file so a next supervisor bind succeeds.
    // Windows named pipes have no file (auto-removed on exit) → nothing to do.
    if (!usesNamedPipe()) {
      try { unlinkSync(supervisorSockPath()); } catch { /* ignored */ }
    }
  }

  // ── UDS binding ──────────────────────────────────────────────────────────

  private _mkdirParent(): void {
    // A named pipe has no parent directory to create (the addr is `\\.\pipe\…`).
    if (usesNamedPipe()) return;
    mkdirSync(dirname(supervisorSockPath()), { recursive: true });
  }

  private async _bindUds(): Promise<void> {
    const path = supervisorSockPath();
    const pipe = usesNamedPipe();
    // Single-instance guard. PROBE first: a live supervisor answering the
    // connect means we must NOT start a second one. Stealing the socket
    // (unlink + bind) would orphan the running supervisor's children — they'd
    // keep running, unreachable by the CLI. Only on POSIX, when the probe
    // fails (stale socket from a crash), do we unlink + bind. On Windows there
    // is no file: always probe, never unlink (the pipe self-cleans on exit).
    if (pipe || existsSync(path)) {
      const alive = await _probeSupervisor(path);
      if (alive) {
        throw new SupervisorAlreadyRunningError(path);
      }
      if (!pipe) {
        try { unlinkSync(path); } catch { /* will throw on bind if still held */ }
      }
    }
    const server = createServer((socket) => this._onConnection(socket));
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(path, () => resolve());
    });
    this.server = server;
  }

  private _onConnection(socket: Socket): void {
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl < 0) return;
      const line = buf.slice(0, nl);
      // Single request per connection; ignore anything past the newline.
      void this._handleRequest(line)
        .then((reply) => socket.end(encodeReply(reply)))
        .catch((err) => socket.end(encodeReply<unknown>({ ok: false, error: String(err) })));
    });
    socket.on("error", () => { /* client hung up; nothing to do */ });
  }

  // ── Request dispatch ─────────────────────────────────────────────────────

  private async _handleRequest(line: string): Promise<ControlReply<unknown>> {
    let req: ControlRequest;
    try { req = parseRequest(line); }
    catch (e) { return { ok: false, error: (e as Error).message }; }

    switch (req.op) {
      case "list":         return { ok: true, data: { daemons: this._listInfo() } };
      case "status":       return { ok: true, data: { daemons: this._listInfo() } };
      case "start_all":    return this._opStartAll();
      case "start":        return this._opStart(req.id);
      case "stop_all":     return this._opStopAll();
      case "stop":         return this._opStop(req.id);
      case "restart_all":  return this._opRestartAll();
      case "restart":      return this._opRestart(req.id);
      case "send":         return this._opSend(req.id, req.text);
      case "rpc":          return this._opRpc(req.id, req.command, req.timeout_ms);
      case "register":     return this._opRegister(req.cwd);
      case "unregister":   return this._opUnregister(req.id);
      case "spawn":        return this._opSpawn(req);
      case "kill":         return this._opKill(req);
      case "cron_add":     return this._opCronAdd(req);
      case "cron_list":    return this._opCronList();
      case "cron_remove":  return this._opCronRemove(req.job_id);
      case "cron_enable":  return this._opCronEnable(req.job_id, req.enabled);
      case "cron_run":     return this._opCronRun(req.job_id);
      case "cron_log":     return this._opCronLog(req.job_id, req.tail);
      default: {
        const unknown = (req as { op: string }).op;
        return { ok: false, error: `unknown op: ${unknown}` };
      }
    }
  }

  // ── Op handlers ──────────────────────────────────────────────────────────

  private _listInfo(): DaemonInfo[] {
    const registry = listDaemons();
    return registry.map((entry) => {
      const slot = this.children.get(entry.id);
      const name = entry.name ?? defaultAgentName(entry.cwd);
      const info: DaemonInfo = {
        id: entry.id,
        cwd: entry.cwd,
        name,
        state: slot?.child.state ?? "stopped",
      };
      if (slot) {
        if (slot.child.pid !== undefined) info.pid = slot.child.pid;
        if (slot.child.uptimeMs !== undefined) info.uptime_s = Math.floor(slot.child.uptimeMs / 1000);
        info.restart_count = slot.child.restartCount;
      }
      return info;
    });
  }

  private _opStartAll(): ControlReply<unknown> {
    const started: string[] = [];
    const already: string[] = [];
    for (const entry of listDaemons()) {
      const slot = this.children.get(entry.id);
      if (slot && slot.child.state === "running") {
        already.push(entry.id);
        continue;
      }
      this._spawnEntry(entry.id, entry.cwd);
      started.push(entry.id);
    }
    return { ok: true, data: { started, already_running: already } };
  }

  /** Spawn a single registered daemon by id. Idempotent: a daemon already
   *  running returns `started: false`. Unknown id → ok:false. This is what
   *  `/remote-pi create` calls so a freshly-registered folder boots its Pi
   *  immediately instead of waiting for the next supervisor restart. */
  private _opStart(id: string): ControlReply<unknown> {
    const entry = listDaemons().find((d) => d.id === id);
    if (!entry) return { ok: false, error: `no daemon with id ${id}` };
    const slot = this.children.get(id);
    if (slot && slot.child.state === "running") {
      return { ok: true, data: { id, state: slot.child.state, started: false } };
    }
    this._spawnEntry(entry.id, entry.cwd, entry.name);
    const state = this.children.get(id)?.child.state ?? "starting";
    return { ok: true, data: { id, state, started: true } };
  }

  private async _opStopAll(): Promise<ControlReply<unknown>> {
    const stopped: string[] = [];
    const already: string[] = [];
    for (const [id, slot] of this.children) {
      if (slot.child.state !== "running") {
        already.push(id);
        continue;
      }
      if (slot.restartTimer !== null) {
        clearTimeout(slot.restartTimer);
        slot.restartTimer = null;
      }
      await slot.child.stop();
      stopped.push(id);
    }
    // Ephemeral (phone) rooms go down too — they ride the same stop path but
    // never appear in the daemon bookkeeping.
    for (const [roomId, slot] of this.ephemeral) {
      if (slot.child.state === "running") {
        await slot.child.stop();
        this.ephemeral.delete(roomId);
      }
    }
    return { ok: true, data: { stopped, already_stopped: already } };
  }

  /** Stop a single registered daemon by id. Idempotent: a daemon that isn't
   *  running returns `stopped: false`. Unknown id → ok:false. Mirrors the
   *  per-id semantics of `_opStart`. Cancels any pending restart backoff so a
   *  deliberate stop stays stopped. */
  private async _opStop(id: string): Promise<ControlReply<unknown>> {
    const entry = listDaemons().find((d) => d.id === id);
    if (!entry) return { ok: false, error: `no daemon with id ${id}` };
    const slot = this.children.get(id);
    if (!slot || slot.child.state !== "running") {
      return { ok: true, data: { id, state: slot?.child.state ?? "stopped", stopped: false } };
    }
    if (slot.restartTimer !== null) {
      clearTimeout(slot.restartTimer);
      slot.restartTimer = null;
    }
    await slot.child.stop();
    return { ok: true, data: { id, state: slot.child.state, stopped: true } };
  }

  /** Restart a single registered daemon by id (stop-if-running, then spawn).
   *  Unknown id → ok:false. Resets the crash backoff. */
  private async _opRestart(id: string): Promise<ControlReply<unknown>> {
    const entry = listDaemons().find((d) => d.id === id);
    if (!entry) return { ok: false, error: `no daemon with id ${id}` };
    const slot = this.children.get(id);
    if (slot && slot.child.state === "running") {
      if (slot.restartTimer !== null) {
        clearTimeout(slot.restartTimer);
        slot.restartTimer = null;
      }
      await slot.child.stop();
    }
    this._spawnEntry(entry.id, entry.cwd, entry.name);
    const state = this.children.get(id)?.child.state ?? "starting";
    return { ok: true, data: { id, state, restarted: true } };
  }

  private async _opRestartAll(): Promise<ControlReply<unknown>> {
    const stopReply = await this._opStopAll();
    if (!stopReply.ok) return stopReply;
    const startReply = this._opStartAll();
    if (!startReply.ok) return startReply;
    const restarted = (startReply.data as { started: string[] }).started;
    return { ok: true, data: { restarted } };
  }

  private _opSend(id: string, text: string): ControlReply<unknown> {
    const slot = this.children.get(id);
    if (!slot) return { ok: false, error: `daemon ${id} not running` };
    if (slot.child.state !== "running") {
      return { ok: false, error: `daemon ${id} state is ${slot.child.state}` };
    }
    const ok = slot.child.sendPrompt(text);
    return { ok: true, data: { id, delivered: ok } };
  }

  /**
   * Forwards one Pi RPC command to a daemon's stdin and (by default) waits for
   * the child's matching `response` line, so a rejection (unknown RPC type,
   * preflight failure such as "no model selected") travels back to the caller
   * as real text instead of a silent no-op.
   *
   * `RPC_PASSTHROUGH` is the whole authority model here: the supervisor only
   * forwards commands on that list, so a bug in one caller cannot reach
   * destructive RPC verbs (e.g. exit paths) through this door. Long-running
   * commands are intentionally absent — they belong on a streaming channel,
   * not on a request/response round-trip.
   */
  private async _opRpc(
    id: string,
    command: RpcCommandWire,
    timeoutMs?: number,
  ): Promise<ControlReply<unknown>> {
    const type = typeof command?.type === "string" ? command.type : "";
    if (!RPC_PASSTHROUGH.has(type)) {
      return { ok: false, error: `rpc command not allowed: ${type || "(missing type)"}` };
    }
    const slot = this.children.get(id);
    if (!slot) return { ok: false, error: `daemon ${id} not running` };
    if (slot.child.state !== "running") {
      return { ok: false, error: `daemon ${id} state is ${slot.child.state}` };
    }
    const wait = Math.min(Math.max(timeoutMs ?? RPC_DEFAULT_TIMEOUT_MS, 100), RPC_MAX_TIMEOUT_MS);
    if (command.await === false) {
      const delivered = slot.child.sendCommand(command);
      return { ok: true, data: { id, delivered } };
    }
    const response = await slot.child.awaitCommand(command, wait);
    return {
      ok: true,
      data: response === null ? { id, delivered: true } : { id, delivered: true, response },
    };
  }

  private _opRegister(rawCwd: string): ControlReply<unknown> {
    try {
      const { id, cwd } = addDaemon(rawCwd);
      return { ok: true, data: { id, cwd } };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  // ── Ephemeral (phone-created) rooms ───────────────────────────────────────
  //
  // The phone's "new room" / "fork room" NEVER touches the daemon registry
  // (`~/.pi/remote/daemons.json`) — that config is manual-only (terminal /
  // config file). Instead the supervisor boots a throwaway `pi --mode rpc`
  // child: a BRAND-NEW session (no `--continue`), announced on the relay as
  // its own room `(cwd, name)`, dropped from bookkeeping the moment it
  // exits — no auto-restart, no registry entry, absent from `list`.

  /**
   * Guard against relay room_id collisions: a RUNNING daemon in the same
   * cwd whose name equals the requested one already holds that room on the
   * relay — the relay would reject the ephemeral's hello and the room would
   * never appear. Step to the next `#N` in that case. A STOPPED daemon
   * holds no room, so the name may be reused.
   */
  private _resolveEphemeralName(cwd: string, requested: string): string {
    // Collect the names of ALL running daemons in this cwd (including
    // #N-named ones). If the requested name collides with any of them,
    // bump past the whole set.
    const running = new Set<string>();
    for (const [id, slot] of this.children) {
      if (slot.child.state !== "running") continue;
      const entry = listDaemons().find((d) => d.id === id);
      if (entry && entry.cwd === cwd) running.add(entry.name);
    }
    if (!running.has(requested)) return requested;
    // Step to the next free #N of the requested base.
    const base = requested.replace(/#\d+$/, "");
    for (let n = 2; ; n += 1) {
      const candidate = `${base}#${n}`;
      if (!running.has(candidate)) return candidate;
    }
  }

  private _opSpawn(req: Extract<ControlRequest, { op: "spawn" }>): ControlReply<unknown> {
    let cwd: string;
    try {
      cwd = normalizeCwd(req.cwd);
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
    const requested = req.name?.trim() || defaultAgentName(cwd);
    const name = this._resolveEphemeralName(cwd, requested);
    process.stderr.write(
      `[remote-pi-supervisord] spawn cwd=${cwd} requested=${requested} -> ${name}\n`,
    );
    const roomId = roomIdFor(cwd, name);
    const existing = this.ephemeral.get(roomId);
    if (existing && existing.child.state === "running") {
      // Idempotent: the same (cwd, name) room is already live.
      return { ok: true, data: { room_id: roomId, started: false, name } };
    }
    this._spawnEphemeral(roomId, cwd, name);
    return { ok: true, data: { room_id: roomId, started: true, name } };
  }

  /**
   * Stop + drop the ephemeral child holding relay room `room_id`.
   * Idempotent: an unknown room_id (already dead / a daemon room) is
   * `killed: false`, not an error.
   */
  private async _opKill(req: Extract<ControlRequest, { op: "kill" }>): Promise<ControlReply<unknown>> {
    // Prefer the exact room_id; fall back to (cwd, name) because the child's
    // cwd lock may have acquired a neighbouring `#N` (the announced room id
    // then differs from the predicted one).
    let slot = this.ephemeral.get(req.room_id);
    if (!slot && req.cwd !== undefined && req.name !== undefined) {
      for (const s of this.ephemeral.values()) {
        if (s.cwd === req.cwd && s.name === req.name) {
          slot = s;
          break;
        }
      }
    }
    if (!slot) return { ok: true, data: { killed: false } };
    if (slot.child.state === "running") await slot.child.stop();
    this.ephemeral.delete(slot.id);
    return { ok: true, data: { killed: true } };
  }

  private _spawnEphemeral(roomId: string, cwd: string, name: string): void {
    // Replace a stale slot (e.g. a starting child that is about to be
    // superseded) — stop it best-effort first.
    const existing = this.ephemeral.get(roomId);
    if (existing && existing.child.state === "running") void existing.child.stop();

    // `agent_name` carries the BASE name only: the extension's config parser
    // migrates a `#N` suffix away on read (it is a runtime cwd-lock artefact,
    // never a user choice — see migrateAgentName), and with
    // `REMOTE_PI_EPHEMERAL=1` the lock then re-derives the suffix itself
    // (`fenlyin` → `fenlyin#2`), which is the name the app computed too.
    const config: LocalConfig = {
      agent_name: migrateAgentName(name) ?? defaultAgentName(cwd),
      auto_start_relay: true,
    };
    const childOpts: RpcChildOptions = {
      extensionPath: this.opts.extensionPath,
      cwd,
      config,
      freshSession: true,  // never resume the daemon's conversation
      ephemeral: true,     // phone room: cwd lock may auto-suffix
    };
    if (this.opts.piBin !== undefined) childOpts.piBin = this.opts.piBin;
    const child = new RpcChild(childOpts);
    const slot: ChildSlot = {
      id: roomId,
      cwd,
      child,
      restartTimer: null,
      restartAttempt: 0,
      ephemeral: true,
      name,
    };
    this.ephemeral.set(roomId, slot);
    child.on("exit", (evt: RpcChildExitEvent) => this._onEphemeralExit(roomId, evt));
    child.spawn();
  }

  /** Ephemeral rooms never auto-restart: a crash is a drop, with a log line
   *  so the owner can see why the tile went away. */
  private _onEphemeralExit(roomId: string, evt: RpcChildExitEvent): void {
    const slot = this.ephemeral.get(roomId);
    if (!slot) return;
    this.ephemeral.delete(roomId);
    if (evt.isCrash) {
      process.stderr.write(
        `[remote-pi-supervisord] ephemeral room ${roomId} exited (code=${evt.code} signal=${evt.signal}) — dropped, no auto-restart for phone rooms\n`,
      );
    }
  }

  private async _opUnregister(id: string): Promise<ControlReply<unknown>> {
    // Stop the child first so we don't leave an orphan when the registry
    // entry is gone.
    const slot = this.children.get(id);
    if (slot) {
      if (slot.restartTimer !== null) {
        clearTimeout(slot.restartTimer);
        slot.restartTimer = null;
      }
      await slot.child.stop();
      this.children.delete(id);
    }
    try {
      const result = removeDaemon(id);
      return { ok: true, data: result };
    } catch (e) {
      return { ok: false, error: (e as Error).message };
    }
  }

  // ── Cron ops + engine (plan/39) ────────────────────────────────────────────

  private _opCronAdd(req: Extract<ControlRequest, { op: "cron_add" }>): ControlReply<unknown> {
    const v = validateSchedule(req.schedule, req.tz);
    if (!v.ok) return { ok: false, error: v.error ?? "invalid schedule" };
    const input: NewJobInput = { daemon_id: req.daemon_id, schedule: req.schedule, prompt: req.prompt };
    if (req.tz !== undefined) input.tz = req.tz;
    if (req.skip_if_busy !== undefined) input.skip_if_busy = req.skip_if_busy;
    if (req.wake !== undefined) input.wake = req.wake;
    if (req.catchup !== undefined) input.catchup = req.catchup;
    const job = addCronJob(input);
    this._scheduleCron(job);
    return { ok: true, data: { job: this._jobView(job) } };
  }

  private _opCronList(): ControlReply<unknown> {
    const jobs = listCronJobs().map((j) => this._jobView(j));
    return { ok: true, data: { jobs } };
  }

  private _opCronRemove(jobId: string): ControlReply<unknown> {
    const removed = removeCronJob(jobId);
    this._stopCron(jobId);
    return { ok: true, data: { removed } };
  }

  private _opCronEnable(jobId: string, enabled: boolean): ControlReply<unknown> {
    const updated = setJobEnabled(jobId, enabled);
    if (updated) {
      this._stopCron(jobId);
      const job = getCronJob(jobId);
      if (enabled && job) this._scheduleCron(job);
    }
    return { ok: true, data: { job_id: jobId, enabled, updated } };
  }

  private async _opCronRun(jobId: string): Promise<ControlReply<unknown>> {
    if (!getCronJob(jobId)) return { ok: false, error: `no cron job with id ${jobId}` };
    const result = await this.fireJob(jobId, { manual: true });
    return { ok: true, data: { job_id: jobId, result } };
  }

  private _opCronLog(jobId: string | undefined, tail: number | undefined): ControlReply<unknown> {
    const opts: { jobId?: string; tail?: number } = {};
    if (jobId !== undefined) opts.jobId = jobId;
    if (tail !== undefined) opts.tail = tail;
    return { ok: true, data: { entries: readCronLog(opts) } };
  }

  private _jobView(job: CronJob): CronJobView {
    const next = nextRunFor(job);
    return { ...job, next_run: next ? next.toISOString() : null };
  }

  /** Rebuild all live `Cron` schedules from the registry (enabled jobs only).
   *  Called on start; mutations reconcile incrementally via _scheduleCron/_stopCron. */
  private _reconcileCron(): void {
    for (const c of this.cronJobs.values()) c.stop();
    this.cronJobs.clear();
    for (const job of listCronJobs()) {
      if (job.enabled) this._scheduleCron(job);
    }
  }

  private _scheduleCron(job: CronJob): void {
    this._stopCron(job.id);
    try {
      const opts = job.tz ? { timezone: job.tz, name: job.id } : { name: job.id };
      const cron = new Cron(job.schedule, opts, () => { void this.fireJob(job.id); });
      this.cronJobs.set(job.id, cron);
    } catch (e) {
      process.stderr.write(`[remote-pi-supervisord] cron schedule failed for ${job.id}: ${String(e)}\n`);
    }
  }

  private _stopCron(jobId: string): void {
    const c = this.cronJobs.get(jobId);
    if (c) { c.stop(); this.cronJobs.delete(jobId); }
  }

  /** Detail 2: on start, run a catchup job once if its previous scheduled run
   *  was missed while the supervisor was down. Opt-in (`catchup`), at most 1×. */
  private _runCatchup(): void {
    for (const job of listCronJobs()) {
      if (!job.enabled || !job.catchup) continue;
      try {
        const cron = new Cron(job.schedule, job.tz ? { timezone: job.tz } : {});
        const prev = cron.previousRun();
        cron.stop();
        if (!prev) continue;
        const lastRunMs = job.last_run ? Date.parse(job.last_run) : 0;
        if (prev.getTime() > lastRunMs) void this.fireJob(job.id, { manual: true });
      } catch { /* skip a malformed schedule */ }
    }
  }

  /**
   * Fires a cron job: resolves the daemon, decides the action (decideFireAction),
   * acts, and records the outcome — ALWAYS one `last_status` update + one JSONL
   * line, for both fires and skips. Returns the result. `manual` bypasses the
   * disabled-skip (used by `cron run` + catchup).
   */
  async fireJob(jobId: string, opts: { manual?: boolean } = {}): Promise<CronResult | "missing"> {
    const job = getCronJob(jobId);
    if (!job) return "missing";

    let result: CronResult;
    if (!job.enabled && !opts.manual) {
      result = "skipped_disabled";
    } else {
      const slot = this.children.get(job.daemon_id);
      const running = !!slot && slot.child.state === "running";
      let busy = false;
      if (running && job.skip_if_busy) busy = await slot!.child.refreshBusy();
      const action = decideFireAction({ running, busy, wake: job.wake, skipIfBusy: job.skip_if_busy });
      if (action === "skip_down") {
        result = "skipped_down";
      } else if (action === "skip_busy") {
        result = "skipped_busy";
      } else if (action === "wake_and_send") {
        const entry = listDaemons().find((d) => d.id === job.daemon_id);
        if (!entry) {
          result = "skipped_down";
        } else {
          this._spawnEntry(entry.id, entry.cwd, entry.name);
          const woke = this.children.get(job.daemon_id);
          result = woke && woke.child.sendPrompt(job.prompt) ? "woke_and_delivered" : "deliver_failed";
        }
      } else {
        result = slot!.child.sendPrompt(job.prompt) ? "delivered" : "deliver_failed";
      }
    }

    const at = new Date().toISOString();
    recordRun(job.id, at, result);
    appendCronLog({ job_id: job.id, daemon_id: job.daemon_id, schedule: job.schedule, result, prompt: job.prompt });
    return result;
  }

  // ── Child lifecycle ──────────────────────────────────────────────────────

  private _spawnAllFromRegistry(): void {
    for (const entry of listDaemons()) {
      this._spawnEntry(entry.id, entry.cwd, entry.name);
    }
  }

  private _spawnEntry(id: string, cwd: string, name?: string): void {
    // Clean up any prior slot (e.g. crashed + waiting for backoff).
    const existing = this.children.get(id);
    if (existing) {
      if (existing.restartTimer !== null) clearTimeout(existing.restartTimer);
      // If somehow the child is still alive, stop it first so we don't
      // leak. Fire-and-forget — caller doesn't await.
      if (existing.child.state === "running") void existing.child.stop();
    }

    // Build the daemon's config and inject it via REMOTE_PI_DIRECT_CONFIG —
    // no per-cwd config file needed. The daemon scopes by (cwd, name) like any
    // agent (plan/38); relay on.
    const config: LocalConfig = {
      agent_name: name ?? defaultAgentName(cwd),
      auto_start_relay: true,
    };
    const childOpts: RpcChildOptions = {
      extensionPath: this.opts.extensionPath,
      cwd,
      config,
    };
    if (this.opts.piBin !== undefined) childOpts.piBin = this.opts.piBin;
    const child = new RpcChild(childOpts);
    const slot: ChildSlot = { id, cwd, child, restartTimer: null, restartAttempt: 0 };
    this.children.set(id, slot);

    child.on("exit", (evt: RpcChildExitEvent) => this._onChildExit(id, evt));
    // Notifications no longer need a bridge here: remote-pi captures
    // `ctx.ui.notify()` from the other extensions in-process and relays it
    // itself, so nothing has to be injected back into the child's stdin.
    // (The previous version fed the frame in as a marked `prompt`; see
    // `ui_notify_capture.ts` for why that could not work.) The child's stdout is
    // still parsed so dialog requests can be refused out loud rather than
    // hanging.
    child.on("stdout", (_line: string, ui?: RpcUiEvent) => {
      if (!ui) return;
      process.stderr.write(
        `[${cwd}] [remote-pi-supervisord] ignored extension UI request "${ui.method ?? "?"}" (notifications are relayed by the daemon itself)\n`,
      );
    });
    child.spawn();
  }

  private _onChildExit(id: string, evt: RpcChildExitEvent): void {
    if (this.shuttingDown) return;
    const slot = this.children.get(id);
    if (!slot) return;

    if (!evt.isCrash) {
      // Clean shutdown (e.g. via `stop_all`). Don't auto-restart.
      return;
    }

    if (evt.code === EXIT_DAEMON_FRESH_SESSION) {
      // App-triggered daemon `/new`: this is an intentional recycle, not a
      // crash. Restart immediately and don't burn the crash backoff budget.
      slot.restartAttempt = 0;
      slot.child.noteRestart();
      slot.child.spawn();
      return;
    }

    // Crash: schedule restart with backoff.
    // LOCAL PATCH (fenlyin): never give up. The fixed schedule used to end in
    // a permanent `crashed` state (2026-09-22 outage: daemon down ~20h until
    // manual restart). After exhausting the schedule, keep retrying at the
    // final (5-minute) interval forever.
    const delay = slot.restartAttempt < RESTART_BACKOFFS_MS.length
      ? RESTART_BACKOFFS_MS[slot.restartAttempt]!
      : RESTART_BACKOFFS_MS[RESTART_BACKOFFS_MS.length - 1]!;
    process.stderr.write(
      `[remote-pi-supervisord] scheduling restart of ${id} in ${delay}ms (attempt ${slot.restartAttempt + 1})\n`,
    );
    slot.restartTimer = setTimeout(() => {
      slot.restartTimer = null;
      slot.restartAttempt += 1;
      slot.child.noteRestart();
      slot.child.spawn();
    }, delay);
  }
}

/** Test helper: derive id from cwd without going through the registry. */
export function _idForCwdForTest(cwd: string): string { return daemonIdForCwd(cwd); }

/** Exported for the bin/supervisord entry + tests to know where the
 *  supervisor will bind. */
export function getSupervisorSockPath(): string { return supervisorSockPath(); }
