export interface AcquiredLock {
    ok: true;
    /** Manual release. Optional — process exit cleans up too. */
    release(): void;
}
export interface RefusedLock {
    ok: false;
    /** Where the live lock socket lives, in case the caller wants to log it. */
    lockPath: string;
}
export type CwdLockResult = AcquiredLock | RefusedLock;
/**
 * Local-IPC address of the lock for a given (cwd, name). Pure helper (no IO).
 * POSIX → a `.sock` file under `locksDir()`; Windows → a per-user named pipe.
 */
export declare function lockPathFor(cwd: string, name?: string): string;
/** Back-compat alias: the cwd-only lock path (no name component). */
export declare function lockPathForCwd(cwd: string): string;
/**
 * Attempts to acquire the cwd lock. Resolves with either:
 *   - `{ ok: true, release }` when we own it (server bound + retained).
 *   - `{ ok: false, lockPath }` when a live Pi already holds the lock.
 *
 * Self-healing path: if the prior holder crashed, the leftover socket file
 * fails `tryConnect` (ECONNREFUSED). We unlink it and retry the bind — the
 * second attempt then succeeds.
 *
 * The server holds no actual listener logic; its only job is to keep the
 * UDS endpoint pinned by the OS. No incoming connection ever does anything
 * useful — the next-Pi-attempt's `tryConnect` succeeding is the entire
 * signal we care about.
 */
export declare function acquireCwdLock(cwd: string, name?: string): Promise<CwdLockResult>;
