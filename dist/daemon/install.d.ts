/**
 * Generates and activates a system service for `pi-supervisord` so the
 * daemon fleet survives reboots (plan/26 W3).
 *
 * Platform support:
 *   - **macOS**: writes `~/Library/LaunchAgents/dev.remotepi.supervisord.plist`
 *     and runs `launchctl bootstrap gui/<uid> <plist>` (modern API) with a
 *     fallback to `launchctl load` for older macOS.
 *   - **Linux**: writes `~/.config/systemd/user/remote-pi-supervisord.service`
 *     and runs `systemctl --user daemon-reload && systemctl --user enable
 *     --now remote-pi-supervisord.service`.
 *
 * Uninstall reverses both. Idempotent — re-running install over an existing
 * unit refreshes it (paths could have changed if user moved node_modules).
 *
 * **What does NOT happen here**: the actual `npm install -g remote-pi` step.
 * The user has to make the supervisor bin reachable on disk before install
 * can wire up the service. The `findSupervisorScript` resolver detects
 * common cases (npm global, pnpm global, local dev clone) and yields a
 * clear error otherwise.
 */
export type SupervisorPlatform = "macos" | "linux" | "windows" | "unsupported";
export declare function detectPlatform(): SupervisorPlatform;
/**
 * Absolute path to the supervisor's compiled entry. We resolve from
 * `import.meta.url` (this file's location) since wherever the daemon
 * module lives, `bin/supervisord.js` is a sibling of `daemon/` under
 * `dist/`.
 *
 * After build: `dist/daemon/install.js` → `dist/bin/supervisord.js`.
 * In dev (`tsx`): same path resolution still lands inside `src/`, which
 * isn't directly runnable by `node` — dev install isn't expected.
 */
export declare function findSupervisorScript(): string;
/**
 * Absolute path to the extension's CLI entry (`dist/index.js`). This is
 * the file we symlink to `~/.local/bin/remote-pi` so the user can run
 * `remote-pi <subcommand>` from any shell after installing the extension
 * through Pi (`pi install npm:remote-pi`).
 *
 * Same resolution strategy as `findSupervisorScript`: from
 * `dist/daemon/install.js` → `dist/index.js`.
 */
export declare function findRemotePiScript(): string;
export declare function findNodeBinary(): string;
export declare function findTemplate(name: "systemd" | "launchd" | "taskscheduler" | "vbs-launcher"): string;
export declare function systemdUnitPath(): string;
export declare function launchdPlistPath(): string;
export declare const LAUNCHD_LABEL = "dev.remotepi.supervisord";
/** systemd --user unit name (with `.service`) for the supervisor. */
export declare const SYSTEMD_UNIT = "remote-pi-supervisord.service";
/** Windows Task Scheduler task name (plan/40). */
export declare const WINDOWS_TASK_NAME = "RemotePiSupervisor";
/** Path of the rendered Task Scheduler XML (input to `schtasks /Create /XML`). */
export declare function taskXmlPath(): string;
/**
 * Path of the rendered VBScript launcher the Task Scheduler action invokes
 * via `wscript.exe` (plan/40, Windows). Launching node through this hidden
 * wrapper is what keeps the supervisor from flashing a console window.
 */
export declare function vbsLauncherPath(): string;
/**
 * Combined stdout/stderr log for the Windows supervisor. The Task Scheduler
 * launches it hidden via wscript, so without this redirect its output (and the
 * forwarded daemon-child stderr) would vanish — mirrors launchd/systemd, which
 * already log to `~/.pi/remote/supervisord.log`.
 */
export declare function supervisordLogPath(): string;
export interface RenderVars {
    node: string;
    supervisor: string;
    home: string;
    user: string;
    /** PATH inherited so `pi --mode rpc` resolves the same way it does
     *  interactively. We snapshot `process.env.PATH` at install time. */
    path: string;
    /** Windows only: absolute path of the VBScript launcher the Task Scheduler
     *  action runs via `wscript.exe`. Empty on POSIX (templates ignore `{VBS}`). */
    vbs: string;
    /** Windows only: combined stdout/stderr log the hidden supervisor appends to.
     *  Empty on POSIX (templates ignore `{LOG}`). */
    logPath: string;
}
export declare function defaultRenderVars(): RenderVars;
/** Replace `{NODE}` / `{SUPERVISOR}` / `{USER}` / `{HOME}` / `{PATH}` / `{VBS}` / `{LOG}`. */
export declare function renderTemplate(template: string, vars: RenderVars): string;
export interface InstallResult {
    platform: SupervisorPlatform;
    unitPath: string;
    /** Lines describing each step taken — surfaced to the user via notify. */
    log: string[];
}
/**
 * Writes the unit/plist, runs the platform's activation command. Throws
 * on unsupported OS or when the supervisor script isn't found.
 *
 * Idempotent: re-running re-writes the unit (paths could have changed)
 * and re-activates via the platform tool's idempotent flag.
 */
export declare function installService(vars?: RenderVars): InstallResult;
export interface UninstallResult {
    platform: SupervisorPlatform;
    unitPath: string;
    removed: boolean;
    log: string[];
}
export declare function uninstallService(): UninstallResult;
/**
 * Build the batch script run elevated. Each command line redirects its output
 * to `logFile` so the (separate, elevated) process's output can be read back by
 * the parent. Control-flow lines (`if`/`exit`/`rem`/`@`) run bare — redirecting
 * them would swallow the exit code. Pure + exported for tests.
 */
export declare function buildElevatedCmd(lines: string[], logFile: string): string;
export interface LinkBinariesResult {
    /** `~/.local/bin/`. The two symlinks land here. */
    binDir: string;
    /** Paths of the two symlinks we created/refreshed. */
    links: Array<{
        name: string;
        path: string;
        target: string;
    }>;
    /** True when `binDir` is already on `$PATH`. False → caller surfaces the
     *  "add this line to your shell rc" hint to the user. */
    onPath: boolean;
    log: string[];
}
export declare function userLocalBinDir(home?: string): string;
/**
 * Check whether `dir` is on `process.env.PATH`. Tolerates trailing
 * slashes and relative entries (which we treat as not matching — `~/.local/bin`
 * is always absolute on our end).
 */
export declare function isOnPath(dir: string, envPath?: string): boolean;
/**
 * Create (or refresh) the `remote-pi` + `pi-supervisord` symlinks in
 * `~/.local/bin/`. Idempotent — replaces stale links pointing at old
 * extension paths (Pi can reinstall the extension to a different hash dir
 * on upgrades, so this MUST overwrite).
 *
 * Returns `onPath: false` when `~/.local/bin` isn't in the user's `$PATH`.
 * The caller is responsible for surfacing the shell-rc instruction —
 * we don't edit the user's shell config files automatically.
 */
export declare function linkCliBinaries(home?: string, paths?: {
    remotePi?: string;
    supervisord?: string;
}, opts?: {
    node?: string;
    mutatePath?: boolean;
}): LinkBinariesResult;
/** A Windows `.cmd` shim that forwards all args to `node "<target>"`. Pure. */
export declare function buildCmdShim(node: string, target: string): string;
/**
 * Remove the symlinks `linkCliBinaries` created. Idempotent — missing
 * links are a no-op. Returns whether each link was actually present so
 * the caller can render a useful summary. Targets (the extension files)
 * are NOT touched here — they live outside this dir and belong to Pi.
 */
export interface UnlinkBinariesResult {
    binDir: string;
    removed: Array<{
        name: string;
        path: string;
        existed: boolean;
    }>;
    log: string[];
}
export declare function unlinkCliBinaries(home?: string): UnlinkBinariesResult;
