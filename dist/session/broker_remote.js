import { asTransportErrorBody, envelope, isUuid, parse, serialize, uuidv7, } from "./envelope.js";
import { canonicalizeEd25519PublicKey, decodeEd25519PublicKey, encodeEd25519PublicKey, publicKeyFingerprint, } from "../mesh/encoding.js";
import { isBoundedPeerAddresses, isBoundedPeerRoster, } from "./peer_limits.js";
const CACHE_TTL_MS = 5 * 60_000;
const PEERS_REQUEST_TIMEOUT_MS = 2_000;
const REANNOUNCE_INTERVAL_MS = 2 * 60_000;
const BROKER_NAME = "broker";
const LEGACY_RELAY_ID_RE = /^[0-9a-f]{32}$/;
function compareAscii(left, right) {
    return left < right ? -1 : left > right ? 1 : 0;
}
function validateAlias(alias, field) {
    if (typeof alias !== "string" ||
        alias.length === 0 ||
        alias.includes(":")) {
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
function buildRoutingState(topology, expectedSelfPubkey) {
    const selfLabel = validateAlias(topology.self?.pcLabel, "self.pcLabel");
    const selfLegacyPcLabel = validateLegacyPcLabel(topology.self?.legacyPcLabel, "self.legacyPcLabel");
    const selfPubkey = canonicalizeEd25519PublicKey(topology.self?.pcPubkey, "self public key");
    if (expectedSelfPubkey && selfPubkey !== expectedSelfPubkey) {
        throw new Error("mesh: self public key cannot change");
    }
    const normalizedSiblings = topology.siblings
        .map((sibling, index) => ({
        pcLabel: validateAlias(sibling?.pcLabel, `siblings[${index}].pcLabel`),
        legacyPcLabel: validateLegacyPcLabel(sibling?.legacyPcLabel, `siblings[${index}].legacyPcLabel`),
        pcPubkey: canonicalizeEd25519PublicKey(sibling?.pcPubkey, `siblings[${index}].pcPubkey`),
    }))
        .filter((sibling) => sibling.pcPubkey !== selfPubkey)
        .sort((left, right) => compareAscii(left.pcPubkey, right.pcPubkey));
    const siblingByLabel = new Map();
    const siblingByPubkey = new Map();
    const siblingLegacyLabelByPubkey = new Map();
    for (const sibling of normalizedSiblings) {
        if (sibling.pcLabel === selfLabel) {
            throw new Error("mesh: sibling routing alias conflicts with self");
        }
        if (siblingByPubkey.has(sibling.pcPubkey)) {
            throw new Error("mesh: duplicate sibling public key");
        }
        if (siblingByLabel.has(sibling.pcLabel)) {
            throw new Error("mesh: duplicate sibling routing alias");
        }
        siblingByLabel.set(sibling.pcLabel, sibling.pcPubkey);
        siblingByPubkey.set(sibling.pcPubkey, sibling.pcLabel);
        siblingLegacyLabelByPubkey.set(sibling.pcPubkey, sibling.legacyPcLabel);
    }
    return {
        self: Object.freeze({
            pcLabel: selfLabel,
            pcPubkey: selfPubkey,
            legacyPcLabel: selfLegacyPcLabel,
        }),
        siblingByLabel,
        siblingByPubkey,
        siblingLegacyLabelByPubkey,
    };
}
export class BrokerRemote {
    broker;
    pi;
    technicalSelfPubkey;
    cacheTtlMs;
    reannounceIntervalMs;
    log;
    routing;
    /** Canonical sibling pubkey → cached local roster. */
    remotePeers = new Map();
    /** Canonical sibling pubkeys whose active topology refresh must be retried. */
    topologyRefreshNeeded = new Set();
    /** Canonical sibling pubkey → in-flight roster fills. */
    pendingFills = new Map();
    onIncoming;
    reannounceTimer = null;
    lifecycle = "dormant";
    constructor(opts) {
        this.broker = opts.broker;
        this.pi = opts.pi;
        this.routing = buildRoutingState(opts.topology);
        this.technicalSelfPubkey = this.routing.self.pcPubkey;
        this.cacheTtlMs = opts.cacheTtlMs ?? CACHE_TTL_MS;
        this.reannounceIntervalMs =
            opts.reannounceIntervalMs ?? REANNOUNCE_INTERVAL_MS;
        this.log = opts.log ?? ((message) => console.error(message));
        this.onIncoming = (env, fromPc) => this.handleIncoming(env, fromPc);
        if (opts.activateOnConstruct !== false)
            this.activate();
    }
    activate() {
        if (this.lifecycle === "active")
            return;
        if (this.lifecycle === "detached") {
            throw new Error("mesh: BrokerRemote is detached");
        }
        try {
            this.pi.on("envelope", this.onIncoming);
            this.broker.setRemoteRouter(this);
            this._bootstrapWithSiblings();
            this.topologyRefreshNeeded.clear();
            if (this.reannounceIntervalMs > 0) {
                this.reannounceTimer = setInterval(() => {
                    if (this.lifecycle !== "active" ||
                        this.routing.siblingByPubkey.size === 0) {
                        return;
                    }
                    try {
                        this._bootstrapWithSiblings();
                        this.topologyRefreshNeeded.clear();
                    }
                    catch {
                        this._logMetadataOnly("[broker_remote] event=reannounce_failed reason=send_failure");
                    }
                }, this.reannounceIntervalMs);
                this.reannounceTimer.unref?.();
            }
            this.lifecycle = "active";
        }
        catch (error) {
            if (this.reannounceTimer) {
                clearInterval(this.reannounceTimer);
                this.reannounceTimer = null;
            }
            try {
                this.pi.off("envelope", this.onIncoming);
            }
            catch {
                // best-effort rollback
            }
            try {
                this.broker.clearRemoteRouter(this);
            }
            catch {
                // preserve the activation error
            }
            this.lifecycle = "detached";
            throw error;
        }
    }
    detach() {
        if (this.lifecycle === "detached")
            return;
        const wasActive = this.lifecycle === "active";
        this.lifecycle = "detached";
        if (this.reannounceTimer) {
            clearInterval(this.reannounceTimer);
            this.reannounceTimer = null;
        }
        this._clearAllPendingFills();
        this.topologyRefreshNeeded.clear();
        if (!wasActive)
            return;
        this.pi.off("envelope", this.onIncoming);
        this.broker.clearRemoteRouter(this);
    }
    setTopology(next) {
        if (this.lifecycle === "detached") {
            throw new Error("mesh: BrokerRemote is detached");
        }
        const previous = this.routing;
        const replacement = buildRoutingState(next, this.technicalSelfPubkey);
        for (const pcPubkey of [...this.remotePeers.keys()]) {
            if (!replacement.siblingByPubkey.has(pcPubkey)) {
                this.remotePeers.delete(pcPubkey);
            }
        }
        for (const pcPubkey of [...this.pendingFills.keys()]) {
            if (!replacement.siblingByPubkey.has(pcPubkey)) {
                this._clearPendingFills(pcPubkey);
            }
        }
        for (const pcPubkey of [...this.topologyRefreshNeeded]) {
            if (!replacement.siblingByPubkey.has(pcPubkey)) {
                this.topologyRefreshNeeded.delete(pcPubkey);
            }
        }
        this.routing = replacement;
        if (this.lifecycle !== "active")
            return;
        const refreshKeys = new Set(this.topologyRefreshNeeded);
        for (const [pcPubkey, alias] of replacement.siblingByPubkey) {
            if (previous.siblingByPubkey.get(pcPubkey) !== alias ||
                previous.siblingLegacyLabelByPubkey.get(pcPubkey) !==
                    replacement.siblingLegacyLabelByPubkey.get(pcPubkey)) {
                refreshKeys.add(pcPubkey);
            }
        }
        if (previous.self.pcLabel !== replacement.self.pcLabel ||
            previous.self.legacyPcLabel !== replacement.self.legacyPcLabel) {
            for (const pcPubkey of replacement.siblingByPubkey.keys()) {
                refreshKeys.add(pcPubkey);
            }
        }
        if (refreshKeys.size === 0)
            return;
        let body;
        try {
            body = this._localPeersBody();
        }
        catch {
            for (const pcPubkey of refreshKeys) {
                this.topologyRefreshNeeded.add(pcPubkey);
            }
            this._logMetadataOnly("[broker_remote] event=topology_refresh_failed reason=inventory_failure");
            return;
        }
        for (const pcPubkey of refreshKeys) {
            let failed = false;
            try {
                this._sendControlEnvelope(pcPubkey, { type: "peers_request" });
            }
            catch {
                failed = true;
            }
            try {
                this._sendControlEnvelope(pcPubkey, body);
            }
            catch {
                failed = true;
            }
            if (failed) {
                this.topologyRefreshNeeded.add(pcPubkey);
                this._logMetadataOnly("[broker_remote] event=topology_refresh_failed reason=send_failure");
            }
            else {
                this.topologyRefreshNeeded.delete(pcPubkey);
            }
        }
    }
    _bootstrapWithSiblings() {
        const body = this._localPeersBody();
        for (const pcPubkey of this.routing.siblingByPubkey.keys()) {
            this._sendControlEnvelope(pcPubkey, { type: "peers_request" });
            this._sendControlEnvelope(pcPubkey, body);
        }
    }
    _localPeersBody() {
        const detailed = this.broker.localPeerInfos();
        if (!isBoundedPeerRoster(detailed)) {
            throw new Error("mesh: local peer roster exceeds wire limits");
        }
        const peers = detailed.map((peer) => peer.address);
        if (!isBoundedPeerAddresses(peers)) {
            throw new Error("mesh: local peer addresses exceed wire limits");
        }
        return {
            type: "peers_update",
            peers,
            peers_detailed: detailed.map((peer) => ({
                cwd: peer.cwd,
                name: peer.name,
                address: peer.address,
            })),
        };
    }
    _remoteInfosByPubkey(pcPubkey) {
        const entry = this.remotePeers.get(pcPubkey);
        if (!entry)
            return [];
        if (Date.now() - entry.ts > this.cacheTtlMs) {
            this.remotePeers.delete(pcPubkey);
            return [];
        }
        return entry.infos;
    }
    getRemotePeers(pcLabel) {
        const pcPubkey = this.routing.siblingByLabel.get(pcLabel);
        return pcPubkey
            ? this._remoteInfosByPubkey(pcPubkey).map((info) => info.address)
            : [];
    }
    getAllRemote() {
        const entries = [];
        for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
            const peers = this._remoteInfosByPubkey(pcPubkey).map((info) => info.address);
            if (peers.length > 0)
                entries.push([pcLabel, peers]);
        }
        return Object.fromEntries(entries);
    }
    listRemotePeers() {
        const output = [];
        for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
            for (const info of this._remoteInfosByPubkey(pcPubkey)) {
                output.push(`${pcLabel}:${info.address}`);
            }
        }
        return output;
    }
    listRemotePeerInfos() {
        const output = [];
        for (const [pcPubkey, pcLabel] of this.routing.siblingByPubkey) {
            for (const info of this._remoteInfosByPubkey(pcPubkey)) {
                output.push({
                    pc: pcLabel,
                    cwd: info.cwd,
                    name: info.name,
                    address: `${pcLabel}:${info.address}`,
                });
            }
        }
        return output;
    }
    onLocalPeersChanged(_peers) {
        if (this.lifecycle !== "active" ||
            this.routing.siblingByPubkey.size === 0) {
            return;
        }
        let body;
        try {
            body = this._localPeersBody();
        }
        catch {
            this._logMetadataOnly("[broker_remote] event=local_roster_dropped reason=wire_limits");
            return;
        }
        for (const pcPubkey of this.routing.siblingByPubkey.keys()) {
            this._sendControlEnvelope(pcPubkey, body);
        }
    }
    tryRouteOutbound(env) {
        if (this.lifecycle !== "active" || typeof env.to !== "string") {
            return false;
        }
        const parsed = parseAddress(env.to);
        if (!parsed)
            return false;
        const siblingKey = this.routing.siblingByLabel.get(parsed.pcLabel);
        if (siblingKey)
            return this._routeToCanonicalSibling(siblingKey, env);
        return false;
    }
    _routeToCanonicalSibling(siblingKey, env) {
        const destination = parseAddress(env.to);
        const legacyDestinationLabel = this.routing.siblingLegacyLabelByPubkey.get(siblingKey);
        if (!destination || !legacyDestinationLabel)
            return false;
        const rewritten = {
            ...env,
            from: `${this.routing.self.legacyPcLabel}:${env.from}`,
            to: `${legacyDestinationLabel}:${destination.peerName}`,
        };
        this.pi.sendEnvelopeToPi(siblingKey, rewritten);
        if (!this.remotePeers.has(siblingKey)) {
            this._sendControlEnvelope(siblingKey, { type: "peers_request" });
            void this._awaitPeersFill(siblingKey, PEERS_REQUEST_TIMEOUT_MS);
        }
        return true;
    }
    handleIncoming(env, fromPc) {
        if (this.lifecycle !== "active")
            return;
        if (fromPc === "_relay") {
            this._propagateTransportError(env);
            return;
        }
        let canonicalFromPc;
        let fromPcBytes;
        try {
            fromPcBytes = decodeEd25519PublicKey(fromPc, "from_pc");
            canonicalFromPc = encodeEd25519PublicKey(fromPcBytes);
        }
        catch {
            this._dropMetadataOnly("invalid_from_pc");
            return;
        }
        const localAlias = this.routing.siblingByPubkey.get(canonicalFromPc);
        if (!localAlias) {
            this._dropMetadataOnly("unknown_from_pc", publicKeyFingerprint(fromPcBytes));
            return;
        }
        if (typeof env.to !== "string") {
            this._dropMetadataOnly("invalid_to");
            return;
        }
        const senderLegacyLabel = this.routing.siblingLegacyLabelByPubkey.get(canonicalFromPc);
        const senderLocalAddress = stripKnownPcPrefix(env.from, senderLegacyLabel);
        const targetLocalAddress = stripKnownPcPrefix(env.to, this.routing.self.legacyPcLabel);
        if (!senderLocalAddress || !targetLocalAddress) {
            this._dropMetadataOnly("invalid_cross_pc_address");
            return;
        }
        let normalized;
        try {
            // Cross-PC frames bypass the UDS parser. Round-trip their rewritten
            // envelope before inspecting a body or mutating control/cache state.
            normalized = parse(serialize({
                ...env,
                from: `${localAlias}:${senderLocalAddress}`,
                to: targetLocalAddress,
            }));
        }
        catch {
            this._dropMetadataOnly("invalid_envelope");
            return;
        }
        if (typeof normalized.to !== "string") {
            this._dropMetadataOnly("invalid_envelope");
            return;
        }
        const body = normalized.body;
        const bodyType = body && typeof body === "object" ? body.type : undefined;
        const isControlEndpoint = senderLocalAddress === "_broker_remote" &&
            targetLocalAddress === "_broker_remote";
        if (isControlEndpoint && bodyType === "peers_update") {
            const infos = _parsePeersUpdate(body);
            if (!infos) {
                this._dropMetadataOnly("invalid_peers_update");
                return;
            }
            this._setRemoteCache(canonicalFromPc, infos);
            return;
        }
        if (isControlEndpoint && bodyType === "peers_request") {
            try {
                this._sendControlEnvelope(canonicalFromPc, this._localPeersBody());
            }
            catch {
                this._logMetadataOnly("[broker_remote] event=control_reply_failed reason=inventory_failure");
            }
            return;
        }
        const status = this.broker.injectFromRemote(normalized);
        if (bodyType === "ack")
            return;
        const ackBody = {
            type: "ack",
            status,
            target: normalized.to,
        };
        const ackEnv = {
            from: `${this.routing.self.legacyPcLabel}:${BROKER_NAME}`,
            to: env.from,
            id: uuidv7(),
            re: normalized.id,
            body: ackBody,
        };
        this.pi.sendEnvelopeToPi(canonicalFromPc, ackEnv);
    }
    _setRemoteCache(pcPubkey, infos) {
        this.remotePeers.set(pcPubkey, {
            infos,
            pcPubkey,
            ts: Date.now(),
        });
        this._clearPendingFills(pcPubkey);
    }
    _awaitPeersFill(pcPubkey, timeoutMs) {
        return new Promise((resolve) => {
            const slot = {
                resolve,
                timer: setTimeout(() => {
                    const pending = this.pendingFills.get(pcPubkey);
                    pending?.delete(slot);
                    if (pending?.size === 0)
                        this.pendingFills.delete(pcPubkey);
                    resolve();
                }, timeoutMs),
            };
            const pending = this.pendingFills.get(pcPubkey) ?? new Set();
            pending.add(slot);
            this.pendingFills.set(pcPubkey, pending);
        });
    }
    _clearPendingFills(pcPubkey) {
        const pending = this.pendingFills.get(pcPubkey);
        if (!pending)
            return;
        for (const slot of pending) {
            clearTimeout(slot.timer);
            slot.resolve();
        }
        this.pendingFills.delete(pcPubkey);
    }
    _clearAllPendingFills() {
        for (const pcPubkey of [...this.pendingFills.keys()]) {
            this._clearPendingFills(pcPubkey);
        }
    }
    _propagateTransportError(env) {
        const body = asTransportErrorBody(env.body);
        const target = typeof env.to === "string"
            ? stripKnownPcPrefix(env.to, this.routing.self.legacyPcLabel)
            : null;
        // Relay-first compatibility: only the authenticated Relay sentinel may
        // carry its former lowercase 32-hex id shape. Normalize it locally before
        // it reaches Broker's normal strict envelope boundary.
        const normalizedId = LEGACY_RELAY_ID_RE.test(env.id)
            ? `${env.id.slice(0, 8)}-${env.id.slice(8, 12)}-${env.id.slice(12, 16)}-${env.id.slice(16, 20)}-${env.id.slice(20)}`
            : isUuid(env.id)
                ? env.id
                : null;
        if (env.from !== "_relay" ||
            !normalizedId ||
            !isUuid(env.re) ||
            !target ||
            target === "broadcast" ||
            !body) {
            this._dropMetadataOnly("invalid_relay_error");
            return;
        }
        this.broker.injectFromRemote({
            ...env,
            id: normalizedId,
            from: BROKER_NAME,
            to: target,
            body,
        });
    }
    _sendControlEnvelope(toPc, body) {
        const env = envelope(`${this.routing.self.legacyPcLabel}:_broker_remote`, `${this._legacyLabelForPubkey(toPc) ?? "?"}:_broker_remote`, body, null);
        this.pi.sendEnvelopeToPi(toPc, env);
    }
    _legacyLabelForPubkey(pcPubkey) {
        return this.routing.siblingLegacyLabelByPubkey.get(pcPubkey);
    }
    _dropMetadataOnly(reason, fingerprint) {
        this._logMetadataOnly(`[broker_remote] event=drop reason=${reason}` +
            (fingerprint ? ` fingerprint=${fingerprint}` : ""));
    }
    _logMetadataOnly(message) {
        try {
            this.log(message);
        }
        catch {
            // Diagnostics are best-effort and must not break routing or timers.
        }
    }
}
export function parseAddress(to) {
    const separator = to.indexOf(":");
    if (separator <= 0 || separator === to.length - 1)
        return null;
    return {
        pcLabel: to.slice(0, separator),
        peerName: to.slice(separator + 1),
    };
}
function stripKnownPcPrefix(value, legacyPcLabel) {
    if (typeof value !== "string")
        return null;
    const exactPrefix = legacyPcLabel === undefined ? undefined : `${legacyPcLabel}:`;
    if (exactPrefix && value.startsWith(exactPrefix)) {
        const remainder = value.slice(exactPrefix.length);
        return remainder.length > 0 ? remainder : null;
    }
    // Legacy labels are display-only after Relay authentication. Preserve the
    // old first-colon behavior for a divergent receiver view rather than using
    // text as an additional authorization gate.
    return stripRequiredPcPrefix(value);
}
function stripRequiredPcPrefix(value) {
    const separator = value.indexOf(":");
    if (separator <= 0 || separator === value.length - 1)
        return null;
    return value.slice(separator + 1);
}
function _parsePeersUpdate(body) {
    const peers = body.peers;
    if (!Array.isArray(peers) || !isBoundedPeerAddresses(peers))
        return null;
    const detailed = body.peers_detailed;
    if (Array.isArray(detailed)) {
        if (!isBoundedPeerRoster(detailed))
            return null;
        return detailed.map((entry) => ({
            cwd: entry.cwd,
            name: entry.name,
            address: entry.address,
        }));
    }
    return peers.map((address) => ({ cwd: "", name: address, address }));
}
//# sourceMappingURL=broker_remote.js.map