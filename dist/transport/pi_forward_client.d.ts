import { EventEmitter } from "node:events";
import type { RelayClient } from "./relay_client.js";
import type { Envelope } from "../session/envelope.js";
/** Outbound API + inbound listener for Pi↔Pi envelope forwarding via relay. */
export interface PiForwardClientEvents {
    /**
     * Emitted whenever the relay delivers a `pi_envelope_in` frame addressed
     * to this Pi. `fromPc` is the verified Pi-pubkey of the sender (relay
     * authoritative — defense against spoofed `envelope.from`).
     */
    envelope: [env: Envelope, fromPc: string];
}
export declare class PiForwardClient extends EventEmitter {
    private readonly relay;
    private readonly onRelayMessage;
    private detached;
    constructor(relay: RelayClient);
    /**
     * Pack `env` in a `pi_envelope` frame addressed to `toPc` and send via
     * the relay WS. Best-effort: if the relay is not connected, the call is
     * silently dropped. The caller (broker_remote) handles the timeout via
     * its outstanding-ACK map — a missing ACK from the destination wrapper
     * surfaces as `status: "timeout"` upstream regardless.
     */
    sendEnvelopeToPi(toPc: string, env: Envelope): void;
    /** Stop listening to the relay. Call from `_goIdle` / shutdown. */
    detach(): void;
    private _handleLine;
}
