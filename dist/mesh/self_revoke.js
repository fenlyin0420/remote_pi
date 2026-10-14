import { createHash } from "node:crypto";
import { MeshFetchInvalidResponseError, MeshFetchUnavailableError, } from "./client.js";
import { bytesEqual, decodeEd25519PublicKey, encodeEd25519PublicKey, publicKeyFingerprint, } from "./encoding.js";
import { buildTopologySnapshot, } from "./siblings.js";
import { verifyEnvelope } from "./verify.js";
const DEFAULT_INTERVAL_MS = 60_000;
function compareAscii(left, right) {
    return left < right ? -1 : left > right ? 1 : 0;
}
function rawOwnerFingerprint(rawOwner) {
    let fingerprintInput;
    if (typeof rawOwner === "string") {
        fingerprintInput = rawOwner;
    }
    else {
        try {
            const serialized = JSON.stringify(rawOwner);
            const type = rawOwner === null ? "null" : typeof rawOwner;
            fingerprintInput = `${type}:${serialized ?? ""}`;
        }
        catch {
            fingerprintInput = `${typeof rawOwner}:unserializable`;
        }
    }
    return createHash("sha256")
        .update(fingerprintInput, "utf8")
        .digest("hex")
        .slice(0, 8);
}
function topologyEquals(left, right) {
    if (!left)
        return false;
    if (left.self.pcPubkey !== right.self.pcPubkey ||
        left.self.pcLabel !== right.self.pcLabel ||
        left.self.legacyPcLabel !== right.self.legacyPcLabel ||
        left.siblings.length !== right.siblings.length)
        return false;
    return left.siblings.every((identity, index) => {
        const other = right.siblings[index];
        return other !== undefined &&
            identity.pcPubkey === other.pcPubkey &&
            identity.pcLabel === other.pcLabel &&
            identity.legacyPcLabel === other.legacyPcLabel;
    });
}
export class SelfRevoke {
    client;
    storage;
    myPubkey;
    intervalMs;
    onRevoke;
    onAuthoritativeOwners;
    onTopologyChanged;
    log;
    /**
     * Accepted anti-rollback floor, deliberately independent from pending I/O.
     * https://github.com/jacobaraujo7/remote_pi/issues/73: this in-memory floor
     * resets on process restart, allowing pre-revocation membership replay.
     */
    lastSeenVersion = new Map();
    pendingRevocations = new Map();
    membershipByOwner = new Map();
    previousTopology = null;
    sweepInFlight = null;
    timer = null;
    /** Invalidates authority held by an async sweep when this producer stops/re-pairs. */
    lifecycleGeneration = 0;
    constructor(opts) {
        this.client = opts.client;
        this.storage = opts.storage;
        this.myPubkey = new Uint8Array(opts.myPubkey);
        encodeEd25519PublicKey(this.myPubkey, "self public key");
        this.intervalMs = opts.intervalMs ?? DEFAULT_INTERVAL_MS;
        this.onRevoke = opts.onRevoke;
        this.onAuthoritativeOwners = opts.onAuthoritativeOwners;
        this.onTopologyChanged = opts.onTopologyChanged;
        this.log = opts.log ?? {
            info: (message) => console.info(message),
            warn: (message) => console.warn(message),
            error: (message) => console.error(message),
        };
    }
    start() {
        if (this.timer !== null)
            return;
        void this.checkOnce().catch(() => this.log.error("[mesh] event=self_revoke_sweep_failed"));
        this.timer = setInterval(() => {
            void this.checkOnce().catch(() => this.log.error("[mesh] event=self_revoke_sweep_failed"));
        }, this.intervalMs);
    }
    stop() {
        this.invalidateStorageAuthority();
        if (this.timer !== null) {
            clearInterval(this.timer);
            this.timer = null;
        }
    }
    /** Called before a same-process pairing mutation enters the storage lane. */
    invalidateStorageAuthority() {
        this.lifecycleGeneration += 1;
    }
    /** Schedules one post-mutation authoritative sweep after any stale sweep exits. */
    requestFreshCheck() {
        const prior = this.sweepInFlight;
        if (!prior)
            return this.checkOnce();
        return prior.catch(() => undefined).then(() => this.checkOnce());
    }
    checkOnce() {
        if (this.sweepInFlight)
            return this.sweepInFlight;
        const generation = this.lifecycleGeneration;
        const sweep = this._runSweep(generation).finally(() => {
            if (this.sweepInFlight === sweep)
                this.sweepInFlight = null;
        });
        this.sweepInFlight = sweep;
        return sweep;
    }
    async _runSweep(generation) {
        let snapshot;
        try {
            snapshot = await this.storage.snapshotOwnerPubkeys();
        }
        catch {
            if (!this._hasAuthority(generation))
                return;
            this.log.error("[mesh] event=owner_list_unavailable");
            await this._publishTopology(buildTopologySnapshot(this.myPubkey, this.membershipByOwner.values()), generation);
            return;
        }
        if (!this._hasAuthority(generation))
            return;
        const slots = this._canonicalOwnerSlots(snapshot);
        if (this.onAuthoritativeOwners) {
            if (!this._hasAuthority(generation))
                return;
            try {
                await this.onAuthoritativeOwners(slots.map((slot) => slot.canonicalOwnerPubkey));
            }
            catch {
                if (this._hasAuthority(generation)) {
                    this.log.error("[mesh] event=authoritative_owners_callback_failed");
                }
            }
            if (!this._hasAuthority(generation))
                return;
        }
        await this._pruneStateNotIn(slots, generation);
        if (!this._hasAuthority(generation))
            return;
        for (const slot of slots) {
            const staleResponse = await this._checkOwnerSlot(slot, generation);
            if (!this._hasAuthority(generation) || staleResponse)
                return;
        }
        await this._publishTopology(buildTopologySnapshot(this.myPubkey, this.membershipByOwner.values()), generation);
    }
    _hasAuthority(generation) {
        return generation === this.lifecycleGeneration;
    }
    _canonicalOwnerSlots(snapshot) {
        const rawHandlesByCanonical = new Map();
        const bytesByCanonical = new Map();
        for (const record of snapshot) {
            const rawOwner = record.rawOwnerPubkey;
            if (typeof rawOwner !== "string") {
                this.log.warn(`[mesh] event=invalid_owner_record owner_fp=${rawOwnerFingerprint(rawOwner)}`);
                continue;
            }
            try {
                const ownerPk = decodeEd25519PublicKey(rawOwner, "Owner record");
                const canonical = encodeEd25519PublicKey(ownerPk);
                const handles = rawHandlesByCanonical.get(canonical) ?? new Map();
                handles.set(rawOwner, record.token);
                rawHandlesByCanonical.set(canonical, handles);
                if (!bytesByCanonical.has(canonical))
                    bytesByCanonical.set(canonical, ownerPk);
            }
            catch {
                this.log.warn(`[mesh] event=invalid_owner_record owner_fp=${rawOwnerFingerprint(rawOwner)}`);
            }
        }
        return [...rawHandlesByCanonical.entries()]
            .sort(([left], [right]) => compareAscii(left, right))
            .map(([canonicalOwnerPubkey, handles]) => {
            const ownerPk = bytesByCanonical.get(canonicalOwnerPubkey);
            return {
                canonicalOwnerPubkey,
                rawOwnerPubkeys: [...handles.entries()]
                    .sort(([left], [right]) => compareAscii(left, right))
                    .map(([rawOwnerPubkey, token]) => ({ rawOwnerPubkey, token })),
                ownerPk,
                fingerprint: publicKeyFingerprint(ownerPk),
            };
        });
    }
    async _pruneStateNotIn(slots, generation) {
        const currentOwners = new Set(slots.map((slot) => slot.canonicalOwnerPubkey));
        for (const [owner, pending] of [...this.pendingRevocations]) {
            if (currentOwners.has(owner))
                continue;
            for (const rawOwnerPubkey of [...pending.rawOwnerTokens.keys()]) {
                if (!this._hasAuthority(generation))
                    return;
                pending.rawOwnerTokens.delete(rawOwnerPubkey);
                await this._invokeRevokeCallback(rawOwnerPubkey, owner, pending.fingerprint, generation);
                if (!this._hasAuthority(generation))
                    return;
            }
            if (pending.rawOwnerTokens.size === 0) {
                this.pendingRevocations.delete(owner);
            }
        }
        for (const owner of this.membershipByOwner.keys()) {
            if (!currentOwners.has(owner) && !this.pendingRevocations.has(owner)) {
                this.membershipByOwner.delete(owner);
            }
        }
        for (const owner of this.lastSeenVersion.keys()) {
            if (!currentOwners.has(owner) && !this.pendingRevocations.has(owner)) {
                this.lastSeenVersion.delete(owner);
            }
        }
    }
    async _checkOwnerSlot(slot, generation) {
        const since = this.lastSeenVersion.get(slot.canonicalOwnerPubkey);
        const hash = createHash("sha256").update(slot.ownerPk).digest("hex");
        let envelope;
        try {
            envelope = await this.client.get(hash, since);
        }
        catch (error) {
            if (!this._hasAuthority(generation))
                return false;
            const stale = await this._retryPending(slot, generation);
            if (stale || !this._hasAuthority(generation))
                return stale;
            if (error instanceof MeshFetchUnavailableError) {
                this.log.warn(`[mesh] event=owner_fetch_unavailable owner_fp=${slot.fingerprint}`);
                return false;
            }
            this.membershipByOwner.delete(slot.canonicalOwnerPubkey);
            const event = error instanceof MeshFetchInvalidResponseError ? "owner_fetch_invalid" : "owner_fetch_failed";
            this.log.warn(`[mesh] event=${event} owner_fp=${slot.fingerprint}`);
            return false;
        }
        if (!this._hasAuthority(generation))
            return false;
        if (!envelope)
            return this._retryPending(slot, generation);
        let header;
        try {
            header = await verifyEnvelope(envelope);
        }
        catch {
            if (!this._hasAuthority(generation))
                return false;
            this.membershipByOwner.delete(slot.canonicalOwnerPubkey);
            this.log.warn(`[mesh] event=owner_envelope_invalid owner_fp=${slot.fingerprint}`);
            return this._retryPending(slot, generation);
        }
        if (!this._hasAuthority(generation))
            return false;
        if (!bytesEqual(header.ownerPk, slot.ownerPk)) {
            this.membershipByOwner.delete(slot.canonicalOwnerPubkey);
            this.log.warn(`[mesh] event=owner_slot_mismatch owner_fp=${slot.fingerprint}`);
            return this._retryPending(slot, generation);
        }
        const lastSeen = this.lastSeenVersion.get(slot.canonicalOwnerPubkey);
        if (lastSeen !== undefined && header.version <= lastSeen) {
            this.log.warn(`[mesh] event=owner_rollback owner_fp=${slot.fingerprint} received_version=${header.version} retained_version=${lastSeen}`);
            return this._retryPending(slot, generation);
        }
        const membership = {
            ownerPubkey: encodeEd25519PublicKey(header.ownerPk),
            members: header.members.map((member) => ({
                pcPubkey: member.remoteEpk,
                ...(member.nickname !== undefined ? { nickname: member.nickname } : {}),
            })),
        };
        const selfPubkey = encodeEd25519PublicKey(this.myPubkey);
        const stillMember = membership.members.some((member) => member.pcPubkey === selfPubkey);
        if (!this._hasAuthority(generation))
            return false;
        if (stillMember) {
            // A newer self-including envelope supersedes any older pending revoke.
            this.pendingRevocations.delete(slot.canonicalOwnerPubkey);
            this.lastSeenVersion.set(slot.canonicalOwnerPubkey, header.version);
            this.membershipByOwner.set(slot.canonicalOwnerPubkey, membership);
            return false;
        }
        const previousVersion = this.lastSeenVersion.get(slot.canonicalOwnerPubkey);
        this.lastSeenVersion.set(slot.canonicalOwnerPubkey, header.version);
        this.membershipByOwner.delete(slot.canonicalOwnerPubkey);
        this.pendingRevocations.set(slot.canonicalOwnerPubkey, {
            version: header.version,
            previousVersion,
            fingerprint: slot.fingerprint,
            rawOwnerTokens: new Map(slot.rawOwnerPubkeys.map(({ rawOwnerPubkey, token }) => [rawOwnerPubkey, token])),
        });
        this.log.info(`[mesh] event=self_revoked owner_fp=${slot.fingerprint} received_version=${header.version} since=${since ?? "none"} member_count=${header.members.length}`);
        const stale = await this._retryPending(slot, generation);
        if (stale) {
            // This signed response authorized the old pairing snapshot only. Do not
            // retain its floor, pending work, or topology contribution for a re-pair.
            this.pendingRevocations.delete(slot.canonicalOwnerPubkey);
            if (previousVersion === undefined)
                this.lastSeenVersion.delete(slot.canonicalOwnerPubkey);
            else
                this.lastSeenVersion.set(slot.canonicalOwnerPubkey, previousVersion);
            return true;
        }
        return false;
    }
    /** Returns true only when storage proves the pending snapshot was re-paired. */
    async _retryPending(slot, generation) {
        const pending = this.pendingRevocations.get(slot.canonicalOwnerPubkey);
        if (!pending)
            return false;
        for (const rawOwnerPubkey of [...pending.rawOwnerTokens.keys()]) {
            if (!this._hasAuthority(generation))
                return false;
            let result;
            try {
                const expectedToken = pending.rawOwnerTokens.get(rawOwnerPubkey);
                result = await this.storage.conditionalRemovePeer(rawOwnerPubkey, expectedToken, () => this._hasAuthority(generation));
            }
            catch {
                if (this._hasAuthority(generation)) {
                    this.log.error(`[mesh] event=owner_storage_remove_failed owner_fp=${slot.fingerprint}`);
                }
                return false;
            }
            if (!this._hasAuthority(generation))
                return false;
            if (result.outcome === "stale") {
                // The accepted revocation belonged to an old pairing snapshot. Its
                // floor must not suppress a current replacement envelope, but the
                // already-pruned topology stays fail-closed until that envelope wins.
                this.pendingRevocations.delete(slot.canonicalOwnerPubkey);
                if (pending.previousVersion === undefined) {
                    this.lastSeenVersion.delete(slot.canonicalOwnerPubkey);
                }
                else {
                    this.lastSeenVersion.set(slot.canonicalOwnerPubkey, pending.previousVersion);
                }
                return true;
            }
            if (result.outcome === "no_authority")
                return false;
            // The remaining terminal outcomes are exact local removal or an
            // authoritative strict-read absence, applied fail-closed to this runtime.
            // This intentionally does not claim durable cross-process re-pair provenance.
            pending.rawOwnerTokens.delete(rawOwnerPubkey);
            if (result.outcome === "removed") {
                for (const remainingRawOwner of pending.rawOwnerTokens.keys()) {
                    pending.rawOwnerTokens.set(remainingRawOwner, result.nextToken);
                }
            }
            await this._invokeRevokeCallback(rawOwnerPubkey, slot.canonicalOwnerPubkey, pending.fingerprint, generation);
            if (!this._hasAuthority(generation))
                return false;
        }
        if (pending.rawOwnerTokens.size === 0) {
            this.pendingRevocations.delete(slot.canonicalOwnerPubkey);
        }
        return false;
    }
    async _invokeRevokeCallback(rawOwnerPubkey, canonicalOwnerPubkey, fingerprint, generation) {
        if (!this._hasAuthority(generation) || !this.onRevoke)
            return;
        try {
            await this.onRevoke(rawOwnerPubkey, canonicalOwnerPubkey);
        }
        catch {
            if (this._hasAuthority(generation)) {
                this.log.error(`[mesh] event=owner_revoke_callback_failed owner_fp=${fingerprint}`);
            }
        }
    }
    async _publishTopology(next, generation) {
        if (!this._hasAuthority(generation) || topologyEquals(this.previousTopology, next))
            return;
        try {
            if (this.onTopologyChanged) {
                if (!this._hasAuthority(generation))
                    return;
                await this.onTopologyChanged(next);
            }
        }
        catch {
            if (this._hasAuthority(generation))
                this.log.error("[mesh] event=topology_callback_failed");
            return;
        }
        if (this._hasAuthority(generation))
            this.previousTopology = next;
    }
}
//# sourceMappingURL=self_revoke.js.map