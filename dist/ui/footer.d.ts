/**
 * Footer renderer for the Pi TUI. Three status slots + window title.
 *
 * Slot keys (intentionally namespaced so other extensions don't collide):
 *   - remote-pi:session   — current local session + peer count
 *   - remote-pi:relay     — relay state (off / on / paired)
 *   - remote-pi:peer-active — active mobile device, if paired
 */
export interface FooterContext {
    ui: {
        setStatus(key: string, value: string | undefined): void;
        setTitle(title: string): void;
    };
}
export interface FooterState {
    session?: string;
    peerCount?: number;
    relayOn?: boolean;
    /** Active device session right now (drives the 📱 slot).
     *  Independent from `hasPairings` — a device may be paired globally
     *  in peers.json without being actively connected to THIS Pi process. */
    devicePaired?: string;
    /** At least one device has been paired with this machine before
     *  (peers.json is non-empty). Drives the 🟢/🟡 icon on the relay slot:
     *  🟢 when true (ready — devices can connect), 🟡 when false (first
     *  pairing needed). Pairing is per-machine (global), not per-process. */
    hasPairings?: boolean;
    /** Assigned agent name in the current session. Becomes the title prefix
     *  (e.g. "backend · foo · relay") when set. Falls back to "Pi" otherwise. */
    agentName?: string;
}
export declare function updateFooter(ctx: FooterContext, state: FooterState): void;
