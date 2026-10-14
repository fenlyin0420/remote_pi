/**
 * CLI ↔ supervisor IPC contract for `~/.pi/remote/supervisor.sock`.
 *
 * Framing: one JSON object per line, newline-terminated. The CLI sends a
 * single `ControlRequest`, the supervisor sends a single `ControlReply`,
 * both close the connection. No multiplexing, no streaming — each command
 * is a short round-trip.
 *
 * Plan/26 W2. The Pi RPC protocol (`pi --mode rpc`) used by the daemon
 * children themselves is a separate contract — see
 * `node_modules/@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-types.d.ts`.
 * This file is strictly the supervisor's own control plane.
 */
// ── Serialization helpers ────────────────────────────────────────────────────
const TRAILING_NEWLINE = "\n";
export function encodeRequest(req) {
    return JSON.stringify(req) + TRAILING_NEWLINE;
}
export function encodeReply(reply) {
    return JSON.stringify(reply) + TRAILING_NEWLINE;
}
/**
 * Parses a single JSON line into a request. Throws on malformed input —
 * the supervisor catches and replies `{ok:false, error}` so the client
 * gets a clean error rather than an unframed disconnect.
 */
export function parseRequest(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch (e) {
        throw new Error(`malformed control request: ${e.message}`);
    }
    if (!obj || typeof obj !== "object") {
        throw new Error("control request must be a JSON object");
    }
    const op = obj.op;
    if (typeof op !== "string") {
        throw new Error("control request missing string `op` field");
    }
    // We don't validate every field shape here — supervisor handlers do it
    // per-op since the error messages are more specific that way.
    return obj;
}
export function parseReply(line) {
    let obj;
    try {
        obj = JSON.parse(line);
    }
    catch (e) {
        throw new Error(`malformed control reply: ${e.message}`);
    }
    if (!obj || typeof obj !== "object") {
        throw new Error("control reply must be a JSON object");
    }
    const ok = obj.ok;
    if (typeof ok !== "boolean") {
        throw new Error("control reply missing boolean `ok` field");
    }
    return obj;
}
//# sourceMappingURL=control_protocol.js.map