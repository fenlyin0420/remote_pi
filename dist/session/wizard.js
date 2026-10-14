import { listSessions, sessionHasSock } from "./global_config.js";
const CREATE_SENTINEL = "━━━ Create new session ━━━";
export async function joinWizard(ui, defaultName) {
    const sessions = listSessions();
    const liveSessions = sessions.filter(sessionHasSock);
    const options = [...liveSessions, CREATE_SENTINEL];
    const picked = await ui.select(liveSessions.length
        ? "Choose a session to join, or create a new one"
        : "No active sessions. Create one?", options);
    if (!picked)
        return null;
    if (picked === CREATE_SENTINEL) {
        // Caller is expected to follow up with a name prompt via ctx.ui.select
        // (the Pi SDK input dialog). For non-interactive contexts we return the
        // default name.
        return defaultName;
    }
    return picked;
}
//# sourceMappingURL=wizard.js.map