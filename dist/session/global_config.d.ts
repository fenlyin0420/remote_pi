/**
 * Fixed UDS session name. The local mesh is single per machine — every Pi
 * process on the host shares this broker. Previous versions exposed
 * multi-session support (named sessions, leave/rename/sessions commands);
 * those were removed in the 2026-05-23 simplification because in practice
 * every install converged on one session anyway and multi-session UX added
 * friction without value.
 */
export declare const LOCAL_SESSION_NAME = "local";
/** Ensures the new subdirs exist inside the existing ~/.pi/remote/. */
export declare function ensureGlobalDirs(): void;
/**
 * Local-IPC address for a session's broker. POSIX → a `.sock` file under the
 * session dir; Windows → a per-user named pipe (plan/40). The `net` API treats
 * both the same; only the address string differs.
 */
export declare function sessionSockPath(name: string): string;
/** Path to the audit log for a named session. */
export declare function sessionAuditPath(name: string): string;
/** Path to the session metadata JSON. */
export declare function sessionMetaPath(name: string): string;
export declare function sessionsDir(): string;
export declare function skillsDir(): string;
/** Lists discovered session names from disk. */
export declare function listSessions(): string[];
/**
 * Heuristic: a session has an existing broker socket FILE (POSIX only). On
 * Windows the broker is a named pipe with no file to stat, so this returns
 * false — the authoritative liveness check there is a connect-probe
 * (`leader_election.tryConnect` / `client.supervisorOnline`), not this. Only
 * legacy `session/wizard.ts` consumes this.
 */
export declare function sessionHasSock(name: string): boolean;
