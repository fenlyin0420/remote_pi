import { appendFile, mkdir } from "node:fs/promises";
import { dirname, posix, win32 } from "node:path";
import { parse, serialize, uuidv7, EnvelopeError } from "./envelope.js";
import { sanitizeSegment } from "./local_config.js";
import { isBoundedPeerInfo, MAX_CWD_LENGTH, MAX_PEERS_UPDATE_ENTRIES, } from "./peer_limits.js";
/**
 * THE sole encoder of a peer address (plan/38): `[<pc>:]<cwd>@<nome>`.
 *
 * - `cwd` present → `<cwd>@<nome>` (the `@` separates name from path so a `/`
 *   in the path never confuses lookup, which is exact-match anyway).
 * - `cwd` empty (legacy peer that sent no cwd) → `address == name`, preserving
 *   pre-plan/38 behavior so a mixed mesh keeps routing.
 * - `pc` present (cross-PC, Fase 2) → prefixed `<pc>:`.
 *
 * Does NOT sanitize — callers sanitize the `name` once (see `sanitizeMeshName`)
 * before composing, so an already-appended `#N` collision suffix survives.
 * Everyone else ECHOES `peer.address` verbatim; only the broker composes.
 */
export function composeAddress(parts) {
    const base = parts.cwd ? `${parts.cwd}@${parts.name}` : parts.name;
    return parts.pc ? `${parts.pc}:${base}` : base;
}
/**
 * Sanitize a requested mesh name to a safe leaf while PRESERVING a trailing
 * `#N` collision suffix (which the cwd-lock or a prior assignment may have
 * added — `sanitizeSegment` alone would mangle `#`→`-`). The base is run through
 * `sanitizeSegment` (af66d04); an unusable base (empty / reserved keyword) falls
 * back to `"agent"`.
 */
