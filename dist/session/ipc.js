import { platform as osPlatform, userInfo } from "node:os";
/** True when local IPC uses named pipes (no socket files to manage). */
export function usesNamedPipe(plat = osPlatform()) {
    return plat === "win32";
}
/** Keep a name component safe for a Windows pipe path. */
function safe(s) {
    return s.replace(/[^A-Za-z0-9_.-]/g, "_");
}
/**
 * Resolve a local-IPC address. On Windows returns a per-user named pipe
 * (`\\.\pipe\remote-pi-<suffix>-<user>`); on POSIX returns `filePath` (the
 * filesystem UDS path) unchanged.
 */
export function ipcAddress(suffix, filePath, plat = osPlatform(), user) {
    if (plat === "win32") {
        const u = safe((user ?? userInfo().username) || "user");
        return `\\\\.\\pipe\\remote-pi-${safe(suffix)}-${u}`;
    }
    return filePath;
}
//# sourceMappingURL=ipc.js.map