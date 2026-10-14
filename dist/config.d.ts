/**
 * Default community relay. Stored in canonical http(s):// form — conversion
 * to ws(s):// happens at the transport layer (see `toWebSocketUrl`). The
 * community relay's reverse proxy maps `:443 → :3000` (the WS port), so the
 * URL has no explicit port and the WebSocket upgrade rides on the same TLS
 * connection as the HTTPS endpoints used by the mesh client.
 */
export declare const kDefaultRelayUrl = "https://relay-rp1.jacobmoura.work";
export type RemotePiConfig = {
    relay?: string;
};
export declare function loadConfig(): RemotePiConfig;
export declare function saveConfig(patch: Partial<RemotePiConfig>): void;
export type RelayResolution = {
    url: string;
    source: "env" | "config" | "default";
};
/**
 * Resolves the effective relay URL in **canonical http(s):// form**.
 *
 * Precedence:
 *   1. `REMOTE_PI_RELAY` env var (ops/CI escape hatch)
 *   2. `~/.pi/remote/config.json` `relay` field (set via /remote-pi set-relay)
 *   3. `kDefaultRelayUrl` (community default)
 *
 * Any ws(s):// values found (legacy configs or env overrides) are coerced
 * to http(s):// defensively — the canonical form across the codebase is
 * http(s)://, and the transport layer converts to ws(s):// at WS-open time.
 */
export declare function resolveRelayUrl(): RelayResolution;
/**
 * Strict validator for **user-provided** relay URLs (via `/remote-pi
 * set-relay` or `/remote-pi relay url`).
 *
 * Only accepts `http://` and `https://`. `ws://`/`wss://` are deliberately
 * **rejected** — the canonical form stored in config is http(s):// and the
 * extension converts to ws(s):// internally when opening the WebSocket.
 * Forcing a single scheme at the user boundary avoids two-form drift.
 */
export declare function isValidRelayUrl(url: string): boolean;
/**
 * Returns true if the URL uses ws:// or wss:// scheme — for emitting a
 * targeted error message when the user pastes a WebSocket URL by mistake.
 */
export declare function isWebSocketScheme(url: string): boolean;
/**
 * Converts an http(s):// URL to the corresponding ws(s):// form. Used by
 * the transport layer right before opening the WebSocket — config storage
 * and the mesh HTTP client both stay on http(s)://.
 *
 *   https://host  → wss://host
 *   http://host   → ws://host
 *   ws(s)://host  → pass-through (defensive — env overrides or legacy
 *                   configs may still carry ws(s)://)
 */
export declare function toWebSocketUrl(url: string): string;
/**
 * Inverse of `toWebSocketUrl`. Used by `resolveRelayUrl` to coerce any
 * ws(s):// values back to canonical http(s):// before returning them to
 * the rest of the codebase.
 */
export declare function toHttpUrl(url: string): string;
