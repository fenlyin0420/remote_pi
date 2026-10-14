import { type MeshClient } from "./client.js";
import { type MeshTopologySnapshot } from "./siblings.js";
export interface SelfRevokeStorageSnapshotRecord {
    readonly rawOwnerPubkey: unknown;
    /** Storage-issued opaque provenance for this canonical Owner slot. */
    readonly token: unknown;
}
export type SelfRevokeRemovalResult = {
    readonly outcome: "removed";
    readonly nextToken: unknown;
} | {
    readonly outcome: "stale" | "not_found" | "no_authority";
};
export interface SelfRevokeStorage {
    snapshotOwnerPubkeys(): Promise<readonly SelfRevokeStorageSnapshotRecord[]>;
    conditionalRemovePeer(remoteEpk: string, expectedToken: unknown, canCommit?: () => boolean): Promise<SelfRevokeRemovalResult>;
}
export interface SelfRevokeOptions {
    client: MeshClient;
    storage: SelfRevokeStorage;
    /** This Pi's long-term Ed25519 pubkey, raw 32 bytes. */
    myPubkey: Uint8Array;
    intervalMs?: number;
    /** Raw storage handle first; canonical runtime Owner identity second. */
    onRevoke?: (rawOwnerPubkey: string, canonicalOwnerPubkey: string) => void | Promise<void>;
    onAuthoritativeOwners?: (canonicalOwnerPubkeys: readonly string[]) => void | Promise<void>;
    onTopologyChanged?: (snapshot: MeshTopologySnapshot) => void | Promise<void>;
    log?: {
        info(msg: string): void;
        warn(msg: string): void;
        error(msg: string): void;
    };
}
export declare class SelfRevoke {
    private readonly client;
    private readonly storage;
    private readonly myPubkey;
    private readonly intervalMs;
    private readonly onRevoke?;
    private readonly onAuthoritativeOwners?;
    private readonly onTopologyChanged?;
    private readonly log;
    /**
     * Accepted anti-rollback floor, deliberately independent from pending I/O.
     * https://github.com/jacobaraujo7/remote_pi/issues/73: this in-memory floor
     * resets on process restart, allowing pre-revocation membership replay.
     */
    private readonly lastSeenVersion;
    private readonly pendingRevocations;
    private readonly membershipByOwner;
    private previousTopology;
    private sweepInFlight;
    private timer;
    /** Invalidates authority held by an async sweep when this producer stops/re-pairs. */
    private lifecycleGeneration;
    constructor(opts: SelfRevokeOptions);
    start(): void;
    stop(): void;
    /** Called before a same-process pairing mutation enters the storage lane. */
    invalidateStorageAuthority(): void;
    /** Schedules one post-mutation authoritative sweep after any stale sweep exits. */
    requestFreshCheck(): Promise<void>;
    checkOnce(): Promise<void>;
    private _runSweep;
    private _hasAuthority;
    private _canonicalOwnerSlots;
    private _pruneStateNotIn;
    private _checkOwnerSlot;
    /** Returns true only when storage proves the pending snapshot was re-paired. */
    private _retryPending;
    private _invokeRevokeCallback;
    private _publishTopology;
}
