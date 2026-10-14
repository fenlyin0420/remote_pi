/**
 * Cross-platform local-IPC address resolution (plan/40).
 *
 * Node's `net` implements local IPC differently per OS:
 *   - **POSIX**: a filesystem Unix-domain socket — a `.sock` path under
 *     `~/.pi/remote/`. The file lingers if the owner crashes (stale-socket
 *     cleanup via `unlink` matters).
 *   - **Windows**: a **named pipe** (`\\.\pipe\<name>`). There is NO file —
 *     `existsSync`/`unlink` don't apply, and the pipe vanishes automatically
 *     when the owning process exits (so there's never a stale pipe to clean).
 *     Pipes are machine-global, so the name embeds the user to avoid collisions
 *     between two accounts on the same host.
 *
 * The `net` API itself (`createServer().listen(addr)`, `createConnection({ path:
 * addr })`, framing) is identical — only the address STRING and the lifecycle
 * (skip file cleanup on Windows) change. `platform`/`user` are injectable so
 * tests can exercise the win32 branch on a POSIX dev host.
 */
export type Plat = NodeJS.Platform;
/** True when local IPC uses named pipes (no socket files to manage). */
export declare function usesNamedPipe(plat?: Plat): boolean;
/**
 * Resolve a local-IPC address. On Windows returns a per-user named pipe
 * (`\\.\pipe\remote-pi-<suffix>-<user>`); on POSIX returns `filePath` (the
 * filesystem UDS path) unchanged.
 */
export declare function ipcAddress(suffix: string, filePath: string, plat?: Plat, user?: string): string;
