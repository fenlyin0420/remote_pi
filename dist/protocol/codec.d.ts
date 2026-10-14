import type { ClientMessage, ServerMessage } from "./types.js";
export declare class DecodeError extends Error {
    readonly code: "invalid_message" | "unsupported_type";
    constructor(code: "invalid_message" | "unsupported_type", message: string);
}
export declare function encodeClient(msg: ClientMessage): string;
export declare function decodeServer(line: string): ServerMessage;