export function sanitizeMeshName(raw) {
    const m = /^(.*?)(#\d+)?$/.exec(raw);
    const base = sanitizeSegment(m?.[1] ?? raw) ?? "agent";
    return m?.[2] ? base + m[2] : base;
}
const BROKER_NAME = "broker";
/** Host-independent Windows drive absolute-path check. */
function isWindowsDriveAbsolutePath(value) {
    return /^[A-Za-z]:[\\/]/.test(value);
}
/** Accept legacy empty cwd plus bounded syntactically absolute paths only. */
function isValidRegisteredCwd(value) {
    if (value === "")
        return true;
    if (value.length > MAX_CWD_LENGTH ||
        /[\0\r\n]/.test(value)) {
        return false;
    }
    return posix.isAbsolute(value) ||
        isWindowsDriveAbsolutePath(value) ||
        (win32.isAbsolute(value) && /^[/\\]{2}/.test(value));
}
export class Broker {
    peers = new Map();
    auditPath;
    onRouted;
    server;
    /** Plan/25 Wave C: optional handoff for cross-PC routing. Null = local only. */
    remoteRouter = null;
    constructor(opts) {
        this.server = opts.server;
        this.auditPath = opts.auditPath;
        this.onRouted = opts.onRouted;
        this.server.on("connection", (socket) => this._handleConnection(socket));
    }
    /** Attach (or detach with null) a cross-PC router. Idempotent. */
    setRemoteRouter(router) {
        this.remoteRouter = router;
    }
    /** Clear only when the caller still owns the active router slot. */
    clearRemoteRouter(expected) {
        if (this.remoteRouter === expected)
            this.remoteRouter = null;
    }
    /**
     * Plan/25 Wave C entry point: deliver an envelope that arrived from a
     * remote PC (via relay forward) into the local UDS mesh. Skips the
     * `force from = conn.name` rule (that defense is anti-spoof for local
     * peers; cross-PC has its own defense via the relay's verified `from_pc`).
     *
     * Returns the ACK status so the caller (broker_remote) can pack and
     * forward an ACK envelope back across the relay:
     *   - `received` — target exists, envelope delivered (plan/34: always
     *     delivered when the peer is online — the Pi harness enqueues mid-turn
     *     messages, so there is no busy-drop)
     *   - `denied` — no such local peer (or write failed) — caller maps to
     *     transport_error or denied ACK as it sees fit
     */
    injectFromRemote(env) {
        // Remote callers do not cross the normal UDS parser, so validate the exact
        // serialized payload before claiming receipt or writing it to a peer.
        let validated;
        try {
            validated = parse(serialize(env));
        }
        catch {
            return "denied";
        }
        if (typeof validated.to !== "string" ||
            validated.to === "broadcast" ||
            validated.to === BROKER_NAME) {
            // Cross-PC is unicast-only at this protocol layer.
            return "denied";
        }
        const targetName = validated.to;
        const peer = this.peers.get(targetName);
        if (!peer)
            return "denied";
        const line = serialize(validated);
        try {
            peer.socket.write(line);
        }
        catch {
            return "denied";
        }
        void this._appendAudit(validated, [targetName], "received", "relay");
        this.onRouted?.(validated, [targetName]);
        return "received";
    }
    /** Peers currently registered. Snapshot, safe to read. */
    peerNames() {
        return [...this.peers.keys()];
    }
    async close() {
        for (const p of this.peers.values())
            p.socket.destroy();
        this.peers.clear();
        await new Promise((resolve) => this.server.close(() => resolve()));
    }
    // ── connection lifecycle ──────────────────────────────────────────────────
    _handleConnection(socket) {
        const conn = { name: "", cwd: "", address: "", socket, buf: "" };
        socket.setEncoding("utf8");
        socket.on("data", (chunk) => this._onData(conn, chunk));
        socket.on("close", () => this._onClose(conn));
        socket.on("error", () => { });
    }
    _onData(conn, chunk) {
        conn.buf += chunk;
        let nl;
        while ((nl = conn.buf.indexOf("\n")) >= 0) {
            const line = conn.buf.slice(0, nl);
            conn.buf = conn.buf.slice(nl + 1);
            if (!line)
                continue;
            void this._handleLine(conn, line);
        }
    }
    async _handleLine(conn, line) {
        // Unregistered conn: a read-only `list_peers` probe (the `remote-pi peers`
        // CLI — answered without registering, so it leaves no trace on the mesh) or
        // the mandatory `register` handshake. Anything else `_handleRegister` drops.
        if (!conn.name) {
            if (this._tryObserverProbe(conn, line))
                return;
            this._handleRegister(conn, line);
            return;
        }
        // Already registered — must be a regular envelope.
        let env;
        try {
            env = parse(line);
        }
        catch (e) {
            if (e instanceof EnvelopeError)
                return; // malformed; drop silently
            throw e;
        }
        // Force `from` to the registered ADDRESS (security: peer can't spoof; and
        // replies/ACKs address back by the same canonical key the Map is keyed on).
        env.from = conn.address;
        await this._route(env);
    }
    _handleRegister(conn, line) {
        let req;
        try {
            const parsed = JSON.parse(line);
            if (!parsed ||
                typeof parsed !== "object" ||
                parsed.type !== "register" ||
                typeof parsed.name !== "string") {
                conn.socket.destroy();
                return;
            }
            req = parsed;
        }
        catch {
            conn.socket.destroy();
            return;
        }
        // (cwd, name) identity (plan/38). The cwd is the first-class axis: the
        // address embeds it, so two same-named agents in DIFFERENT folders get
        // distinct addresses and never collide. Legacy peers (no cwd) keep the old
        // global-name behavior. New peers can opt into exact-address takeover for
        // same-folder reincarnations such as daemon restarts.
        const requestedCwd = req.cwd === undefined ? "" : req.cwd;
        if (typeof requestedCwd !== "string" || !isValidRegisteredCwd(requestedCwd)) {
            conn.socket.destroy();
            return;
        }
        const identity = this._identityForRegister(requestedCwd, req.name, req.takeover === true);
        if (!identity) {
            conn.socket.destroy();
            return;
        }
        conn.cwd = requestedCwd;
        conn.name = identity.name;
        conn.address = identity.address;
        // Candidate validity is established before a takeover evicts its prior
        // connection, so a rejected replacement cannot drop a healthy peer.
        if (identity.replaceAddress)
            this._dropPeerAt(identity.replaceAddress);
        this.peers.set(identity.address, conn);
        // `name_assigned` doubles as the compat alias: for a legacy peer it equals
        // `address_assigned` (cwd empty → address == name), so old clients that read
        // `name_assigned` still get a routable identity.
        const ack = {
            type: "register_ack",
            address_assigned: conn.address,
            name_assigned: conn.name,
        };
        try {
            conn.socket.write(JSON.stringify(ack) + "\n");
        }
        catch { /* peer hung up */ }
        // Notify others (peer_joined broadcast). The field carries the ADDRESS.
        this._broadcastSystem({ type: "peer_joined", name: conn.address, address: conn.address }, conn.address);
    }
    /**
     * Answer a read-only `list_peers` request from an UNREGISTERED connection
     * (the `remote-pi peers` CLI probe). Returns true when the line was such a
     * probe — the reply is written and the connection stays unregistered: no
     * name assigned, no `peer_joined`/`peer_left` broadcast, no sibling push, so
     * querying the roster from the shell never perturbs the mesh. Returns false
     * (not a probe) so the caller falls through to the register handshake.
     */
    _tryObserverProbe(conn, line) {
        let parsed;
        try {
            parsed = JSON.parse(line);
        }
        catch {
            return false; // not JSON → let _handleRegister destroy it
        }
        if (!parsed || typeof parsed !== "object" || parsed.type !== "list_peers") {
            return false;
        }
        const reply = {
            from: BROKER_NAME,
            to: "observer", // synthetic: the conn has no registered name
            id: uuidv7(),
            re: null,
            body: {
                type: "list_peers_reply",
                peers: this._allPeerNames(),
                peers_detailed: this._allPeerInfos(),
            },
        };
        try {
            conn.socket.write(serialize(reply));
        }
        catch { /* probe hung up */ }
        return true;
    }
    /** Local UDS peer names plus cross-PC `<pc>:<peer>` entries from the remote
     *  router (empty when no bridge). Shared by the registered `list_peers`
     *  handler and the unregistered observer probe. */
    _allPeerNames() {
        const remote = this.remoteRouter ? this.remoteRouter.listRemotePeers() : [];
        return [...this.peerNames(), ...remote];
    }
    /** Structured roster of LOCAL UDS peers (plan/38): one `PeerInfo` each, no
     *  `pc` (they're on this machine). Public so the cross-PC router
     *  (`broker_remote`) can read the authoritative local inventory directly to
     *  push to siblings — no `list_peers` round-trip, no stale cache. */
    localPeerInfos() {
        return [...this.peers.values()].map((p) => ({
            cwd: p.cwd,
            name: p.name,
            address: p.address,
        }));
    }
    /** Structured roster (plan/38): local peers (no `pc`) + cross-PC peers with
     *  `pc`/`cwd`/`name` filled by the remote router (Fase 2). */
    _allPeerInfos() {
        const remote = this.remoteRouter?.listRemotePeerInfos() ?? [];
        return [...this.localPeerInfos(), ...remote];
    }
    /**
     * Resolve a free `(name, address)` for a register, keyed by **(cwd, name)**
     * (plan/38): the collision check is on the composed ADDRESS, so a name only
     * collides with another peer in the SAME cwd. `#N` is appended to the name
     * (matching the cwd-lock's suffix scheme) until the address is free; for a
     * legacy peer (cwd "") the address is the name, preserving global-name `#N`.
     */
    _identityForRegister(cwd, requested, takeover) {
        const sanitized = sanitizeMeshName(requested);
        const candidateFor = (name) => {
            const address = composeAddress({ cwd, name });
            return isBoundedPeerInfo({ cwd, name, address }) ? { name, address } : null;
        };
        const direct = candidateFor(sanitized);
        if (!direct)
            return null;
        if (takeover && cwd && this.peers.has(direct.address)) {
            return { ...direct, replaceAddress: direct.address };
        }
        if (this.peers.size >= MAX_PEERS_UPDATE_ENTRIES)
            return null;
        if (!this.peers.has(direct.address))
            return direct;
        // Collision: strip any client-provided `#N`, then re-suffix from #2.
        const base = sanitized.replace(/#\d+$/, "");
        for (let n = 2; n < 1000; n++) {
            const candidate = candidateFor(`${base}#${n}`);
            if (!candidate)
                return null;
            if (!this.peers.has(candidate.address))
                return candidate;
        }
        return null;
    }
    _dropPeerAt(address) {
        const existing = this.peers.get(address);
        if (!existing)
            return;
        this.peers.delete(address);
        // The old socket's close event may arrive after the replacement has been
        // inserted. Clear its address so it cannot delete the replacement.
        existing.address = "";
        try {
            existing.socket.destroy();
        }
        catch { /* ignored */ }
    }
    _onClose(conn) {
        if (!conn.address)
            return;
        if (this.peers.get(conn.address) !== conn)
            return;
        this.peers.delete(conn.address);
        this._broadcastSystem({ type: "peer_left", name: conn.address, address: conn.address }, conn.address);
    }
    // ── routing ───────────────────────────────────────────────────────────────
    async _route(env) {
        // Special handling for messages addressed to the broker itself.
        if (env.to === BROKER_NAME) {
            this._handleBrokerMessage(env);
            return;
        }
        // Give known cross-PC aliases first chance to route. A syntactically
        // absolute Windows drive address contains a colon but is always exact
        // local; all other local registrations may not shadow a known alias.
        const exactLocal = typeof env.to === "string" ? this.peers.get(env.to) : undefined;
        const exactWindowsDriveLocal = !!exactLocal && isWindowsDriveAbsolutePath(exactLocal.cwd);
        if (!exactWindowsDriveLocal && this.remoteRouter && typeof env.to === "string") {
            if (this.remoteRouter.tryRouteOutbound(env))
                return;
        }
        const targets = this._resolveTargets(env);
        const delivered = [];
        const line = serialize(env);
        const isUnicast = typeof env.to === "string" && env.to !== "broadcast";
        // plan/34: reliable delivery — always write to the target's socket. The
        // Pi harness enqueues messages that arrive mid-turn, so there is no
        // busy-drop and `busy` is no longer a possible ACK status. Unicast sends
        // to an online peer always ACK `received`.
        let ackStatus = "none";
        for (const targetName of targets) {
            const peer = this.peers.get(targetName);
            if (!peer)
                continue; // unknown peer: silent drop (sender times out)
            try {
                peer.socket.write(line);
                delivered.push(targetName);
                if (isUnicast) {
                    ackStatus = "received";
                    this._sendAckToSender(env, "received", targetName);
                }
            }
            catch {
                // peer dropped mid-write — close handler will fire; treat as silent
            }
        }
        if (this.auditPath)
            await this._appendAudit(env, delivered, ackStatus);
        this.onRouted?.(env, delivered);
    }
    _resolveTargets(env) {
        if (env.to === "broadcast") {
            // plan/38 decision C: broadcast is scoped to the sender's cwd (folder
            // colleagues), local-only. A peer in /a/b never hears /a/c. The sender is
            // keyed by its address (= env.from); legacy peers (cwd "") broadcast among
            // other cwd-less peers, matching pre-plan/38 behavior.
            const sender = this.peers.get(env.from);
            const scope = sender?.cwd ?? "";
            return [...this.peers.values()]
                .filter((p) => p.address !== env.from && p.cwd === scope)
                .map((p) => p.address);
        }
        if (Array.isArray(env.to)) {
            return env.to.filter((n) => n !== env.from);
        }
        // Unicast: drop self-loops too. The skill warns "useless" but the LLM
        // might still try (especially with deceiving `re` reply chains). A
        // self-loop has no upside and risks unbounded message ↔ inject ↔ message
        // cycles when the inbound injector tells the LLM "reply with re=…".
        if (env.to === env.from)
            return [];
        return [env.to];
    }
    /**
     * Writes an ACK envelope to the original sender's socket. Synchronous —
     * the caller is inside `_route` and must keep busy-check/busy-set atomic.
     * Broker → sender: `from="broker"`, `to=env.from`, `re=env.id`,
     * `body={type:"ack", status, target}`.
     */
    _sendAckToSender(env, status, target) {
        const sender = this.peers.get(env.from);
        if (!sender)
            return; // sender vanished mid-write
        const body = { type: "ack", status, target };
        const ackEnv = {
            from: BROKER_NAME,
            to: env.from,
            id: uuidv7(),
            re: env.id,
            body,
        };
        try {
            sender.socket.write(serialize(ackEnv));
        }
        catch { /* sender dropped; close handler will fire */ }
    }
    _handleBrokerMessage(env) {
        const body = env.body;
        if (!body || typeof body !== "object")
            return;
        if (body.type === "list_peers") {
            const reply = {
                from: BROKER_NAME,
                to: env.from,
                id: uuidv7(),
                re: env.id,
                body: {
                    type: "list_peers_reply",
                    peers: this._allPeerNames(), // addresses — legacy clients route by these
                    peers_detailed: this._allPeerInfos(), // plan/38 — clients group without parsing
                },
            };
            const peer = this.peers.get(env.from);
            if (peer) {
                try {
                    peer.socket.write(serialize(reply));
                }
                catch { /* ignored */ }
            }
            return;
        }
        // plan/34: `turn_state` is no longer consumed — the broker doesn't gate
        // delivery on busy state. The Pi extension still publishes working state
        // as room_meta over the relay (index.ts), independent of the broker.
    }
    _broadcastSystem(body, excludeAddress) {
        for (const [address, peer] of this.peers) {
            if (address === excludeAddress)
                continue;
            const env = {
                from: BROKER_NAME,
                to: address,
                id: uuidv7(),
                re: null,
                body,
            };
            try {
                peer.socket.write(serialize(env));
            }
            catch { /* ignored */ }
        }
    }
    async _appendAudit(env, delivered, ackStatus, 
    /**
     * Plan/25 Wave D: provenance hint for the audit reader. `"relay"` marks
     * envelopes injected via `injectFromRemote` (cross-PC). Local UDS
     * delivery keeps the default `"uds"` so existing audit consumers see
     * a uniform field rather than an undefined hole.
     */
    via = "uds") {
        if (!this.auditPath)
            return;
        const line = JSON.stringify({
            ts: Date.now(),
            from: env.from,
            to: env.to,
            id: env.id,
            re: env.re,
            delivered,
            ack_status: ackStatus,
            via,
        }) + "\n";
        try {
            await mkdir(dirname(this.auditPath), { recursive: true });
            await appendFile(this.auditPath, line, "utf8");
        }
        catch { /* audit best-effort */ }
    }
}
//# sourceMappingURL=broker.js.map