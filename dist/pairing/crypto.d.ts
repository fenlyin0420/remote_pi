export interface Ed25519Keypair {
    publicKey: Uint8Array;
    secretKey: Uint8Array;
}
/** Generates an Ed25519 keypair for relay challenge-response auth. */
export declare function generateEd25519Keypair(): Ed25519Keypair;
export declare function ed25519Sign(sk: Uint8Array, msg: Uint8Array): Uint8Array;
export declare function ed25519Verify(pk: Uint8Array, msg: Uint8Array, sig: Uint8Array): boolean;
