import { type Envelope, type TransportErrorReason } from "./envelope.js";
import { Broker } from "./broker.js";
/**
 * Symmetric peer-in-session API. Hides whether you are leader or follower;
 * `send`, `request`, `onMessage`, `rename`, `leave` all work the same.
 *
 * Pending map demuxes parallel `request()` calls by message `id` → `re`.
 *
 * Failover: when the leader dies, follower socket emits `close`. Remaining
 * peers re-run `joinOrLead`. One becomes the new leader; others reconnect.
 */
export type MessageHandler = (env: Envelope) => void;
export type ReconnectHandler = () => void;
export interface SessionPeerOptions {
    sockPath: string;
    name: string;
    /**
     * Working directory of this agent. Sent in the `register` so the broker can
     * key peers by the (cwd, name) pair: two agents in the SAME folder with the
     * same name are the SAME logical agent reincarnating (switch_session /
     * restart), so the broker take-over the name instead of suffixing `#N`.
     * Optional for backward-compat with peers that predate this field.
     */
    cwd?: string;
    /** Replace an existing same-(cwd,name) registration instead of accepting a
     *  broker-assigned `#N`. Use only for stable logical identities; ordinary
     *  multi-agent sessions should leave this false. */
    takeoverExisting?: boolean;
    auditPath?: string;
    /** Per-request default timeout (ms). Override per call if needed. */
    defaultTimeoutMs?: number;
}
export type AckStatus = "received" | "busy" | "denied" | "timeout";
export interface AckResult {
    status: AckStatus;
    /** The original envelope id that was awaiting ACK. */
    id: string;
    /** Target name reported by broker (when ACK arrived). Undefined on timeout. */
    target?: string;
    error?: `transport_error: ${TransportErrorReason}`;
    reason?: TransportErrorReason;
}
export declare class MeshTransportError extends Error {
    readonly reason: TransportErrorReason;
    readonly correlationId: string;
    constructor(reason: TransportErrorReason, correlationId: string);
}
export declare class SessionPeer {
    private readonly opts;
    /** Clean leaf name actually assigned by the broker (may carry a `#N`
     *  collision suffix). Used for display + self-filtering. */
    private assignedName;
    /** Canonical address assigned by the broker (`[<pc>:]<cwd>@<nome>`, or just
     *  the name for a legacy broker). This is the routing/identity key the mesh
     *  uses; callers ECHO it, never compose it. */
    private assignedAddress;
    private role;
    private broker;
    private socket;
    private buf;
    /** Map of in-flight request ids → resolver. Used by `request()`. */
    private readonly pending;
    /** Map of in-flight send ids → ACK resolver. Used by `sendWithAck()`. */
    private readonly ackPending;
    private readonly handlers;
    private readonly reconnectHandlers;
    private leftFlag;
    constructor(opts: SessionPeerOptions);
    /** Joins or leads the session at `sockPath`. Resolves with the assigned name. */
    start(): Promise<string>;
    /** Returns the clean leaf name as assigned by the broker (after any `#N`). */
    name(): string;
    /** Returns the canonical address (`[<pc>:]<cwd>@<nome>`) assigned by the
     *  broker — the key the mesh routes on. Equals `name()` against a legacy
     *  broker that returns no address. */
    address(): string;
    /** Returns "leader" or "follower" — current role. */
    currentRole(): "leader" | "follower";
    /** Returns the locally-hosted Broker when this peer is the leader, or
     *  null when it's a follower. Wave 25C uses this to attach the
     *  cross-PC router. */
    localBroker(): Broker | null;
    /**
     * Fire-and-forget send. Doesn't await a reply.
     *
     * `re` (optional) lets the caller correlate this message as a reply to a
     * previous request — when an LLM peer is *answering* a question from
     * another agent, it must echo the original `id` here so the requester's
     * pending map can resolve. Without `re`, the requester treats this as a
     * new unsolicited message and its `request()` call times out.
     */
    send(to: string | string[], body: unknown, re?: string | null): Promise<void>;
    /**
     * Unicast send + await broker ACK. Returns the ACK status:
     *   - `received` — peer was idle, envelope delivered, will be processed soon
     *   - `busy`     — peer mid-turn, envelope dropped; sender is owner of retry
     *   - `denied`   — broker/Relay refused delivery (including authorization or envelope failure)
     *   - `timeout`  — no ACK within `timeoutMs`, or trusted Relay says offline
     *
     * Only meaningful for unicast non-broadcast addresses. The peer's body-level
     * reply (if any) is asynchronous and arrives as a normal inbound envelope
     * carrying `re=<this-send-id>` in a future turn — handled by `onMessage`.
     */
    sendWithAck(to: string, body: unknown, re?: string | null, timeoutMs?: number): Promise<AckResult>;
    /**
     * Send + await reply. Resolves with the first inbound envelope whose `re`
     * matches the outbound `id`. Rejects on timeout, teardown/write failure, or
     * a trusted Relay transport error.
     */
    request(to: string, body: unknown, timeoutMs?: number): Promise<Envelope>;
    onMessage(handler: MessageHandler): () => void;
    /**
     * Fires after the peer successfully (re)joins following a failover —
     * leader died and we re-elected. NOT called for the initial `start()`,
     * only for post-drop reconnects. Consumers use this to re-query state
     * the broker may have lost in the transition (e.g., peer list).
     */
    onReconnect(handler: ReconnectHandler): () => void;
    /**
     * Requests a different display name from the broker. Returns the name
     * actually assigned (may carry a #N suffix on collision). Implemented as
     * a soft rejoin: leaves & rejoins with the new name.
     */
    rename(newName: string): Promise<string>;
    leave(): Promise<void>;
    private _joinOrLead;
    private _registerAsClient;
    private _wireSocket;
    private _registerOver;
    private _preAckListener;
    private _onData;
    private _handleLine;
    private _consumeAckTransportError;
    private _rejectRequestTransportError;
    private _dispatchToHandlers;
    private _writeEnvelope;
    private _onSocketClose;
    private _teardownConn;
}
