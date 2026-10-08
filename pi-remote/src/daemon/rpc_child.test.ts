import { afterEach, describe, expect, test } from "vitest";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RpcChild, busyTransition, resolvePiBin, resolvePiSpawn, _npmShimTarget, rpcSpawnArgs, type RpcChildExitEvent } from "./rpc_child.js";

/**
 * Regression for the orphaned-daemon bug: a deliberate `stop()` kills the
 * child by signal (SIGTERM/SIGKILL), which used to look like a crash and trip
 * the supervisor's auto-restart — re-spawning a daemon the operator just
 * stopped/removed. `stop()` must report a clean exit instead.
 *
 * We use a tiny executable that ignores the `--mode rpc -e <path>` args and
 * just sleeps, so the child is genuinely alive when we stop it.
 */
describe("rpcSpawnArgs", () => {
  test("includes --continue so a restart resumes the latest session (not a new one)", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js")).toEqual([
      "--mode", "rpc", "--approve", "--continue", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("pins the session display name via --name when one is given", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC")).toEqual([
      "--mode", "rpc", "--approve", "--continue", "--name", "PC", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("can omit --continue for one daemon fresh-session restart", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC", false)).toEqual([
      "--mode", "rpc", "--approve", "--name", "PC", "-e", "/path/to/dist/index.js",
    ]);
  });

  test("always passes --approve (pi >=0.79 project trust; RPC is non-interactive)", () => {
    expect(rpcSpawnArgs("/path/to/dist/index.js")).toContain("--approve");
    expect(rpcSpawnArgs("/path/to/dist/index.js", "PC", false)).toContain("--approve");
  });
});

describe("RpcChild — deliberate stop is not a crash", () => {
  let dir: string;

  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  // POSIX-only: uses a `.sh` stub + SIGTERM/SIGKILL semantics. The RpcChild
  // stop() logic is cross-platform; only this stub/signal harness is POSIX.
  test.skipIf(process.platform === "win32")("stop() emits isCrash:false though the child dies by signal", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-rpcchild-"));
    const bin = join(dir, "staysalive.sh");
    writeFileSync(bin, "#!/bin/sh\nexec sleep 30\n");
    chmodSync(bin, 0o755);

    const child = new RpcChild({ piBin: bin, extensionPath: "/no/such.js", cwd: dir });
    const exited = new Promise<RpcChildExitEvent>((resolve) => child.once("exit", resolve));
    child.spawn();
    // Let the process actually exec before we signal it.
    await new Promise((r) => setTimeout(r, 50));
    await child.stop();

    const evt = await exited;
    expect(evt.isCrash).toBe(false);   // ← was `true` before the fix → spurious restart
    expect(child.state).toBe("stopped");
  });
});

describe("resolvePiBin (plan/40 — Windows pi.cmd)", () => {
  test("POSIX → returns the bin name unchanged", () => {
    expect(resolvePiBin("pi", "darwin")).toBe("pi");
    expect(resolvePiBin("pi", "linux")).toBe("pi");
    expect(resolvePiBin("/opt/homebrew/bin/pi", "darwin")).toBe("/opt/homebrew/bin/pi");
  });
  test("Windows → an explicit path or suffixed name is used as-is (no lookup)", () => {
    expect(resolvePiBin("C:\\tools\\pi.cmd", "win32")).toBe("C:\\tools\\pi.cmd");
    expect(resolvePiBin("pi.cmd", "win32")).toBe("pi.cmd");
    expect(resolvePiBin("C:/tools/pi", "win32")).toBe("C:/tools/pi");
  });
  // The bare-`pi`-on-win32 lookup uses `where` (Windows-only); not unit-tested
  // here (no `where` on the POSIX dev host) — covered by the real Windows smoke.
});

