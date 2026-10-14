export function formatMeshAckResult(to, ack) {
    switch (ack.status) {
        case "received":
            return textResult(`Delivered to ${ack.target ?? to}`);
        case "busy":
            return errorResult(`NOT delivered — "${to}" came back BUSY, which only happens when an ` +
                `OUT-OF-DATE broker leader dropped the message (busy was removed in the ` +
                `current version). Restart the agent that leads the local broker (the ` +
                `oldest Pi/remote-pi process) so it picks up the new build, then resend.`);
        case "denied":
            return errorResult(formatDenied(to, ack));
        case "timeout":
            return errorResult(formatTimeout(to, ack));
    }
}
function formatDenied(to, ack) {
    const errorSuffix = ack.error ? ` (${ack.error})` : "";
    if (ack.reason === "not_authorized") {
        return `Relay did not authorize delivery to ${to}${errorSuffix}. ` +
            `Do not blindly retry; verify authorization first.`;
    }
    if (ack.reason === "bad_envelope") {
        return `Relay rejected the envelope for ${to}${errorSuffix}. ` +
            `Do not blindly retry; correct the envelope first.`;
    }
    return `${to} denied the message`;
}
function formatTimeout(to, ack) {
    if (ack.reason === "offline") {
        const errorSuffix = ack.error ? ` (${ack.error})` : "";
        return `Immediate Relay offline transport error for ${to}${errorSuffix}; ` +
            `reported as timeout without waiting for an ACK.`;
    }
    return `No ACK from ${to} (timeout) — peer may be offline`;
}
function textResult(text) {
    return { content: [{ type: "text", text }] };
}
function errorResult(text) {
    return { content: [{ type: "text", text }], isError: true };
}
//# sourceMappingURL=mesh_result.js.map