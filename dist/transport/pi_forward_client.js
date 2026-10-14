import { EventEmitter } from "node:events";
export class PiForwardClient extends EventEmitter {
    relay;
    onRelayMessage;
    detached = false;
    constructor(relay) {
        super();
        this.relay = relay;
        this.onRelayMessage = (line) => this._handleLine(line);
        this.relay.on("message", this.onRelayMessage);
    }
    /**
     * Pack `env` in a `pi_envelope` frame addressed to `toPc` and send via
     * the relay WS. Best-effort: if the relay is not connected, the call is
     * silently dropped. The caller (broker_remote) handles the timeout via
     * its outstanding-ACK map — a missing ACK from the destination wrapper
     * surfaces as `status: "timeout"` upstream regardless.
     */
    sendEnvelopeToPi(toPc, env) {
        if (this.detached)
            return;
        const frame = { type: "pi_envelope", to_pc: toPc, envelope: env };
        try {
            this.relay.send(JSON.stringify(frame));
        }
        catch {
            // relay not connected; broker_remote's pending logic will time out
        }
    }
    /** Stop listening to the relay. Call from `_goIdle` / shutdown. */
    detach() {
        if (this.detached)
            return;
        this.detached = true;
        this.relay.off("message", this.onRelayMessage);
    }
    _handleLine(line) {
        // The relay multiplexes several frame types over the same WS; we only
        // care about `pi_envelope_in`. Other frames (outer-encrypted owner
        // envelopes, control replies) are silently ignored.
        let parsed;
        try {
            parsed = JSON.parse(line);
        }
        catch {
            return;
        }
        if (!parsed || typeof parsed !== "object")
            return;
        const o = parsed;
        if (o.type !== "pi_envelope_in")
            return;
        if (typeof o.from_pc !== "string" || !o.envelope || typeof o.envelope !== "object")
            return;
        // Cheap shape check — full envelope parse happens downstream in broker_remote.
        const env = o.envelope;
        if (typeof env.from !== "string" || typeof env.id !== "string")
            return;
        this.emit("envelope", env, o.from_pc);
    }
}
//# sourceMappingURL=pi_forward_client.js.map