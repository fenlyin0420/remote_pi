const K_SESSION = "remote-pi:session";
const K_RELAY = "remote-pi:relay";
const K_PEER = "remote-pi:peer-active";
export function updateFooter(ctx, state) {
    if (state.session) {
        const count = state.peerCount ?? 0;
        ctx.ui.setStatus(K_SESSION, `📡 ${state.session} (${count})`);
    }
    else {
        ctx.ui.setStatus(K_SESSION, undefined);
    }
    if (state.relayOn) {
        ctx.ui.setStatus(K_RELAY, state.hasPairings ? "🟢 relay" : "🟡 relay waiting for pairing");
    }
    else {
        ctx.ui.setStatus(K_RELAY, undefined);
    }
    if (state.devicePaired) {
        ctx.ui.setStatus(K_PEER, `📱 ${state.devicePaired}`);
    }
    else {
        ctx.ui.setStatus(K_PEER, undefined);
    }
    // Terminal title — two parts only: `<agent-name> · <On|Off>`.
    // Pre-2026-05-24 the title carried three segments (`name · local · relay`),
    // but `local` was always the same string (single fixed UDS session) and
    // `relay` repeated information the relay slot already shows. Collapsed
    // to "name + relay state in plain English" — same info, clearer at a
    // glance: terminal tabs read like `backend · On` / `backend · Off`.
    const prefix = state.agentName?.trim() || "Pi";
    const relayState = state.relayOn ? "On" : "Off";
    ctx.ui.setTitle(`${prefix} · ${relayState}`);
}
//# sourceMappingURL=footer.js.map