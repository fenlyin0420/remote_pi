/**
 * Cron registry: scheduled prompts for daemons, persisted at
 * `~/.pi/remote/cron.json`. Mirrors `registry.ts` (`daemons.json`) — tolerant
 * load (missing/corrupt → empty), atomic-ish full-file save.
 *
 * Each job targets a daemon by its `daemon_id` (the 8-hex id from
 * `daemonIdForCwd`) and fires `prompt` on `schedule` (a cron expression, run
 * by croner in the supervisor). The scheduler engine + `fireJob` live in
 * `supervisor.ts`; this module only owns persistence + schedule validation.
 *
 * Plan/39. Decisions B (croner), C (min-interval 60s), E (audit via cron_log).
 */
/** Minimum allowed interval between two consecutive runs of a schedule. */
export declare const MIN_INTERVAL_MS = 60000;
/** A scheduled prompt. */
export interface CronJob {
    /** `j_<hex>` — random, stable across restarts. */
    id: string;
    /** Target daemon id (`daemonIdForCwd`). */
    daemon_id: string;
    /** Cron expression (croner syntax; optional 6th seconds field supported). */
    schedule: string;
    /** IANA timezone for the schedule (e.g. "America/Sao_Paulo"). */
    tz?: string;
    /** Prompt text injected into the daemon when the job fires. */
    prompt: string;
    enabled: boolean;
    /** Skip the fire when the daemon is mid-turn (default true). */
    skip_if_busy: boolean;
    /** Start the daemon if it's down, then fire (default false). */
    wake: boolean;
    /** On supervisor start, run once if the previous scheduled run was missed
     *  while it was down (default false; at most 1×). */
    catchup: boolean;
    created_at: string;
    last_run?: string;
    /** Last fire result — see cron_log `result` values. Shortcut for `cron list`. */
    last_status?: string;
}
export interface CronRegistry {
    jobs: CronJob[];
}
/** Test/diag-only: the on-disk path. */
export declare function cronRegistryPath(): string;
/** Reads the registry; returns empty on missing/corrupt file. */
export declare function loadCronRegistry(): CronRegistry;
export declare function saveCronRegistry(reg: CronRegistry): void;
export declare function listJobs(): CronJob[];
export declare function getJob(id: string): CronJob | undefined;
/** Fields a caller supplies when creating a job. Flags default sensibly. */
export interface NewJobInput {
    daemon_id: string;
    schedule: string;
    prompt: string;
    tz?: string;
    skip_if_busy?: boolean;
    wake?: boolean;
    catchup?: boolean;
}
/** Adds a job with a fresh `j_<hex>` id. Pure persistence — call
 *  `validateSchedule` first at the op/CLI boundary. */
export declare function addJob(input: NewJobInput): CronJob;
export declare function removeJob(id: string): boolean;
export declare function setJobEnabled(id: string, enabled: boolean): boolean;
/** Records the outcome of a fire on the job (the `cron list` shortcut). */
export declare function recordRun(id: string, at: string, status: string): void;
export interface ScheduleValidation {
    ok: boolean;
    error?: string;
    /** Interval (ms) between the next two runs, when computable. */
    intervalMs?: number;
}
/**
 * Validates a cron expression via croner and enforces the ≥60s min-interval
 * (decision C — guards against pileup + token burn). Returns `ok:false` with a
 * user-facing message on a bad expression or a too-frequent schedule.
 */
export declare function validateSchedule(schedule: string, tz?: string): ScheduleValidation;
/** Returns the next scheduled run for a job, or null. Used by `cron list`. */
export declare function nextRunFor(job: CronJob): Date | null;
