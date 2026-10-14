/**
 * Deterministic room id derived from a cwd. Two Pi processes in the same
 * directory produce the same id; different cwds produce different ids
 * (with cryptographic-strength collision resistance). Symlinks are resolved
 * via `realpath` so `/a` and `/symlink-to-a` map to the same room.
 *
 * Format: first 12 chars of base64url(sha256(realpath)).
 */
export declare function roomIdForCwd(cwd: string): string;
/**
 * THE single derivation of the App↔Pi `room_id` (plan/41) — keyed by
 * `(cwd, name)` so several agents in the SAME folder get distinct rooms (the
 * app then renders one tile per agent instead of merging them into one).
 *
 * Default-preserving: when `name` is absent OR equals `defaultAgentName(cwd)`
 * (an agent with no custom `agent_name`), it returns the LEGACY `roomIdForCwd`
 * EXACTLY — so a single unnamed agent's existing conversation is NOT re-keyed
 * on upgrade. A custom or `#N`-suffixed name → a name-scoped id (same formula
 * the cwd-lock uses).
 *
 * Using the ASSIGNED leaf name (the broker's `#N` on collision) disambiguates
 * even two unnamed agents: the 1st stays `folder` (== default → legacy room),
 * the 2nd becomes `folder#2` (≠ default → name-scoped room).
 *
 * INVARIANT: every callsite that derives the App↔Pi room for the same agent
 * MUST go through this function — otherwise the app would pair on a room the
 * Pi never announces.
 */
export declare function roomIdFor(cwd: string, name?: string): string;
