import type { Broker, PeerInfo, RemoteRouter } from "./broker.js";
import { type Envelope } from "./envelope.js";
import type { PiForwardClient } from "../transport/pi_forward_client.js";
import type { MeshTopologySnapshot } from "../mesh/siblings.js";
export interface WirePeerInfo {
    cwd: string;
    name: string;
    address: string;
}
export interface RemotePeerEntry {
    infos: WirePeerInfo[];
    pcPubkey: string;
    ts: number;
}
export interface BrokerRemoteOptions {
    broker: Broker;
    pi: PiForwardClient;
    topology: MeshTopologySnapshot;
    cacheTtlMs?: number;
    reannounceIntervalMs?: number;
    log?: (msg: string) => void;
    /** Defaults true for compatibility; Task 6 bridge construction passes false. */
    activateOnConstruct?: boolean;
}
export interface BrokerRemoteLifecycle {
    activate(): void;
    setTopology(next: MeshTopologySnapshot): void;
}
export declare class BrokerRemote implements RemoteRouter, BrokerRemoteLifecycle {
    private readonly broker;
    private readonly pi;
    private readonly technicalSelfPubkey;
    private readonly cacheTtlMs;
    private readonly reannounceIntervalMs;
    private readonly log;
    private routing;
    /** Canonical sibling pubkey → cached local roster. */
    private readonly remotePeers;
    /** Canonical sibling pubkeys whose active topology refresh must be retried. */
    private readonly topologyRefreshNeeded;
    /** Canonical sibling pubkey → in-flight roster fills. */
    private readonly pendingFills;
    private readonly onIncoming;
    private reannounceTimer;
    private lifecycle;
    constructor(opts: BrokerRemoteOptions);
    activate(): void;
    detach(): void;
    setTopology(next: MeshTopologySnapshot): void;
    private _bootstrapWithSiblings;
    private _localPeersBody;
    private _remoteInfosByPubkey;
    getRemotePeers(pcLabel: string): string[];
    getAllRemote(): Record<string, string[]>;
    listRemotePeers(): string[];
    listRemotePeerInfos(): PeerInfo[];
    onLocalPeersChanged(_peers: string[]): void;
    tryRouteOutbound(env: Envelope): boolean;
    private _routeToCanonicalSibling;
    handleIncoming(env: Envelope, fromPc: string): void;
    private _setRemoteCache;
    private _awaitPeersFill;
    private _clearPendingFills;
    private _clearAllPendingFills;
    private _propagateTransportError;
    private _sendControlEnvelope;
    private _legacyLabelForPubkey;
    private _dropMetadataOnly;
    private _logMetadataOnly;
}
export declare function parseAddress(to: string): {
    pcLabel: string;
    peerName: string;
} | null;
