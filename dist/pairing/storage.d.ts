import { type Ed25519Keypair } from "./crypto.js";
/** Raised when the keyring is unreadable on a platform where it's a core OS
 *  service (macOS Keychain, Windows Credential Manager) AND no prior file
 *  identity exists. We refuse to generate a NEW identity here because that
 *  would break existing pairing — the caller surfaces this so the user can
 *  unlock the keychain and retry instead of silently re-pairing. */
export declare class KeyringUnavailableError extends Error {
    constructor(cause: unknown);
}
/** Raised when no identity can be resolved (keyring unreadable, no identity
 *  file) BUT `peers.json` already lists paired devices. Minting a fresh key
 *  here would make SelfRevoke wipe those pairings — see issues #95 / #69. */
export declare class PairedIdentityMissingError extends Error {
    constructor(pairedCount: number, cause: unknown);
}
/**
 * Minimal backend interface for credential reads/writes. Swappable so
 * tests can inject a controlled in-memory store without touching the OS
 * keyring (which is shared with the developer's own credentials).
 *
 * Errors thrown by `read`/`write`/`delete` signal "backend unavailable on
 * this platform" — callers fall back to the file store on first failure.
 * Returning `undefined` from `read` means "no such entry" (a normal,
 * non-error condition).
 */
export interface KeyStoreBackend {
    read(service: string, account: string): Promise<string | undefined>;
    write(service: string, account: string, value: string): Promise<void>;
    delete(service: string, account: string): Promise<boolean>;
}
/** Test-only: force (or clear with `null`) a memoized binding-load failure, so
 *  the Bun/no-native-binding branch is reachable without a Bun host. */
export declare function _setNativeBindingErrorForTest(err: unknown): void;
/** Test-only: swap (or clear with `null`) the keyring backend. */
export declare function _setKeyStoreBackendForTest(backend: KeyStoreBackend | null): void;
/** Test-only: force `_keyringExpectedAvailable()` (so a darwin test host can
 *  exercise the Linux/headless branch and vice-versa). `null` restores the
 *  real platform check. */
export declare function _setKeyringExpectedForTest(value: boolean | null): void;
/** Test-only: shrink retry attempts/delay so the persistent-failure path is
 *  fast. `null`/omitted restores defaults. */
export declare function _setKeyringRetryForTest(attempts: number | null, delayMs?: number): void;
/**
 * Returns the Pi-secret Ed25519 keypair, generating + persisting one on
 * first call. Resolution order:
 *   1. Existing file `~/.pi/remote/identity.json`, if present — it WINS over
 *      the keyring. A file identity is only ever written by the headless/
 *      degraded fallback (step 4) or an explicit `REMOTE_PI_ALLOW_FILE_IDENTITY`
 *      opt-in, so its mere presence means this machine established its identity
 *      as a file and the mobile device paired against THAT pubkey. If the
 *      platform keyring later becomes readable (D-Bus/libsecret installed, a
 *      desktop session, or a stale/other entry from another install), reading
 *      it first would mask the file identity — returning a DIFFERENT key, or
 *      (when the keyring is empty) minting a fresh one and persisting it —
 *      silently breaking the existing pairing. So when both exist, file wins.
 *   2. New keyring service `dev.remotepi.pi` (read retried — a transiently
 *      locked Keychain throws; we don't treat that as "no key")
 *   3. Old keyring service `dev.remotepi.mac` (migrate → step 2, delete old)
 *   4. Generate a fresh keypair, BUT only when it's safe to: either both
 *      keyring reads succeeded and returned nothing (genuine first run), or
 *      the keyring is genuinely unavailable on a platform without a core one
 *      (headless Linux → a file identity is minted here). On macOS/Windows a
 *      persistent read failure with no file identity throws
 *      `KeyringUnavailableError` instead of minting a new key — generating
 *      there silently breaks existing pairing (the "lost pairing after idle"
 *      bug). `REMOTE_PI_ALLOW_FILE_IDENTITY=1` opts back into a file identity
 *      for headless macOS/Windows hosts.
 *
 * Idempotent: subsequent calls return the same identity. The migration
 * runs at most once per machine (the old entry is deleted after copy).
 */
export declare function getOrCreateEd25519Keypair(): Promise<Ed25519Keypair>;
export interface PeerRecord {
    name: string;
    remote_epk: string;
    paired_at: string;
}
export declare function listPeers(): Promise<PeerRecord[]>;
declare const _ownerStorageTokenBrand: unique symbol;
/** Opaque, process-local provenance for one canonical Owner storage slot. */
export type OwnerStorageToken = {
    readonly [_ownerStorageTokenBrand]: true;
};
export interface OwnerStorageSnapshotRecord {
    readonly rawOwnerPubkey: unknown;
    readonly token: OwnerStorageToken;
}
export type ConditionalPeerRemoval = {
    readonly outcome: "removed";
    readonly nextToken: OwnerStorageToken;
} | {
    readonly outcome: "stale" | "not_found" | "no_authority";
};
export declare function addPeer(record: PeerRecord): Promise<void>;
/**
 * Returns the set of distinct `remote_epk` values in peers.json.
 *
 * In the current pairing model (plan/23 + plan/24), each `remote_epk` is the
 * Owner's Ed25519 pubkey — and we treat each as a distinct Owner the Pi has
 * been paired with. Used by the mesh self-revoke poller (plan/24 Wave 3) to
 * know which Owners' mesh blobs to fetch.
 */
export declare function listOwnerPubkeys(): Promise<unknown[]>;
/**
 * Atomically snapshots raw Owner handles and their canonical-slot provenance.
 * The token is deliberately process-local and opaque to callers.
 */
export declare function snapshotOwnerPubkeys(): Promise<readonly OwnerStorageSnapshotRecord[]>;
/**
 * Removes one exact raw handle only when its snapshot provenance still owns
 * the target canonical Owner slot. The final authority/token checks and sync
 * write share the existing serialized mutation lane.
 */
export declare function conditionalRemovePeer(remoteEpk: string, expectedToken: OwnerStorageToken, canCommit?: () => boolean): Promise<ConditionalPeerRemoval>;
export declare function removePeer(remoteEpk: string, canCommit?: () => boolean): Promise<boolean>;
/** Test-only: expose the identity-file path so tests can clean it. */
export declare const _IDENTITY_FILE_FOR_TEST: string;
/** Test-only: expose unlink for cleanup. */
export declare const _unlinkIdentityFileForTest: () => Promise<void>;
export {};
