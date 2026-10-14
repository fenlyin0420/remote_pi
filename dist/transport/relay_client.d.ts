import { EventEmitter } from "node:events";
import type { Ed25519Keypair } from "../pairing/crypto.js";
export interface RoomMeta {
    name: string;
    cwd: string;
    /** Friendly model name (e.g. "claude-sonnet-4.5"). Optional — pi-ext sends
     *  when `ExtensionContext.model` is available; relay/app tolerate absence. */
    model?: string;
}
/** Control frame sent to relay (not routed to app peer). */
export interface RoomMetaUpdateFrame {
    type: "room_meta_update";
    room_id: string;
    meta: {
        model?: string;
    };
}
export interface ConnectOptions {
    roomId?: string;
    roomMeta?: RoomMeta;
}
/** Relay rejected hello because another peer already holds (pubkey, room_id). */
export declare class RoomAlreadyOpenError extends Error {
    readonly roomId: string | undefined;
    constructor(roomId: string | undefined);
}
export interface RelayClientEvents {
    /** A single JSONL line delivered by the relay (outer envelope). */
    message: [line: string];
    close: [];
    error: [err: Error];
}
/**
 * Thin WebSocket client for the Remote Pi relay.
 *
 * Lifecycle:
 *   const relay = new RelayClient(url, ed25519Keypair)
 *   await relay.connect()          // opens WS + runs Ed25519 challenge-response
 *   relay.on("message", line => …) // outer envelopes: { peer, ct }
 *   relay.send(jsonLine)           // write to relay
 *   relay.close()
 *
 * Auth sequence (pairing.md §Challenge-response):
 *   → { type:"hello",     pubkey: "<Ed25519 pubkey base64>" }
 *   ← { type:"challenge", nonce:  "<32 bytes base64>" }
 *   → { type:"auth",      sig:    "<Ed25519 sig base64>" }
 */
export declare class RelayClient extends EventEmitter {
    private readonly url;
    private readonly keypair;
    private ws;
    /** Epoch ms of the last inbound frame (message / relay ping / pong). */
    private lastActivityAt;
    private livenessTimer;
    constructor(url: string, keypair: Ed25519Keypair);
    /**
     * Connects and completes Ed25519 auth.  Resolves when relay is ready.
     *
     * `options.roomId` (12-char id derived from cwd, see `src/rooms.ts`) is
     * included in the hello so the relay can multiplex N concurrent peers
     * with the same Ed25519 pubkey but different rooms (one pi-ext per cwd).
     * Omitting `roomId` is backward-compat with old relays (treated as the
     * default "main" room server-side).
     *
     * Throws `RoomAlreadyOpenError` if the relay rejects the hello because
     * another peer already holds the (pubkey, room_id) tuple. Caller (e.g.
     * `_cmdStart`) maps that to a clearer UI message.
     */
    connect(options?: ConnectOptions): Promise<void>;
    /** True only while the authenticated Relay WebSocket is currently open. */
    isOpen(): boolean;
    /** Sends a raw line to the relay (caller is responsible for framing). */
    send(line: string): void;
    /**
     * Sends a control frame to the relay (not routed to app peer). Used for
     * out-of-band metadata updates like `room_meta_update`. Silently no-ops if
     * the WS isn't open (best-effort: control frames are observational; we
     * don't want them throwing inside SDK event callbacks).
     */
    sendControl(frame: object): void;
    close(): void;
    /** Force-close the WS when no inbound frame has arrived for
     *  `LIVENESS_TIMEOUT_MS` — see the constant's doc for why. `terminate()`
     *  fires `close`, which the owner turns into a reconnect. */
    private _startLiveness;
    private _stopLiveness;
    private _authenticate;
    /** Waits for the next single WS message with a timeout. */
    private _nextMsg;
    private _rawSend;
}
