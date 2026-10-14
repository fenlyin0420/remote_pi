import { BrokerRemote } from "./broker_remote.js";
import { PiForwardClient } from "../transport/pi_forward_client.js";
import { MeshClient } from "../mesh/client.js";
import { buildTopologySnapshot, discoverTopology, } from "../mesh/siblings.js";
import { canonicalizeEd25519PublicKey, encodeEd25519PublicKey, } from "../mesh/encoding.js";
import { listOwnerPubkeys } from "../pairing/storage.js";
function compareAscii(left, right) {
    return left < right ? -1 : left > right ? 1 : 0;
}
function validateAlias(alias, field) {
    if (typeof alias !== "string" || alias.length === 0 || alias.includes(":")) {
        throw new Error(`mesh: ${field} is not a valid routing alias`);
    }
    return alias;
}
function validateLegacyPcLabel(label, field) {
    if (typeof label !== "string" || label.length === 0) {
        throw new Error(`mesh: ${field} is not a valid legacy PC label`);
    }
    return label;
}
function ownTopology(snapshot, expectedSelfPubkey) {
    const selfPubkey = canonicalizeEd25519PublicKey(snapshot.self?.pcPubkey, "self public key");
    if (selfPubkey !== expectedSelfPubkey) {
        throw new Error("mesh: topology self public key does not match relay identity");
    }
    const selfLabel = validateAlias(snapshot.self.pcLabel, "self.pcLabel");
    const selfLegacyPcLabel = validateLegacyPcLabel(snapshot.self.legacyPcLabel, "self.legacyPcLabel");
    const self = Object.freeze({
        pcLabel: selfLabel,
        pcPubkey: selfPubkey,
        legacyPcLabel: selfLegacyPcLabel,
    });
    const siblingKeys = new Set();
    const siblingAliases = new Set();
    const normalizedSiblings = [];
    for (const [index, sibling] of snapshot.siblings.entries()) {
        const pcPubkey = canonicalizeEd25519PublicKey(sibling.pcPubkey, `siblings[${index}].pcPubkey`);
        if (pcPubkey === selfPubkey)
            continue;
        const pcLabel = validateAlias(sibling.pcLabel, `siblings[${index}].pcLabel`);
        const legacyPcLabel = validateLegacyPcLabel(sibling.legacyPcLabel, `siblings[${index}].legacyPcLabel`);
        if (pcLabel === selfLabel || siblingAliases.has(pcLabel)) {
            throw new Error("mesh: duplicate sibling routing alias");
        }
        if (siblingKeys.has(pcPubkey)) {
            throw new Error("mesh: duplicate sibling public key");
        }
        siblingAliases.add(pcLabel);
        siblingKeys.add(pcPubkey);
        normalizedSiblings.push(Object.freeze({ pcLabel, pcPubkey, legacyPcLabel }));
    }
    normalizedSiblings.sort((left, right) => compareAscii(left.pcPubkey, right.pcPubkey));
    return Object.freeze({ self, siblings: Object.freeze(normalizedSiblings) });
}
async function discoverStandaloneTopology(opts) {
    const silent = { warn: (_message) => { } };
    try {
        const owners = await listOwnerPubkeys();
        return await discoverTopology({
            client: new MeshClient(opts.relayUrl, {
                ...(opts.meshRequestTimeoutMs !== undefined
                    ? { requestTimeoutMs: opts.meshRequestTimeoutMs }
                    : {}),
            }),
            ownerEpks: owners,
            myPubkey: opts.keypair.publicKey,
            log: silent,
        });
    }
    catch {
        return buildTopologySnapshot(opts.keypair.publicKey, []);
    }
}
export async function attachCrossPcBridge(opts) {
    const expectedSelfPubkey = encodeEd25519PublicKey(opts.keypair.publicKey, "relay public key");
    const topology = ownTopology(opts.topology ?? await discoverStandaloneTopology(opts), expectedSelfPubkey);
    // No Relay listeners exist until all standalone discovery has completed.
    const piForward = new PiForwardClient(opts.relay);
    let brokerRemote;
    try {
        brokerRemote = new BrokerRemote({
            broker: opts.broker,
            pi: piForward,
            topology,
            activateOnConstruct: false,
            log: opts.log ?? (() => { }),
        });
    }
    catch (error) {
        piForward.detach();
        throw error;
    }
    let state = "dormant";
    return {
        brokerRemote,
        piForward,
        topology,
        activate() {
            if (state !== "dormant")
                return;
            try {
                brokerRemote.activate();
                state = "active";
            }
            catch (error) {
                state = "detached";
                try {
                    brokerRemote.detach();
                }
                finally {
                    piForward.detach();
                }
                throw error;
            }
        },
        detach() {
            if (state === "detached")
                return;
            state = "detached";
            try {
                brokerRemote.detach();
            }
            finally {
                piForward.detach();
            }
        },
    };
}
//# sourceMappingURL=bridge.js.map