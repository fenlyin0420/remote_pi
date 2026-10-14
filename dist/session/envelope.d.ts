/**
 * 5-field envelope for the agent-network local protocol (plano 19).
 * Serialized as JSONL (one JSON object per line) over UDS streams.
 */
export interface Envelope {
    from: string;
    to: string | string[];
    id: string;
    re: string | null;
    body: unknown;
}
export declare const TRANSPORT_ERROR_REASONS: readonly ["offline", "not_authorized", "bad_envelope"];
export type TransportErrorReason = typeof TRANSPORT_ERROR_REASONS[number];
export interface TransportErrorBody {
    type: "transport_error";
    reason: TransportErrorReason;
}
export declare function isUuid(value: unknown): value is string;
export declare function hasTransportErrorType(value: unknown): boolean;
export declare function asTransportErrorBody(value: unknown): TransportErrorBody | null;
/**
 * Generates a UUID v7 — time-ordered, monotonically increasing within the
 * same millisecond. Format:
 *   <48-bit ts ms><4-bit ver=7><12-bit rand><2-bit var=10><62-bit rand>
 */
export declare function uuidv7(): string;
export declare class EnvelopeError extends Error {
    constructor(message: string);
}
export declare function serialize(env: Envelope): string;
export declare function parse(line: string): Envelope;
/** Convenience: builds an envelope with id auto-generated. */
export declare function envelope(from: string, to: string | string[], body: unknown, re?: string | null): Envelope;
