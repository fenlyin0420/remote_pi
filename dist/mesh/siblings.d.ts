import type { MeshClient } from "./client.js";
export interface PiRoutingIdentity {
    readonly pcPubkey: string;
    /** Receiver-local display and routing alias. */
    readonly pcLabel: string;
    /** Raw legacy cross-PC wire prefix; distinct from the receiver-local alias. */
    readonly legacyPcLabel: string;
}
export interface MeshTopologySnapshot {
    readonly self: PiRoutingIdentity;
    readonly siblings: readonly PiRoutingIdentity[];
}
export interface BoundOwnerMembership {
    /** Canonical standard-padded string derived from MeshHeader.ownerPk bytes. */
    readonly ownerPubkey: string;
    readonly members: readonly {
        readonly pcPubkey: string;
        readonly nickname?: string;
    }[];
}
/** Legacy mutable shape retained through the Task 4 compatibility window. */
export interface SiblingPi {
    pcLabel: string;
    pcPubkey: string;
}
export interface DiscoverSelfLabelResult {
    selfPcLabel: string;
}
export interface DiscoverOptions {
    client: MeshClient;
    ownerEpks: readonly unknown[];
    myPubkey: Uint8Array;
    log?: {
        warn(msg: string): void;
    };
}
/**
 * Builds one deterministic direct-co-membership topology for self and siblings.
 * Memberships that do not themselves contain self contribute nothing.
 */
export declare function buildTopologySnapshot(myPubkey: Uint8Array, memberships: Iterable<BoundOwnerMembership>): MeshTopologySnapshot;
/** Discovers one bound, direct, canonical topology from raw Owner records. */
export declare function discoverTopology(opts: DiscoverOptions): Promise<MeshTopologySnapshot>;
/** Compatibility fallback now follows the routing-alias grammar. */
export declare function fallbackLabel(pcPubkey: string): string;
/** Compatibility wrapper over the atomic topology producer. */
export declare function discoverSelfLabel(opts: DiscoverOptions): Promise<DiscoverSelfLabelResult>;
/** Compatibility wrapper over the atomic topology producer. */
export declare function discoverSiblings(opts: DiscoverOptions): Promise<SiblingPi[]>;
