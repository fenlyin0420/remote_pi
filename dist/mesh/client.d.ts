import type { MeshEnvelope } from "./types.js";
export declare class MeshFetchUnavailableError extends Error {
    readonly name = "MeshFetchUnavailableError";
}
export declare class MeshFetchInvalidResponseError extends Error {
    readonly name = "MeshFetchInvalidResponseError";
}
export interface MeshClientOptions {
    /** Finite deadline covering response headers and body parsing. */
    readonly requestTimeoutMs?: number;
}
/** Finite-deadline HTTP client for Relay mesh membership envelopes. */
export declare class MeshClient {
    private readonly baseUrl;
    private readonly requestTimeoutMs;
    constructor(relayUrl: string, options?: MeshClientOptions);
    get(hash: string, since?: number): Promise<MeshEnvelope | null>;
}
