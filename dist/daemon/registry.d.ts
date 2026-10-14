export interface DaemonEntry {
    /** Absolute realpath of the cwd this daemon manages. */
    cwd: string;
    /**
     * Display name (mesh `agent_name`). Persisted here because the supervisor
     * now injects the daemon's config via `REMOTE_PI_DIRECT_CONFIG` at spawn
     * instead of reading a per-cwd `.pi/remote-pi/config.json`. Legacy entries
     * (cwd only) fall back to `defaultAgentName(cwd)`.
     */
    name?: string;
}
export interface DaemonRegistry {
    daemons: DaemonEntry[];
}
/**
 * Normalizes a user-provided path: expands `~`/`~/...`, resolves relative
 * components against `process.cwd()`, and runs `realpath` to canonicalize
 * symlinks. Throws if the resulting path doesn't exist on disk.
 *
 * `/remote-pi create` always stores normalized paths so two registrations
 * of the same logical folder via different aliases produce a single entry.
 */
export declare function normalizeCwd(input: string): string;
/** Reads the registry, returning an empty one when the file is absent. */
export declare function loadRegistry(): DaemonRegistry;
export declare function saveRegistry(reg: DaemonRegistry): void;
/**
 * Adds a daemon entry. Refuses duplicates (same normalized cwd already
 * present). Returns the derived id + normalized cwd so the caller can
 * report it back to the user.
 */
export declare function addDaemon(rawCwd: string, name?: string): {
    id: string;
    cwd: string;
    name: string;
};
/**
 * Removes the daemon entry whose derived id matches `id`. Returns the
 * removed cwd (if any). Does NOT touch the cwd's local config — `create`
 * the same cwd later restores the registration idempotently.
 */
export declare function removeDaemon(id: string): {
    removed: boolean;
    cwd?: string;
};
/** Snapshot of all registered daemons with derived ids. Order matches the
 *  file's insertion order — first-registered first. */
export declare function listDaemons(): Array<{
    id: string;
    cwd: string;
    name: string;
}>;
/**
 * One-shot migration: backfill `name` (folder-derived) into legacy entries
 * that predate the name field, persisting the change to `daemons.json`.
 * Idempotent — writes only when something was missing. Returns how many
 * entries were backfilled. The supervisor runs this on start.
 */
export declare function migrateRegistryNames(): number;
/** Test/diag-only: returns the on-disk path. Exported so tests can poke
 *  at it (e.g. tmpdir override is done via env, but for now the path is
 *  hardcoded to ~/.pi/remote/daemons.json). */
export declare function registryPath(): string;
