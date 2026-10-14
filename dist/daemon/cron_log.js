import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
const PREVIEW_LEN = 80;
function logPath() {
    const root = process.env["REMOTE_PI_HOME"] || homedir();
    return join(root, ".pi", "remote", "cron.jsonl");
}
/** Test/diag-only: the on-disk path. */
export function cronLogPath() {
    return logPath();
}
/** Maps a result to whether a prompt was actually delivered. */
export function firedFor(result) {
    return result === "delivered" || result === "woke_and_delivered";
}
/**
 * Appends one entry. Best-effort: creates the parent dir + file when absent;
 * never throws into the scheduler (a logging failure must not abort a fire).
 */
export function appendCronLog(entry) {
    const line = JSON.stringify({
        ts: Date.now(),
        job_id: entry.job_id,
        daemon_id: entry.daemon_id,
        schedule: entry.schedule,
        fired: firedFor(entry.result),
        result: entry.result,
        prompt_preview: entry.prompt.slice(0, PREVIEW_LEN),
    }) + "\n";
    try {
        mkdirSync(dirname(logPath()), { recursive: true });
        appendFileSync(logPath(), line, "utf8");
    }
    catch {
        /* audit is best-effort — don't break the scheduler on a write error */
    }
}
/**
 * Reads the log, newest-last. Optional `jobId` filter and `tail` (last N).
 * Missing file → []. Malformed lines are skipped.
 */
export function readCronLog(opts = {}) {
    if (!existsSync(logPath()))
        return [];
    let raw;
    try {
        raw = readFileSync(logPath(), "utf8");
    }
    catch {
        return [];
    }
    const entries = [];
    for (const line of raw.split("\n")) {
        if (!line.trim())
            continue;
        try {
            const e = JSON.parse(line);
            if (opts.jobId && e.job_id !== opts.jobId)
                continue;
            entries.push(e);
        }
        catch {
            /* skip malformed */
        }
    }
    if (opts.tail !== undefined && opts.tail >= 0 && entries.length > opts.tail) {
        return entries.slice(entries.length - opts.tail);
    }
    return entries;
}
//# sourceMappingURL=cron_log.js.map