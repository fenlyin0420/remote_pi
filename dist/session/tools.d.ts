import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { SessionPeer } from "./peer.js";
/**
 * Registers the native tools the Pi LLM uses to talk to other agents in the
 * same UDS session (plano 19 transport + plan/25 Wave 0 ACK protocol):
 *
 *   - `agent_send`     — unified delivery with broker-level ACK. Returns
 *                        a status so the LLM can decide whether to retry.
 *                        For unicast targets the broker auto-replies with
 *                        `received | busy | denied`. For broadcast/multicast
 *                        the tool is fire-and-forget (status `sent`).
 *   - `agent_request`  — **deprecated**. Still works (send + block on reply
 *                        via `re` correlation) but the LLM should migrate
 *                        to the event-driven send+inbox pattern. Each call
 *                        emits a one-shot warning to stderr.
 *
 * Reply pattern (new world): when you receive a message you want to answer,
 * send back another envelope with `re=<original-id>`. The original sender
 * sees that reply in its inbox during a future turn.
 *
 * `getSessionPeer` is a getter (not a captured value) so changes to the
 * underlying `_sessionPeer` module variable are observed live.
 */
export declare function registerAgentTools(pi: ExtensionAPI, getSessionPeer: () => SessionPeer | null): void;
