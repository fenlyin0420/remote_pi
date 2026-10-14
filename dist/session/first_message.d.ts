/**
 * Pure helpers for the `room_meta.first_message` title (Plan/46).
 *
 * The Pi publishes the current session's first *user* message in
 * `room_meta.first_message` so a room with no configured agent name shows its
 * opening message on the app instead of the cwd basename. This file holds the
 * non-I/O logic so it can be unit-tested in isolation; `index.ts` wires the
 * result into the control-plane publish (which needs the module state).
 */
export declare const FIRST_MESSAGE_MAX_CHARS = 120;
/**
 * Extracts plain text from a message, mirroring the SDK's `extractTextContent`
 * (which reads `message.content`): a string is used as-is; a block array
 * yields its `text` blocks joined with spaces. `null` when there is no text
 * content at all.
 */
export declare function extractTextContent(message: unknown): string | null;
/**
 * The first user message of the given session, trimmed and truncated to
 * [FIRST_MESSAGE_MAX_CHARS]. Reads the active leaf branch (`getBranch`) on the
 * in-memory session manager, falling back to `getEntries()` when only that
 * view is available — exactly the data the history mirror is seeded from.
 *
 * Walks the entries for the first `message`/`role: "user"` entry with text
 * content. Returns `null` (not an empty string) when the session has no user
 * message yet; the caller decides whether to publish `""` (explicit clear,
 * needed when a session is replaced by a fresh empty one) or omit the field
 * (legacy, no-change). Never throws.
 */
export declare function firstUserMessageForSession(ctx: unknown): string | null;
