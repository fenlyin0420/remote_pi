import type { ClientMessage, ServerMessage } from "../protocol/types.js";
import type { RelayClient } from "./relay_client.js";
/** Sink for ServerMessage outbound to the remote app. */
export interface PeerChannel {
    send(msg: ServerMessage): void;
}
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
export declare class PlainPeerChannel implements PeerChannel {
    private readonly relay;
    private readonly remotePeerId;
    private readonly onMessage;
    private readonly _unsubscribe;
    constructor(relay: RelayClient, remotePeerId: string, 
    /**
     * This Pi's room id. Currently NOT injected in the outer envelope
     * (defensive — relay/app not yet ready). Kept in the constructor for
     * forward-compat so callers don't need to change again when we re-enable.
     */
    myRoomId: string | undefined, onMessage: (msg: ClientMessage) => void, 
    /** Called when this specific peer connection is considered lost. */
    _onDisconnect?: () => void);
    send(msg: ServerMessage): void;
    /** Detaches from relay (does not close the relay itself). */
    detach(): void;
    private _onLine;
}
