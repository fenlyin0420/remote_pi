import { type ControlReplyFor, type ControlRequest } from "./control_protocol.js";
export declare class SupervisorOfflineError extends Error {
    readonly sockPath: string;
    constructor(sockPath: string);
}
/**
 * Sends a single request and returns the typed reply data.
 *
 * Throws:
 *   - `SupervisorOfflineError` when the supervisor isn't reachable.
 *   - `Error` from `parseReply` when the reply line is malformed.
 *   - The supervisor's own error string when `ok: false`.
 */
export declare function callSupervisor<Op extends ControlRequest["op"]>(req: Extract<ControlRequest, {
    op: Op;
}>): Promise<ControlReplyFor<Op>>;
/** Returns true when the supervisor is reachable. Used by `/remote-pi
 *  daemons` to decide whether to query runtime state or fall back to
 *  registry-only listing. */
export declare function supervisorOnline(): Promise<boolean>;
