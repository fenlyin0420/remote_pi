/**
 * Plan/25 Wave D — pure formatter for the `/remote-pi peers` output.
 *
 * Lives in its own module so it can be unit-tested without booting the full
 * extension (no keychain access, no relay client, no mocks needed). The
 * extension imports the function and wraps it with the `_sessionPeer`
 * `list_peers` request.
 *
 * Input shape: the broker's `list_peers_reply` body returns peer names as
 * plain strings — local peers without a prefix (`sess-1`, `agent-2`),
 * cross-PC peers with a `<pc_label>:<peer>` prefix (`casa:sess-3`).
 */
export declare function formatPeerInventory(peers: string[], selfName?: string): string;
