import { afterEach, beforeEach, describe, expect, test } from "vitest";
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { createConnection } from "node:net";
import { join } from "node:path";
import { Supervisor, getSupervisorSockPath } from "./supervisor.js";
import { addDaemon, loadRegistry, registryPath } from "./registry.js";
import { roomIdFor } from "../rooms.js";
import { defaultAgentName } from "../session/local_config.js";
import {
  encodeRequest,
  parseReply,
  type ControlReply,
  type ControlRequest,
} from "./control_protocol.js";

/**
 * Ephemeral (phone-created) rooms — the supervisor's `spawn`/`kill` ops.
 *
 * Unlike `supervisor.test.ts` (where the fake child dies instantly), this
 * file's child is a long-sleeping `sh` stub so states are deterministic
 * while the ops run. A cwd containing `.crash` makes the child exit
 * immediately, to exercise the "crash = drop, no auto-restart" rule.
 */

let testHome: string;
let supervisor: Supervisor | null = null;
let fakePi: string;

async function ask<R = ControlReply<unknown>>(req: ControlRequest): Promise<R> {
  return new Promise((resolve, reject) => {
    const sock = createConnection({ path: getSupervisorSockPath() });
    let buf = "";
    sock.setEncoding("utf8");
    sock.on("data", (chunk: string) => {
      buf += chunk;
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        sock.destroy();
        try { resolve(parseReply(buf.slice(0, nl)) as R); }
        catch (e) { reject(e); }
      }
    });
    sock.on("error", reject);
    sock.write(encodeRequest(req));
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

beforeEach(async () => {
  testHome = mkdtempSync(join(tmpdir(), "pi-sv-eph-"));
  process.env["REMOTE_PI_HOME"] = testHome;
  // The spawned "Pi" is a POSIX sh stub (same convention as
  // rpc_child.test.ts): it ignores pi's RPC args, sleeps for an hour so it
  // stays `running` while the ops run, and exits 1 (a crash) when its cwd
  // carries the `.crash` marker.
  fakePi = join(testHome, "fake-pi");
  writeFileSync(
    fakePi,
    "#!/bin/sh\n" +
    "case \"$PWD\" in\n" +
    "*.crash*) exit 1;;\n" +
    "*) exec sleep 3600;;\n" +
    "esac\n",
  );
  chmodSync(fakePi, 0o755);
  supervisor = new Supervisor({ extensionPath: "/no/such/extension.js", piBin: fakePi });
  await supervisor.start();
});

afterEach(async () => {
  if (supervisor) {
    await supervisor.stop();
    supervisor = null;
  }
  delete process.env["REMOTE_PI_HOME"];
  try { rmSync(testHome, { recursive: true, force: true }); } catch { /* best-effort */ }
});

describe("Supervisor — ephemeral (phone) rooms", () => {
  test("spawn creates a room keyed by (cwd, name) and never touches the daemon registry", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-cwd-"));
    const r = await ask({ op: "spawn", cwd: tmp, name: "pi-remote" }) as ControlReply<{
      room_id: string; started: boolean; name: string;
    }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.name).toBe("pi-remote");
      expect(r.data!.started).toBe(true);
      expect(r.data!.room_id).toBe(roomIdFor(tmp, "pi-remote"));
      // The registry file must not even exist after a phone create.
      expect(existsSync(registryPath())).toBe(false);
      expect(loadRegistry().daemons).toEqual([]);
      // And the daemon bookkeeping (`list`) stays empty.
      const list = await ask({ op: "list" }) as ControlReply<{ daemons: unknown[] }>;
      expect(list.ok && list.data!.daemons).toEqual([]);
    }
    // The room must be killable through its room_id.
    const kill = await ask({ op: "kill", room_id: roomIdFor(tmp, "pi-remote") }) as ControlReply<{ killed: boolean }>;
    expect(kill.ok && kill.data!.killed).toBe(true);
  });

  test("spawn without a name uses the folder's default agent name", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-def-"));
    const r = await ask({ op: "spawn", cwd: tmp }) as ControlReply<{ room_id: string; name: string }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.name).toBe(defaultAgentName(tmp));
      expect(r.data!.room_id).toBe(roomIdFor(tmp, defaultAgentName(tmp)));
    }
  });

  test("spawn is idempotent for an already-running (cwd, name) room", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-idem-"));
    const first = await ask({ op: "spawn", cwd: tmp, name: "proj" }) as ControlReply<{ room_id: string; started: boolean }>;
    const second = await ask({ op: "spawn", cwd: tmp, name: "proj" }) as ControlReply<{ room_id: string; started: boolean }>;
    expect(first.ok).toBe(true);
    expect(second.ok).toBe(true);
    if (first.ok && second.ok) {
      expect(second.data!.room_id).toBe(first.data!.room_id);
      expect(second.data!.started).toBe(false);
    }
  });

  test("spawn steps to the next #N when a running daemon already holds the name", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-coll-"));
    const reg = addDaemon(tmp);
    const start = await ask({ op: "start", id: reg.id });
    expect(start.ok).toBe(true);
    const defaultName = defaultAgentName(tmp);
    const r = await ask({ op: "spawn", cwd: tmp, name: defaultName }) as ControlReply<{ room_id: string; name: string }>;
    expect(r.ok).toBe(true);
    if (r.ok) {
      expect(r.data!.name).toBe(`${defaultName}#2`);
      expect(r.data!.room_id).toBe(roomIdFor(tmp, `${defaultName}#2`));
    }
    // A name the daemon does not hold is used as-is.
    const r2 = await ask({ op: "spawn", cwd: tmp, name: "other" }) as ControlReply<{ name: string }>;
    expect(r2.ok && r2.data!.name).toBe("other");
  });

  test("spawn steps past a daemon that holds a custom #N name", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-cust-"));
    const reg = addDaemon(tmp, "proj#2");
    const start = await ask({ op: "start", id: reg.id });
    expect(start.ok).toBe(true);
    const r = await ask({ op: "spawn", cwd: tmp, name: "proj#2" }) as ControlReply<{ name: string }>;
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.data!.name).toBe("proj#3");
  });

  test("kill stops a live ephemeral room and is idempotent after", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-kill-"));
    const roomId = roomIdFor(tmp, "proj");
    await ask({ op: "spawn", cwd: tmp, name: "proj" });
    const first = await ask({ op: "kill", room_id: roomId }) as ControlReply<{ killed: boolean }>;
    expect(first.ok && first.data!.killed).toBe(true);
    await sleep(50);
    const second = await ask({ op: "kill", room_id: roomId }) as ControlReply<{ killed: boolean }>;
    expect(second.ok && second.data!.killed).toBe(false);
  });

  test("kill of an unknown room_id is killed:false, not an error", async () => {
    const r = await ask({ op: "kill", room_id: "deadbeef0000" }) as ControlReply<{ killed: boolean }>;
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.data!.killed).toBe(false);
  });

  test("kill finds an ephemeral by (cwd, name) when the room_id differs", async () => {
    // The child's cwd lock may land on a neighbouring `#N`, so the announced
    // room id can differ from the predicted one — the phone's room_delete
    // must still reach the room.
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-byname-"));
    await ask({ op: "spawn", cwd: tmp, name: "proj" });
    const kill = await ask({
      op: "kill",
      room_id: "deadbeef0000",
      cwd: tmp,
      name: "proj",
    }) as ControlReply<{ killed: boolean }>;
    expect(kill.ok && kill.data!.killed).toBe(true);
    // Idempotent: the slot is gone.
    const again = await ask({
      op: "kill",
      room_id: "deadbeef0000",
      cwd: tmp,
      name: "proj",
    }) as ControlReply<{ killed: boolean }>;
    expect(again.ok && again.data!.killed).toBe(false);
  });

  test("a crashed ephemeral room is dropped with NO auto-restart", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph.crash-"));
    const r = await ask({ op: "spawn", cwd: tmp, name: "proj" }) as ControlReply<{ room_id: string }>;
    expect(r.ok).toBe(true);
    const roomId = r.ok ? r.data!.room_id : "";
    // Let the child crash (exit 1) and the supervisor drop the slot.
    await sleep(300);
    const kill = await ask({ op: "kill", room_id: roomId }) as ControlReply<{ killed: boolean }>;
    // The slot is already gone: nothing left to kill, and no respawn.
    expect(kill.ok && kill.data!.killed).toBe(false);
  });

  test("stop_all stops ephemeral rooms too (and the registry is still untouched)", async () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-sv-eph-all-"));
    const roomId = roomIdFor(tmp, "proj");
    await ask({ op: "spawn", cwd: tmp, name: "proj" });
    const stopAll = await ask({ op: "stop_all" });
    expect(stopAll.ok).toBe(true);
    await sleep(50);
    const kill = await ask({ op: "kill", room_id: roomId }) as ControlReply<{ killed: boolean }>;
    expect(kill.ok && kill.data!.killed).toBe(false);
    expect(existsSync(registryPath())).toBe(false);
  });

  test("spawn of a missing directory is a clean error", async () => {
    const r = await ask({ op: "spawn", cwd: join(tmpdir(), "no-such-dir-xyz") });
    expect(r).toMatchObject({ ok: false });
  });
});
