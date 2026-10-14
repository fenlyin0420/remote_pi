import type { MeshEnvelope, MeshHeader } from "./types.js";
/**
 * Verifies the Ed25519 signature on a mesh envelope and decodes the blob
 * into a typed `MeshHeader`.
 *
 * The verification key is extracted *from the blob* (`owner_pk` field) —
 * the caller MUST then check that `sha256(header.ownerPk)` matches the
 * URL hash they queried with. Otherwise a malicious relay could serve a
 * valid-but-different-owner blob at our hash slot.
 *
 * Throws on:
 *   - JSON parse failure
 *   - Missing or wrong-type required fields
 *   - `owner_pk` not 32 bytes
 *   - Signature mismatch
 */
export declare function verifyEnvelope(env: MeshEnvelope): Promise<MeshHeader>;
