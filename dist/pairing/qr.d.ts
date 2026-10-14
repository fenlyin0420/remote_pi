/** Default ephemeral-token lifetime (also the QR rotation period). */
export declare const TOKEN_TTL_MS = 60000;
/** Bounds for a caller-supplied pairing TTL (e.g. `/remote-pi pair --ttl <s>`). */
export declare const PAIR_TTL_MIN_MS = 10000;
export declare const PAIR_TTL_MAX_MS = 600000;
/** Clamp an arbitrary ttl (ms) into the safe pairing range; NaN → default. */
export declare function clampPairTtlMs(ttlMs: number): number;
/** Encapsulates the single active QR token. One instance per Pi process. */
export declare class QRSession {
    private active;
    /** Generates a fresh 16-byte random token encoded as base64url. */
    generateToken(): string;
    /**
     * Issues a new active token, invalidating any previous one.
     * Returns the token and its expiry timestamp.
     */
    issueToken(ttlMs?: number): {
        token: string;
        expiresAt: number;
    };
    /** Validates and atomically consumes a token. */
    consumeToken(token: string): "ok" | "expired" | "consumed" | "unknown";
    clear(): void;
}
export declare const qrSession: QRSession;
export declare function buildQRUri(token: string, longtermEdPk: Uint8Array, // Ed25519 — only peer ID after E2E rollback
sessionName: string, 
/**
 * Pi room id (12 chars, base64url) derived from cwd. App routes pair_request
 * to this room so the relay delivers it to the right Pi instance among N
 * paralelos com mesmo epk. Adicionado no fix do plano 17 (sem `rm` o app
 * cai em room=main e o relay drops com "dest not found").
 */
roomId?: string): string;
/**
 * Returns the QR ASCII as a string (pure Unicode block characters —
 * `█ ▀ ▄` and space, NO ANSI escapes — qrcode-terminal v0.12 small mode
 * is escape-free, see lib/main.js:48-53).
 *
 * The caller can either write the string to stderr (legacy path, breaks
 * the Pi TUI layout) or inject it via `pi.sendMessage` (renders inside
 * the chat panel as proper content).
 */
export declare function renderQRAscii(uri: string): string;
/**
 * Legacy stderr writer — kept for the standalone CLI mode
 * (`pi-remote/src/index.ts` bottom block, which runs outside a Pi TUI).
 * Inside the Pi TUI extension flow, use `renderQRAscii` + `pi.sendMessage`
 * instead — direct stderr writes from inside an extension break the TUI's
 * scrollable output widget (the QR overflows the panel and other writes
 * collide with the prompt area).
 */
export declare function displayQR(uri: string): void;
/**
 * Starts a rotating QR session: generates a new QR every 60s, printing it
 * to stdout. Returns a `stop()` function that cancels the rotation and clears
 * the active token.
 */
export declare function startQRRotation(longtermEdPk: Uint8Array, sessionName: string, roomId?: string): () => void;
