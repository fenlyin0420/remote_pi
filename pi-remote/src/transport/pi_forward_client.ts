import { EventEmitter } from "node:events";
import type { RelayClient } from "./relay_client.js";
import type { Envelope } from "../session/envelope.js";

/**
 * Plan/25 Wave A wire types — must stay bit-compatible with the relay's
 * `handlers/pi_forward.rs`.
 *
 * Outbound (Pi → relay):
 *   { type: "pi_envelope", to_pc: <pi-b-pubkey-base64>, envelope: {...} }
 *
 * Inbound (relay → Pi):
 *   { type: "pi_envelope_in", from_pc: <pi-a-pubkey-base64>, envelope: {...} }
 *
 * Transport errors arrive as a regular envelope nested inside the inbound
 * frame, with `envelope.from = "_relay"` and
 * `envelope.body = { type: "transport_error", reason }`. They are NOT a
 * separate frame type — `pi_forward_client` simply emits them through the
 * same `envelope` event and lets `broker_remote` recognize them.
 */

interface PiEnvelopeFrame {
  type: "pi_envelope";
  to_pc: string;
  envelope: Envelope;
}

interface PiEnvelopeInFrame {
  type: "pi_envelope_in";
  from_pc: string;
  envelope: Envelope;
}

/** Outbound API + inbound listener for Pi↔Pi envelope forwarding via relay. */
export interface PiForwardClientEvents {
  /**
   * Emitted whenever the relay delivers a `pi_envelope_in` frame addressed
   * to this Pi. `fromPc` is the verified Pi-pubkey of the sender (relay
   * authoritative — defense against spoofed `envelope.from`).
   */
  envelope: [env: Envelope, fromPc: string];
}

export class PiForwardClient extends EventEmitter {
  private readonly onRelayMessage: (line: string) => void;
  private detached = false;

  constructor(private readonly relay: RelayClient) {
    super();
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
  sendEnvelopeToPi(toPc: string, env: Envelope): void {
    if (this.detached) return;
    const frame: PiEnvelopeFrame = { type: "pi_envelope", to_pc: toPc, envelope: env };
    try {
      this.relay.send(JSON.stringify(frame));
    } catch {
      // relay not connected; broker_remote's pending logic will time out
    }
  }

  /** Stop listening to the relay. Call from `_goIdle` / shutdown. */
  detach(): void {
    if (this.detached) return;
    this.detached = true;
    this.relay.off("message", this.onRelayMessage);
  }

  private _handleLine(line: string): void {
    // The relay multiplexes several frame types over the same WS; we only
    // care about `pi_envelope_in`. Other frames (outer-encrypted owner
    // envelopes, control replies) are silently ignored.
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      return;
    }
    if (!parsed || typeof parsed !== "object") return;
    const o = parsed as Partial<PiEnvelopeInFrame>;
    if (o.type !== "pi_envelope_in") return;
    if (typeof o.from_pc !== "string" || !o.envelope || typeof o.envelope !== "object") return;

    // Cheap shape check — full envelope parse happens downstream in broker_remote.
    const env = o.envelope as Envelope;
    if (typeof env.from !== "string" || typeof env.id !== "string") return;
    this.emit("envelope", env, o.from_pc);
  }
}
