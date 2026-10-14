import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage } from "./protocol/types.js";
export interface UiNotifyCapture {
    /** Number of notifications forwarded since the last reset (diagnostics/tests). */
    readonly forwardedCount: number;
    /** True once a usable shared context was found and wrapped. */
    readonly armed: boolean;
    /** Restore the original `notify` and stop forwarding. */
    dispose(): void;
}
/**
 * Wrap the session's shared `notify` so notifications raised by ANY extension
 * reach the paired app, then still reach the desktop UI.
 *
 * Idempotent per context: Pi shares one context across all extensions, so a
 * second call would wrap our own wrapper and double-send.
 *
 * Returns `null` only when the API exposes no `on` (nothing to hook).
 */
export declare function createUiNotifyCapture(pi: ExtensionAPI, broadcast: (msg: ServerMessage) => void, onForwarded?: (message: string) => void): UiNotifyCapture | null;