describe("_npmShimTarget (plan/40 — parse the .cmd shim)", () => {
  let tmp: string;
  afterEach(() => { if (tmp) rmSync(tmp, { recursive: true, force: true }); });

  test("recovers the cli.js the npm shim launches (relative to the shim dir)", () => {
    tmp = mkdtempSync(join(tmpdir(), "pi-shim-"));
    // Mimic the npm-generated shim layout: <dir>\pi.cmd + <dir>\node_modules\…\cli.js
    const rel = join("node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
    const target = join(tmp, rel);
    require("node:fs").mkdirSync(join(target, ".."), { recursive: true });
    writeFileSync(target, "// cli\n");
    const shim = join(tmp, "pi.cmd");
    // The relevant line of a real npm cmd shim (forward-slash dp0 segment varies;
    // the launcher always quotes "%dp0%\<relative>").
    writeFileSync(shim, `@ECHO off\r\n"%_prog%"  "%dp0%\\${rel}" %*\r\n`);
    expect(_npmShimTarget(shim)).toBe(target);
  });

  test("returns null when the shim doesn't match / target missing", () => {
    tmp = mkdtempSync(join(tmpdir(), "pi-shim-"));
    const shim = join(tmp, "weird.cmd");
    writeFileSync(shim, "@echo off\r\necho nope\r\n");
    expect(_npmShimTarget(shim)).toBeNull();
    // points at a non-existent target → null (don't hand spawn a bad path)
    const shim2 = join(tmp, "pi.cmd");
    writeFileSync(shim2, `"%_prog%" "%dp0%\\does-not-exist.js" %*\r\n`);
    expect(_npmShimTarget(shim2)).toBeNull();
  });
});

describe("resolvePiSpawn (plan/40 — directly-spawnable target)", () => {
  test("POSIX → command is pi, no prefix args", () => {
    expect(resolvePiSpawn("pi", "linux")).toEqual({ command: "pi", prefixArgs: [] });
    expect(resolvePiSpawn("/usr/bin/pi", "darwin")).toEqual({ command: "/usr/bin/pi", prefixArgs: [] });
  });

  test("Windows .cmd shim → spawn node + parsed cli.js (no cmd.exe layer)", () => {
    const tmp = mkdtempSync(join(tmpdir(), "pi-spawn-"));
    try {
      const rel = join("node_modules", "@earendil-works", "pi-coding-agent", "dist", "cli.js");
      const target = join(tmp, rel);
      require("node:fs").mkdirSync(join(target, ".."), { recursive: true });
      writeFileSync(target, "// cli\n");
      const shim = join(tmp, "pi.cmd");
      writeFileSync(shim, `"%_prog%" "%dp0%\\${rel}" %*\r\n`);
      const r = resolvePiSpawn(shim, "win32", "C:\\node\\node.exe");
      expect(r.command).toBe("C:\\node\\node.exe");
      expect(r.prefixArgs).toEqual([target]);
    } finally {
      rmSync(tmp, { recursive: true, force: true });
    }
  });

  test("Windows explicit .exe → used as-is, no prefix args", () => {
    expect(resolvePiSpawn("C:\\tools\\pi.exe", "win32")).toEqual({
      command: "C:\\tools\\pi.exe",
      prefixArgs: [],
    });
  });
});

describe("busyTransition (stream markers)", () => {
  test("message_start → true, message_end → false", () => {
    expect(busyTransition('{"type":"message_start"}')).toBe(true);
    expect(busyTransition('{"type":"message_end"}')).toBe(false);
  });
  test("other events + garbage → null (no change)", () => {
    expect(busyTransition('{"type":"session_info_changed"}')).toBeNull();
    expect(busyTransition('{"type":"response","command":"prompt"}')).toBeNull();
    expect(busyTransition("not json")).toBeNull();
  });
});

describe("RpcChild — isBusy", () => {
  let dir: string;
  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  test("passive flag opens/closes on stream markers", () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-"));
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: dir });
    expect(child.isBusy).toBe(false);
    child._ingestStdoutForTest('{"type":"message_start"}');
    expect(child.isBusy).toBe(true);
    child._ingestStdoutForTest('{"type":"message_end"}');
    expect(child.isBusy).toBe(false);
  });

  // POSIX-only harness: the stub is a `#!/usr/bin/env node` shebang script,
  // which Windows can't spawn directly. refreshBusy itself is cross-platform;
  // the get_state correlation logic is also covered by the unit pieces above.
  test.skipIf(process.platform === "win32")("refreshBusy syncs from get_state.isStreaming (authoritative)", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-gs-"));
    // Stub that answers get_state with isStreaming:true (ignores rpc args).
    const stub = join(dir, "stub.mjs");
    writeFileSync(
      stub,
      "#!/usr/bin/env node\n" +
      "process.stdin.setEncoding('utf8');let b='';" +
      "process.stdin.on('data',c=>{b+=c;let n;while((n=b.indexOf('\\n'))>=0){const l=b.slice(0,n);b=b.slice(n+1);" +
      "try{const m=JSON.parse(l);if(m.type==='get_state')process.stdout.write(JSON.stringify({type:'response',command:'get_state',id:m.id,success:true,data:{isStreaming:true}})+'\\n');}catch{}}});" +
      "setInterval(()=>{},1e9);\n",
    );
    chmodSync(stub, 0o755);

    const child = new RpcChild({ piBin: stub, extensionPath: "/x", cwd: dir });
    child.spawn();
    await new Promise((r) => setTimeout(r, 80)); // let it exec
    const busy = await child.refreshBusy(1500);
    expect(busy).toBe(true);
    expect(child.isBusy).toBe(true);
    await child.stop();
  });

  test("refreshBusy returns the passive flag when the child isn't running", async () => {
    dir = mkdtempSync(join(tmpdir(), "pi-busy-off-"));
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: dir });
    // never spawned → not running → returns passive _busy (false)
    expect(await child.refreshBusy(200)).toBe(false);
  });
});

