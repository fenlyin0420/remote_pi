import { createHash } from "node:crypto";
import { allocateRoutingAliases, bytesEqual, canonicalizeEd25519PublicKey, decodeEd25519PublicKey, encodeEd25519PublicKey, publicKeyFingerprint, selectRoutingNickname, toBase64UrlNoPad, } from "./encoding.js";
import { verifyEnvelope } from "./verify.js";
function compareAscii(left, right) {
    return left < right ? -1 : left > right ? 1 : 0;
}
function freezeIdentity(pcPubkey, pcLabel, legacyPcLabel) {
    return Object.freeze({ pcPubkey, pcLabel, legacyPcLabel });
}
/**
 * Builds one deterministic direct-co-membership topology for self and siblings.
 * Memberships that do not themselves contain self contribute nothing.
 */
export function buildTopologySnapshot(myPubkey, memberships) {
    const selfPubkey = encodeEd25519PublicKey(myPubkey, "self public key");
    const nicknamesByKey = new Map([[selfPubkey, []]]);
    for (const membership of memberships) {
        canonicalizeEd25519PublicKey(membership.ownerPubkey, "membership.ownerPubkey");
        const normalizedMembers = membership.members.map((member, index) => {
            if (member.nickname !== undefined &&
                typeof member.nickname !== "string") {
                throw new Error(`mesh: membership.members[${index}].nickname invalid`);
            }
            return {
                pcPubkey: canonicalizeEd25519PublicKey(member.pcPubkey, `membership.members[${index}].pcPubkey`),
                nickname: member.nickname,
            };
        });
        if (!normalizedMembers.some((member) => member.pcPubkey === selfPubkey)) {
            continue;
        }
        for (const member of normalizedMembers) {
            const candidates = nicknamesByKey.get(member.pcPubkey) ?? [];
            if (!nicknamesByKey.has(member.pcPubkey)) {
                nicknamesByKey.set(member.pcPubkey, candidates);
            }
            if (member.nickname)
                candidates.push(member.nickname);
        }
    }
    const selectedNicknames = new Map([...nicknamesByKey.entries()].map(([pcPubkey, candidates]) => [
        pcPubkey,
        selectRoutingNickname(candidates),
    ]));
    const aliases = allocateRoutingAliases([...selectedNicknames.entries()].map(([pcPubkey, nickname]) => ({
        pcPubkey,
        ...(nickname !== undefined ? { nickname } : {}),
    })));
    const selfLabel = aliases.get(selfPubkey);
    if (!selfLabel) {
        throw new Error("mesh: topology self alias invariant failed");
    }
    const siblings = [...aliases.entries()]
        .filter(([pcPubkey]) => pcPubkey !== selfPubkey)
        .sort(([left], [right]) => compareAscii(left, right))
        .map(([pcPubkey, pcLabel]) => freezeIdentity(pcPubkey, pcLabel, selectedNicknames.get(pcPubkey) ?? pcPubkey.slice(0, 8)));
    return Object.freeze({
        self: freezeIdentity(selfPubkey, selfLabel, selectedNicknames.get(selfPubkey) ?? selfPubkey.slice(0, 8)),
        siblings: Object.freeze(siblings),
    });
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
function canonicalOwnerSlots(rawOwners, log) {
    const slots = new Map();
    for (const rawOwner of rawOwners) {
        if (typeof rawOwner !== "string") {
            log.warn(`[mesh] event=invalid_owner_record owner_fp=${rawOwnerFingerprint(rawOwner)}`);
            continue;
        }
        try {
            const ownerPk = decodeEd25519PublicKey(rawOwner, "Owner record");
            const canonicalOwnerPubkey = encodeEd25519PublicKey(ownerPk);
            if (!slots.has(canonicalOwnerPubkey)) {
                slots.set(canonicalOwnerPubkey, {
                    canonicalOwnerPubkey,
                    ownerPk,
                    fingerprint: publicKeyFingerprint(ownerPk),
                });
            }
        }
        catch {
            log.warn(`[mesh] event=invalid_owner_record owner_fp=${rawOwnerFingerprint(rawOwner)}`);
        }
    }
    return [...slots.values()].sort((left, right) => compareAscii(left.canonicalOwnerPubkey, right.canonicalOwnerPubkey));
}
/** Discovers one bound, direct, canonical topology from raw Owner records. */
export async function discoverTopology(opts) {
    const log = opts.log ?? { warn: (message) => console.warn(message) };
    const selfPubkey = encodeEd25519PublicKey(opts.myPubkey, "self public key");
    const memberships = [];
    for (const slot of canonicalOwnerSlots(opts.ownerEpks, log)) {
        try {
            const hash = createHash("sha256").update(slot.ownerPk).digest("hex");
            const envelope = await opts.client.get(hash);
            if (!envelope)
                continue;
            const header = await verifyEnvelope(envelope);
            if (!bytesEqual(header.ownerPk, slot.ownerPk)) {
                log.warn(`[mesh] event=owner_slot_mismatch owner_fp=${slot.fingerprint}`);
                continue;
            }
            if (!header.members.some((member) => member.remoteEpk === selfPubkey)) {
                continue;
            }
            memberships.push({
                ownerPubkey: encodeEd25519PublicKey(header.ownerPk),
                members: header.members.map((member) => ({
                    pcPubkey: member.remoteEpk,
                    ...(member.nickname !== undefined
                        ? { nickname: member.nickname }
                        : {}),
                })),
            });
        }
        catch {
            log.warn(`[mesh] event=owner_discovery_failed owner_fp=${slot.fingerprint}`);
        }
    }
    return buildTopologySnapshot(opts.myPubkey, memberships);
}
/** Compatibility fallback now follows the routing-alias grammar. */
export function fallbackLabel(pcPubkey) {
    const bytes = decodeEd25519PublicKey(pcPubkey, "pcPubkey");
    return `pc-${toBase64UrlNoPad(bytes).slice(0, 8)}`;
}
/** Compatibility wrapper over the atomic topology producer. */
export async function discoverSelfLabel(opts) {
    const topology = await discoverTopology(opts);
    return { selfPcLabel: topology.self.pcLabel };
}
/** Compatibility wrapper over the atomic topology producer. */
export async function discoverSiblings(opts) {
    const topology = await discoverTopology(opts);
    return topology.siblings.map(({ pcLabel, pcPubkey }) => ({
        pcLabel,
        pcPubkey,
    }));
}
//# sourceMappingURL=siblings.js.map