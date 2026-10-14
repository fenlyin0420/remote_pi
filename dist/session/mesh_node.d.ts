import { SessionPeer, type AckResult } from "./peer.js";
import type { Envelope } from "./envelope.js";
import type { Broker } from "./broker.js";
import { RelayClient } from "../transport/relay_client.js";
import type { Ed25519Keypair } from "./../pairing/crypto.js";
import type { MeshTopologySnapshot } from "../mesh/siblings.js";
/**
 * MeshNode is the composition point for the local UDS mesh plus the optional
 * cross-PC Relay bridge. Topology is retained independently from the current
 * role, Relay, Broker, or bridge publication lifecycle.
 */
/** Self-managed-relay bridge config (MCP path). */
export interface MeshSelfRelayBridge {
    /** Relay URL in http(s):// form (converted to ws(s):// internally). */
    relayUrl: string;
    /** cwd — derives the relay room id and the room_meta. */
    cwd: string;
    /** Display name for room_meta. Defaults to the assigned mesh name. */
    sessionName?: string;
    /** Advanced/test override; production defaults to five seconds per request. */
    meshRequestTimeoutMs?: number;
}
export interface MeshNodeOptions {
    /** UDS broker socket path (e.g. ~/.pi/remote/sessions/local/broker.sock). */
    sockPath: string;
    /** Requested mesh name (broker may add a #N collision suffix). */
    name: string;
    cwd?: string;
    takeoverExisting?: boolean;
    auditPath?: string;
    /** Self-managed relay bridge — brought up if this node leads. */
    bridge?: MeshSelfRelayBridge;
    /** Diagnostic logger. Defaults to a no-op (avoids leaking into TUIs). */
    log?: (msg: string) => void;
}
export type { AckResult } from "./peer.js";
export declare class MeshNode {
    private readonly peer_;
    private readonly log;
    private latestTopology;
    private topologyRevision;
    private bridgeGeneration;
    private bridgeAttachInFlight;
    private bridgeAttachQueued;
    private closed;
    private closeInFlight;
    private activeBridge;
    private relay;
    private relayOwned;
    private relayCloseHandler;
    private brokerRemote;
    private piForward;
    private keypair;
    private bridgeParams;
    private reconnectWired;
    private readonly closedOwnedRelays;
    /** Self-managed relay reconnect state. Injected Relay reconnect is host-owned. */
    private relayReconnectTimer;
    private relayBackoffIdx;
    private static readonly RELAY_RECONNECT_BACKOFFS_MS;
    constructor(opts: MeshNodeOptions);
    /** Join (or lead) the mesh. Resolves with the assigned name. */
    connect(): Promise<string>;
    /** Attach an externally-owned Relay. MeshNode never closes this Relay. */
    attachBridge(opts: {
        relay: RelayClient;
        relayUrl: string;
        keypair?: Ed25519Keypair;
        meshRequestTimeoutMs?: number;
    }): Promise<void>;
    /** Retain a canonical immutable topology independently from bridge state. */
    setTopology(snapshot: MeshTopologySnapshot): void;
    hasTopology(): boolean;
    /** Forget bridge parameters and tear down publication, retaining topology. */
    detachBridge(): void;
    private _assertOpen;
    private _wireReconnect;
    private _onReconnect;
    /** One serialized attach loop. Newer generations are drained before exit. */
    private _requestBridge;
    private _attemptBridge;
    private _attemptIsStale;
    private _relayIsClosed;
    private _removeMarker;
    private _closeOwnedRelay;
    private _teardownPublishedBridge;
    private _onSelfRelayClosed;
    private _clearRelayReconnectTimer;
    private _scheduleRelayReconnect;
    private _attemptRelayReconnect;
    /** Announce the local peer set to siblings (Pi broker peer_joined/left). */
    onLocalPeersChanged(local: string[]): void;
    /** True when the cross-PC relay bridge is active (this node is leader). */
    hasBridge(): boolean;
    /** The underlying SessionPeer — for consumers that need it directly (tools). */
    peer(): SessionPeer;
    /** Fire-and-forget send. `to` may be a name, `<pc>:<name>`, or "broadcast". */
    send(to: string | string[], body: unknown, re?: string | null): Promise<void>;
    /** Unicast send + await broker ACK (received/busy/denied/timeout). */
    sendWithAck(to: string, body: unknown, re?: string | null, timeoutMs?: number): Promise<AckResult>;
    /** Send + await the first reply whose `re` matches the outbound id. */
    request(to: string, body: unknown, timeoutMs?: number): Promise<Envelope>;
    /** Subscribe to inbound envelopes. Returns an unsubscribe fn. */
    onMessage(handler: (env: Envelope) => void): () => void;
    /** Subscribe to post-failover reconnects. Returns an unsubscribe fn. */
    onReconnect(handler: () => void): () => void;
    /** Assigned clean mesh name (after any #N collision suffix). */
    name(): string;
    /** Canonical mesh address (`[<pc>:]<cwd>@<nome>`) — echo, never compose. */
    address(): string;
    rename(newName: string): Promise<string>;
    currentRole(): "leader" | "follower";
    localBroker(): Broker | null;
    listPeers(timeoutMs?: number): Promise<string[]>;
    close(): Promise<void>;
}
