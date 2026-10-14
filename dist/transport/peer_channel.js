/**
 * Plaintext PeerChannel backed by a RelayClient WebSocket.
 *
 * Usage (after pair_request handshake completes):
 *   const channel = new PlainPeerChannel(relay, appPeerId, myRoomId, onMsg)
 *   channel.send(serverMessage)          // base64-encodes JSON, routes via relay
 *   // incoming relay messages destined for appPeerId are auto-decoded
 *   // and delivered via onMessage callback
 *
 * `myRoomId` is the *local* Pi's room id — sent on every outbound envelope
 * so the app can correlate which Pi sent it (multi-pi support, plano 17).
 */
export class PlainPeerChannel {
    relay;
    remotePeerId;
    onMessage;
    _unsubscribe;
    constructor(relay, remotePeerId, 
    /**
     * This Pi's room id. Currently NOT injected in the outer envelope
     * (defensive — relay/app not yet ready). Kept in the constructor for
     * forward-compat so callers don't need to change again when we re-enable.
     */
    myRoomId, onMessage, 
    /** Called when this specific peer connection is considered lost. */
    _onDisconnect) {
        this.relay = relay;
        this.remotePeerId = remotePeerId;
        this.onMessage = onMessage;
        const listener = (line) => this._onLine(line);
        relay.on("message", listener);
        this._unsubscribe = () => relay.off("message", listener);
        void _onDisconnect;
        void myRoomId; // intentionally unused — see send() comment
    }
    // ── PeerChannel interface ──────────────────────────────────────────────────
    send(msg) {
        const ct = Buffer.from(JSON.stringify(msg)).toString("base64");
        // NOTE: `room` removed from the outer envelope until relay (W1.A) + app
        // (W1.C) accept the field. Multi-Pi multiplexing already works via
        // `room_id`/`room_meta` in the WS-level `hello` — outer routing stays by
        // `peer` alone. Re-add the field once downstream is ready.
        const outer = { peer: this.remotePeerId, ct };
        // Best-effort delivery. The relay WS can be mid-reconnect (idle/NAT drop, or
        // a session_new/session-replacement teardown) when we push a server→app frame
        // — notably the action_ok/action_error ack a handler emits right after
        // newSession. `relay.send` throws "relay: not connected" in that window; since
        // this runs inside an async SDK event callback, letting it propagate becomes an
        // uncaughtException that kills the whole pi process. The relay auto-reconnects
        // and the app re-syncs via session_sync, so a dropped frame is recoverable — a
        // crash is not. Mirrors RelayClient.sendControl's no-op-when-closed policy.
        try {
            this.relay.send(JSON.stringify(outer));
        }
        catch {
            /* relay down — drop this frame; reconnect + session_sync will recover */
        }
    }
    /** Detaches from relay (does not close the relay itself). */
    detach() {
        this._unsubscribe();
    }
    // ── Incoming line from relay ────────────────────────────────────────────────
    _onLine(line) {
        let outer;
        try {
            outer = JSON.parse(line);
        }
        catch {
            return; // malformed line
        }
        if (outer.peer !== this.remotePeerId)
            return;
        if (!outer.ct)
            return;
        let plaintext;
        try {
            plaintext = Buffer.from(outer.ct, "base64").toString("utf8");
        }
        catch {
            return;
        }
        let msg;
        try {
            msg = JSON.parse(plaintext);
        }
        catch {
            return;
        }
        if (!msg ||
            typeof msg !== "object" ||
            typeof msg.type !== "string") {
            return;
        }
        this.onMessage(msg);
    }
}
//# sourceMappingURL=peer_channel.js.map