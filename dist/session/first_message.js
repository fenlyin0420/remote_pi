/**
 * Pure helpers for the `room_meta.first_message` title (Plan/46).
 *
 * The Pi publishes the current session's first *user* message in
 * `room_meta.first_message` so a room with no configured agent name shows its
 * opening message on the app instead of the cwd basename. This file holds the
 * non-I/O logic so it can be unit-tested in isolation; `index.ts` wires the
 * result into the control-plane publish (which needs the module state).
 */
export const FIRST_MESSAGE_MAX_CHARS = 120;
/**
 * Extracts plain text from a message, mirroring the SDK's `extractTextContent`
 * (which reads `message.content`): a string is used as-is; a block array
 * yields its `text` blocks joined with spaces. `null` when there is no text
 * content at all.
 */
export function extractTextContent(message) {
    if (!message || typeof message !== "object")
        return null;
    const content = message.content;
    if (typeof content === "string")
        return content;
    if (Array.isArray(content)) {
        return content
            .filter((b) => b &&
            typeof b !== "string" &&
            b.type === "text" &&
            typeof b.text === "string")
            .map((b) => b.text)
            .join(" ");
    }
    return null;
}
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
export function firstUserMessageForSession(ctx) {
    try {
        const sm = ctx?.sessionManager;
        const entries = sm?.getBranch?.() ?? sm?.getEntries?.();
        if (!Array.isArray(entries))
            return null;
        for (const entry of entries) {
            if (!(entry && typeof entry === "object"))
                continue;
            const e = entry;
            if (e.type !== "message" || !e.message)
                continue;
            const message = e.message;
            if (message.role !== "user")
                continue;
            const text = extractTextContent(message);
            if (text == null)
                continue;
            const normalized = text.replace(/\s+/g, " ").trim();
            if (!normalized)
                continue;
            return normalized.length > FIRST_MESSAGE_MAX_CHARS
                ? normalized.slice(0, FIRST_MESSAGE_MAX_CHARS)
                : normalized;
        }
    }
    catch { /* defensive — never block a turn on title computation */ }
    return null;
}
//# sourceMappingURL=first_message.js.map