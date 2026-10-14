const SERVER_TYPES = new Set([
    "pair_ok",
    "pair_error",
    "user_input",
    "queued_message_state",
    "agent_chunk",
    "agent_thinking",
    "agent_done",
    "agent_message",
    "tool_request",
    "tool_result",
    "error",
    "cancelled",
    "pong",
    "bye",
    "session_history",
    // Plan/57 — interactive extension prompt (ask_user via pi-ask).
    "extension_ui_request",
]);
export class DecodeError extends Error {
    code;
    constructor(code, message) {
        super(message);
        this.code = code;
        this.name = "DecodeError";
    }
}
export function encodeClient(msg) {
    return JSON.stringify(msg) + "\n";
}
export function decodeServer(line) {
    let obj;
    try {
        obj = JSON.parse(line.trim());
    }
    catch (e) {
        throw new DecodeError("invalid_message", `not JSON: ${e.message}`);
    }
    if (!obj ||
        typeof obj !== "object" ||
        typeof obj.type !== "string") {
        throw new DecodeError("invalid_message", "missing 'type'");
    }
    const t = obj.type;
    if (!SERVER_TYPES.has(t)) {
        throw new DecodeError("unsupported_type", `unknown type: ${t}`);
    }
    return obj;
}
//# sourceMappingURL=codec.js.map