/**
 * Generic RPC passthrough (the phone command channel's transport). The stub
 * answers only `set_session_name` so the id-correlation path can be tested
 * against a real stdin/stdout round-trip, and the timeout path against a verb
 * the stub deliberately ignores.
 */
describe("RpcChild — sendCommand / awaitCommand", () => {
  let dir: string;
  afterEach(() => {
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort */ }
  });

  const stubSource =
    "#!/usr/bin/env node\n" +
    "process.stdin.setEncoding('utf8');let b='';" +
    "process.stdin.on('data',c=>{b+=c;let n;while((n=b.indexOf('\\n'))>=0){const l=b.slice(0,n);b=b.slice(n+1);" +
    "try{const m=JSON.parse(l);if(m.type==='set_session_name')" +
    "process.stdout.write(JSON.stringify({type:'response',command:'set_session_name',id:m.id,success:true,data:{name:m.name}})+'\\n');}catch{}}});" +
    "setInterval(()=>{},1e9);\n";

  function spawnStub(): RpcChild {
    dir = mkdtempSync(join(tmpdir(), "pi-rpc-cmd-"));
    const stub = join(dir, "stub.mjs");
    writeFileSync(stub, stubSource);
    chmodSync(stub, 0o755);
    const child = new RpcChild({ piBin: stub, extensionPath: "/x", cwd: dir });
    child.spawn();
    return child;
  }

  test("parse: nonsense and events are not responses", async () => {
    const { parseResponseLine } = await import("./rpc_child.js");
    expect(parseResponseLine("not json")).toBeNull();
    expect(parseResponseLine('{"type":"message_start"}')).toBeNull();
    expect(parseResponseLine('{"type":"response","command":"prompt","id":"s1","success":true}'))
      .toEqual({ id: "s1", response: { command: "prompt", success: true } });
    expect(parseResponseLine('{"type":"response","id":"s2","success":false,"error":"nope"}'))
      .toEqual({ id: "s2", response: { success: false, error: "nope" } });
  });

  test("sendCommand is fire-and-forget and reports a dead child", () => {
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: mkdtempSync(join(tmpdir(), "pi-rpc-dead-")) });
    expect(child.sendCommand({ type: "prompt", message: "hi" })).toBe(false);
  });

  // POSIX-only: the stub is a shebang script, which Windows can't spawn directly.
  test.skipIf(process.platform === "win32")("awaitCommand resolves with the matching response", async () => {
    const child = spawnStub();
    await new Promise((r) => setTimeout(r, 80)); // let it exec
    const res = await child.awaitCommand({ type: "set_session_name", name: "nightly" }, 1500);
    expect(res).toMatchObject({ command: "set_session_name", success: true });
    await child.stop();
  });

  test.skipIf(process.platform === "win32")("awaitCommand resolves null when the child never answers", async () => {
    const child = spawnStub();
    await new Promise((r) => setTimeout(r, 80));
    // The stub ignores `compact`, so the caller gets "delivered, unknown
    // outcome" instead of hanging the supervisor's request.
    expect(await child.awaitCommand({ type: "compact" }, 120)).toBeNull();
    await child.stop();
  });

  test.skipIf(process.platform === "win32")("awaitCommand resolves null when the child isn't running", async () => {
    const child = new RpcChild({ piBin: "/usr/bin/true", extensionPath: "/x", cwd: mkdtempSync(join(tmpdir(), "pi-rpc-null-")) });
    expect(await child.awaitCommand({ type: "compact" }, 50)).toBeNull();
  });
});
