export declare class MeshPublicKeyError extends Error {
    readonly field: string;
    constructor(field: string, message: string);
}
/**
 * Strictly decodes a 32-byte Ed25519 public key accepted at a protocol boundary.
 * The rejected value is deliberately absent from every error message.
 */
export declare function decodeEd25519PublicKey(raw: string, field?: string): Uint8Array;
/** Returns an Ed25519 public key in RFC 4648 standard padded base64. */
export declare function encodeEd25519PublicKey(bytes: Uint8Array, field?: string): string;
/** Decodes then returns an Ed25519 public key in canonical standard base64. */
export declare function canonicalizeEd25519PublicKey(raw: string, field?: string): string;
/** RFC 4648 URL-safe base64 without padding. */
export declare function toBase64UrlNoPad(bytes: Uint8Array): string;
/** Stable metadata-only fingerprint for a validated public key. */
export declare function publicKeyFingerprint(bytes: Uint8Array): string;
export interface RoutingAliasInput {
    readonly pcPubkey: string;
    readonly nickname?: string;
}
/** Percent-encodes a nickname into the receiver-local routing grammar. */
export declare function encodeRoutingAlias(rawNickname: string): string;
/** Selects a raw nickname by encoded ASCII order, then raw UTF-8 bytes. */
export declare function selectRoutingNickname(candidates: readonly string[]): string | undefined;
/**
 * Allocates a deterministic bijection from canonical Pi key to effective alias.
 * Every colliding base is suffixed with an adaptively expanded key prefix.
 */
export declare function allocateRoutingAliases(inputs: readonly RoutingAliasInput[]): ReadonlyMap<string, string>;
/**
 * Constant-time-ish byte equality for validated public keys. Returns false
 * immediately on length mismatch.
 *
 * Not strictly constant-time — Ed25519 pubkeys aren't secrets, so the
 * short-circuit on length and the byte-by-byte compare are acceptable.
 */
export declare function bytesEqual(a: Uint8Array, b: Uint8Array): boolean;
