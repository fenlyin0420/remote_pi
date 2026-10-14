import { createHash, randomBytes } from "node:crypto";
import * as ed from "@noble/ed25519";
// Configure @noble/ed25519 v3 to use Node.js built-in SHA-512
ed.hashes["sha512"] = (...msgs) => {
    const h = createHash("sha512");
    for (const m of msgs)
        h.update(m);
    return Uint8Array.from(h.digest());
};
/** Generates an Ed25519 keypair for relay challenge-response auth. */
export function generateEd25519Keypair() {
    const secretKey = randomBytes(32);
    const publicKey = ed.getPublicKey(secretKey);
    return { secretKey, publicKey: Buffer.from(publicKey) };
}
export function ed25519Sign(sk, msg) {
    return Buffer.from(ed.sign(msg, sk));
}
export function ed25519Verify(pk, msg, sig) {
    return ed.verify(sig, msg, pk);
}
//# sourceMappingURL=crypto.js.map