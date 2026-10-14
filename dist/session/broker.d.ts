import type { Server } from "node:net";
import { type Envelope } from "./envelope.js";
/**
 * Structured view of one mesh peer (plan/38). The `address` is the canonical
 * routing key; the other fields let a client group/label peers WITHOUT parsing
 * the address string. `pc` is undefined for local peers (filled cross-PC in
 * Fase 2). Returned by `list_peers` as `peers_detailed`.
 */
export interface PeerInfo {
    /** Cross-PC label; undefined for a local peer. */
    pc?: string;
    /** Working directory (realpath). Empty string for a legacy peer (no cwd). */
    cwd: string;
    /** Clean leaf name (carries a `#N` only on a same-(cwd,name) collision). */
    name: string;
    /** Canonical address — the broker's Map key and the `to`/`from` on the wire. */
    address: string;
}
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
export declare function composeAddress(parts: {
    pc?: string;
    cwd: string;
    name: string;
}): string;
/**
 * Sanitize a requested mesh name to a safe leaf while PRESERVING a trailing
 * `#N` collision suffix (which the cwd-lock or a prior assignment may have
 * added — `sanitizeSegment` alone would mangle `#`→`-`). The base is run through
 * `sanitizeSegment` (af66d04); an unusable base (empty / reserved keyword) falls
 * back to `"agent"`.
 */
export declare function sanitizeMeshName(raw: string): string;
/**
 * Broker hosted by the session leader. Accepts UDS connections, maintains a
 * `name → connection` map, routes envelopes per the `to` field, and appends
 * each routed message to an `audit.jsonl` log.
 *
 * Auto-suffix on name collision: when a peer registers a name already taken,
 * the broker assigns `<name>#N` and returns it in the register ack.
 *
 * ## ACK protocol (plan/25 Wave 0; reliable delivery per plan/34)
 *
 * For **unicast non-broker** envelopes the broker synchronously emits an ACK
 * envelope back to the sender once it has delivered:
 *
 *   - target online → deliver envelope, ACK `received`
 *   - no such peer  → silent drop (sender times out)
 *
 * plan/34 removed the busy-drop: a message that arrives while the target is
 * mid-turn is **always delivered**, never dropped. The Pi harness
 * (`sendMessage(triggerTurn:true)`) enqueues mid-turn messages and processes
 * them in the upcoming turn, so the broker needs no busy gate or mailbox.
 * Consequently `busy` is no longer a possible ACK status for unicast new
 * work — the sender always gets `received`. (Turn-lifecycle / working
 * indicators live in `index.ts` via room_meta over the relay, not here.)
 *
 * Broadcast/multicast/broker-addressed envelopes are not ACKed (no single
 * authoritative recipient or no semantic match). The audit log carries the
 * ACK status (`received | denied | none`) per envelope.
 */
export interface BrokerOptions {
    server: Server;
    auditPath?: string;
    /** Optional callback invoked after each successful route (testing/observability). */
    onRouted?: (env: Envelope, deliveredTo: string[]) => void;
}
/**
 * Hook the broker calls before doing local routing, so cross-PC prefixes
 * (`<pc_label>:<peer_name>`) can be handed off to a remote forwarder
 * without baking transport knowledge into the broker. Wave C (plan/25)
 * wires `broker_remote.ts` here.
 */
