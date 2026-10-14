import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { AskResponseEnrichmentWire, ExtensionUiResponseWire, ServerMessage } from "./protocol/types.js";
export interface ExtensionUiBridge {
    /** Route an inbound `extension_ui_response` from a peer back to pi-ask. */
    respond(msg: ExtensionUiResponseWire): void;
    /**
     * Requests for flows still awaiting an answer, for `session_sync` to replay.
     *
     * The `started` broadcast fires exactly once. A peer that connects *after*
     * a flow opened never saw it: history replayed, but the interactive frame
     * did not, so the phone showed the ask_user tool call as plain text while
     * the desktop sat blocked on the TUI dialog. Replaying on sync closes that
     * hole — the common real-world case is the agent asking while the app is
     * closed.
     */
    pendingRequests(): ServerMessage[];
    /** Drop all subscriptions + state (best-effort teardown). */
    dispose(): void;
}
/**
 * Wire pi-ask's event contract to the relay's extension_ui_request/response
 * frames. Returns `null` only if the SDK exposes no usable `events` bus (defensive
 * — modern Pi always has one); callers stay null-safe.
 */
export declare function createExtensionUiBridge(pi: ExtensionAPI, broadcast: (msg: ServerMessage) => void): ExtensionUiBridge | null;
export type { AskResponseEnrichmentWire, ExtensionUiResponseWire };
