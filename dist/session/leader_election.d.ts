import { Server, Socket } from "node:net";
export type ElectionResult = {
    role: "leader";
    server: Server;
} | {
    role: "follower";
    socket: Socket;
};
/**
 * UDS-based leader election. Tries to connect to `sockPath`; on failure, tries
 * to bind. If both lose the race (EADDRINUSE on bind, ECONNREFUSED on connect),
 * cleans up stale sock file and retries with jittered backoff.
 *
 * Returns the role + the live handle (server for leader, socket for follower).
 */
export declare function joinOrLead(sockPath: string): Promise<ElectionResult>;
/**
 * Probes a UDS path: if a live listener responds, returns the connected
 * socket; otherwise returns null (timeout or ECONNREFUSED). Exported so
 * the cwd-lock primitive can reuse it without duplicating the OS dance.
 */
export declare function tryConnect(sockPath: string): Promise<Socket | null>;
/**
 * Attempts to bind a UDS server on `sockPath`. Returns the live server on
 * success, null when the path is already held (EADDRINUSE) or any other
 * bind error. Caller is responsible for `unlink`ing a stale sock file
 * before retrying.
 */
export declare function tryBind(sockPath: string): Promise<Server | null>;
/** Unlinks the sock file if it exists and is actually a socket. No-op
 *  otherwise. Used to clear stale sockets left behind by a crashed peer. */
export declare function removeStaleSock(sockPath: string): void;
