/**
 * Escape hatch: when set, carries the WHOLE local config as inline JSON,
 * bypassing the on-disk `config.json`. For CI/ops/daemons that inject config
 * via env instead of writing a file — mirrors `REMOTE_PI_RELAY` for the relay
 * URL. Takes precedence over the file; an unset/empty/unparseable value falls
 * back to the file (never fatal).
 */
export declare const DIRECT_CONFIG_ENV = "REMOTE_PI_DIRECT_CONFIG";
export interface LocalConfig {
    agent_name?: string;
    /**
     * If true (default), `/remote-pi` with no args auto-joins the local UDS
     * mesh and starts the relay on a fresh terminal. The field name is
     * historical (plano 21); the UX wording was reworked to "use the relay
     * on this terminal to connect to the remote mesh (mobile + PCs)". Legacy
     * configs without this field are treated as `true` for backward compat.
     */
    auto_start_relay?: boolean;
}
/**
 * Normalize a name segment to a mesh-safe token: trim, replace the addressing
 * separators (`/ : @ #`) and whitespace runs with `-`, collapse repeats, strip
 * edges. The `@` is included so a sanitized name can never contain the address
 * separator — `<cwd>@<name>` stays unambiguous on the wire. Returns undefined
 * when the input isn't a usable non-empty string, sanitizes to empty, or is a
 * reserved addressing keyword (`broadcast` / `broker`). Used by the broker's
 * `sanitizeMeshName` to keep the `<nome>` half of a peer address safe to
 * compose (plan/38).
 */
export declare function sanitizeSegment(v: unknown): string | undefined;
/**
 * Migrate a persisted `agent_name` to the plan/38 leaf-name model (decision E).
 * Two legacy shapes get rewritten on read so a pre-fix config never fossilizes a
 * runtime accident as if it were an explicit choice:
 *
 *   - **`#N` collision suffix** — could only have come from a broker/lock
 *     assignment (the user can't type `#`: `sanitizeSegment` maps it to `-`), so
 *     a trailing `#<digits>` is stripped and the clean base re-derived.
 *   - **legacy `parent/folder`** — the old `defaultAgentName` shape; the `/`
 *     means it predates the leaf-only model, so we keep only the leaf segment.
 *
 * Returns the cleaned name, or undefined when nothing usable remains (so the
 * caller falls back to `defaultAgentName(cwd)`).
 */
export declare function migrateAgentName(raw: string): string | undefined;
/**
 * True when a local config is available for this cwd — either inline via
 * `REMOTE_PI_DIRECT_CONFIG` or as `<cwd>/.pi/remote-pi/config.json` on disk.
 */
export declare function localConfigExists(cwd: string): boolean;
export declare function loadLocalConfig(cwd: string): LocalConfig;
export declare function saveLocalConfig(cwd: string, patch: Partial<LocalConfig>): void;
/**
 * Default agent name when none is configured (plan/38 decision D): the **leaf**
 * of the cwd, `basename(cwd)`. The cwd now travels as its own address axis
 * (`<cwd>@<nome>`), so the name no longer needs the `parent/folder` prefix that
 * used to disambiguate folders — the broker keys peers by `(cwd, nome)`, and a
 * clean leaf means `#N` almost never fires. Falls back to `"agent"` for a
 * path with no usable basename (root / empty).
 */
export declare function defaultAgentName(cwd: string): string;
/** Resolves auto_start_relay with backward-compat (undefined → true). */
export declare function effectiveAutoStartRelay(cfg: LocalConfig): boolean;