export interface RemoteRouter {
    /**
     * Try to claim responsibility for routing this envelope cross-PC.
     * Returns true if claimed (broker MUST NOT also deliver locally). Returns
     * false if the envelope should fall through to local routing — e.g., the
     * prefix matches the local `pc_label`, the prefix is not a known remote
     * label (backward-compat for local names containing `:`), or there's no
     * prefix at all.
     */
    tryRouteOutbound(env: Envelope): boolean;
    /** Aggregated remote peer addresses (`<pc_label>:<cwd>@<nome>`) for the
     *  `list_peers` reply's `peers` (string) field. Empty when nothing known. */
    listRemotePeers(): string[];
    /** Structured remote roster (plan/38 Fase 2): one `PeerInfo` per cross-PC
     *  peer with `pc` filled (the sibling label), `cwd`/`name` from the sibling's
     *  inventory, and `address` prefixed `<pc>:<cwd>@<nome>`. Powers the
     *  `peers_detailed` half of `list_peers` so clients group by `pc`/`cwd`
     *  without parsing. Empty when nothing known. */
    listRemotePeerInfos(): PeerInfo[];
}
export interface ConditionalRemoteRouterHost {
    clearRemoteRouter(expected: RemoteRouter): void;
}
/** Local outcome of a cross-PC envelope injection. broker_remote uses this
 *  to construct the ACK envelope it sends back via the relay. plan/34: `busy`
 *  is gone — injection always delivers when the peer exists. */
export type RemoteInjectStatus = "received" | "denied";
export declare class Broker {
    private readonly peers;
    private readonly auditPath?;
    private readonly onRouted?;
    private readonly server;
    /** Plan/25 Wave C: optional handoff for cross-PC routing. Null = local only. */
    private remoteRouter;
    constructor(opts: BrokerOptions);
    /** Attach (or detach with null) a cross-PC router. Idempotent. */
    setRemoteRouter(router: RemoteRouter | null): void;
    /** Clear only when the caller still owns the active router slot. */
    clearRemoteRouter(expected: RemoteRouter): void;
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
    injectFromRemote(env: Envelope): RemoteInjectStatus;
    /** Peers currently registered. Snapshot, safe to read. */
    peerNames(): string[];
    close(): Promise<void>;
    private _handleConnection;
    private _onData;
    private _handleLine;
    private _handleRegister;
    /**
     * Answer a read-only `list_peers` request from an UNREGISTERED connection
     * (the `remote-pi peers` CLI probe). Returns true when the line was such a
     * probe — the reply is written and the connection stays unregistered: no
     * name assigned, no `peer_joined`/`peer_left` broadcast, no sibling push, so
     * querying the roster from the shell never perturbs the mesh. Returns false
     * (not a probe) so the caller falls through to the register handshake.
     */
    private _tryObserverProbe;
    /** Local UDS peer names plus cross-PC `<pc>:<peer>` entries from the remote
     *  router (empty when no bridge). Shared by the registered `list_peers`
     *  handler and the unregistered observer probe. */
    private _allPeerNames;
    /** Structured roster of LOCAL UDS peers (plan/38): one `PeerInfo` each, no
     *  `pc` (they're on this machine). Public so the cross-PC router
     *  (`broker_remote`) can read the authoritative local inventory directly to
     *  push to siblings — no `list_peers` round-trip, no stale cache. */
    localPeerInfos(): PeerInfo[];
    /** Structured roster (plan/38): local peers (no `pc`) + cross-PC peers with
     *  `pc`/`cwd`/`name` filled by the remote router (Fase 2). */
    private _allPeerInfos;
    /**
     * Resolve a free `(name, address)` for a register, keyed by **(cwd, name)**
     * (plan/38): the collision check is on the composed ADDRESS, so a name only
     * collides with another peer in the SAME cwd. `#N` is appended to the name
     * (matching the cwd-lock's suffix scheme) until the address is free; for a
     * legacy peer (cwd "") the address is the name, preserving global-name `#N`.
     */
    private _identityForRegister;
    private _dropPeerAt;
    private _onClose;
    private _route;
    private _resolveTargets;
    /**
     * Writes an ACK envelope to the original sender's socket. Synchronous —
     * the caller is inside `_route` and must keep busy-check/busy-set atomic.
     * Broker → sender: `from="broker"`, `to=env.from`, `re=env.id`,
     * `body={type:"ack", status, target}`.
     */
    private _sendAckToSender;
    private _handleBrokerMessage;
    private _broadcastSystem;
    private _appendAudit;
}
