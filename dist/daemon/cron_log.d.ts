/**
 * Append-only audit trail for cron fires at `~/.pi/remote/cron.jsonl`.
 *
 * One JSON line per scheduler decision — **every fire AND every skip** — so an
 * operator can see exactly what ran and what didn't (the agent's output goes
 * fire-and-forget to the relay/mesh, so the dispatch itself needs its own
 * trail). Plan/39 decision E.
 */
/** Outcome of a single `fireJob` decision. */
export type CronResult = "delivered" | "deliver_failed" | "woke_and_delivered" | "skipped_busy" | "skipped_down" | "skipped_disabled";
export interface CronLogEntry {
    /** epoch ms */
    ts: number;
    job_id: string;
    daemon_id: string;
    schedule: string;
    /** true when a prompt was actually sent (delivered / woke_and_delivered). */
    fired: boolean;
    result: CronResult;
    /** First chars of the prompt, for at-a-glance log reading. */
    prompt_preview: string;
}
/** Test/diag-only: the on-disk path. */
export declare function cronLogPath(): string;
/** Maps a result to whether a prompt was actually delivered. */
export declare function firedFor(result: CronResult): boolean;
/**
 * Appends one entry. Best-effort: creates the parent dir + file when absent;
 * never throws into the scheduler (a logging failure must not abort a fire).
 */
export declare function appendCronLog(entry: {
    job_id: string;
    daemon_id: string;
    schedule: string;
    result: CronResult;
    prompt: string;
}): void;
/**
 * Reads the log, newest-last. Optional `jobId` filter and `tail` (last N).
 * Missing file → []. Malformed lines are skipped.
 */
export declare function readCronLog(opts?: {
    jobId?: string;
    tail?: number;
}): CronLogEntry[];
