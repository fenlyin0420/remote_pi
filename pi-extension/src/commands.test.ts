/**
 * Phone command channel — `/slash` and `!shell`.
 *
 * Two layers are covered here:
 *   - the pure pieces (parsing, output formatting, the builtin table) directly;
 *   - the handlers through `_routeClientMessageFrom`, which is the same door a
 *     relay frame takes, so a missing `case` in the message switch fails these
 *     tests instead of only failing on a phone.
 */
import { describe, expect, test, vi, beforeEach, afterEach } from "vitest";
import type { ServerMessage } from "./protocol/types.js";

const h = vi.hoisted(() => ({
  callSupervisor: vi.fn(),
}));

vi.mock("./daemon/client.js", () => ({
  callSupervisor: h.callSupervisor,
  supervisorOnline: vi.fn(async () => true),
  SupervisorOfflineError: class SupervisorOfflineError extends Error {},
}));

const indexModule = await import("./index.js");
const {
  BUILTIN_COMMANDS,
  BASH_OUTPUT_MAX_CHARS,
  _splitSlashCommand,
  _formatBashResult,
  _sanitizeShellOutput,
  _commandsForSession,
  _routeClientMessageFrom,
  _setPiForTest,
  _setMessageBufferForTest,
  _getMessageBufferForTest,
} = indexModule;

// ── Harness ───────────────────────────────────────────────────────────────────

interface Sent {
  sent: ServerMessage[];
  send: (msg: ServerMessage) => void;
  last: () => ServerMessage;
}

function makeSender(): Sent {
  const sent: ServerMessage[] = [];
  return {
    sent,
    send: (msg: ServerMessage) => { sent.push(msg); },
    last: () => sent[sent.length - 1]!,
  };
}

/** Minimal ExtensionAPI surface the command handlers touch. */
function makePi(overrides: Record<string, unknown> = {}) {
  return {
    getCommands: () => [] as unknown[],
    setSessionName: vi.fn(),
    getSessionName: vi.fn(() => undefined),
    setThinkingLevel: vi.fn(),
    setModel: vi.fn(async () => true),
    sendMessage: vi.fn(),
    exec: vi.fn(async () => ({ stdout: "", stderr: "", code: 0, killed: false })),
    ...overrides,
  };
}

const CTX = { abort: () => undefined, compact: () => undefined };

/** Test ctx shaped like a real `ExtensionContext`: it always carries `compact`
 *  (the router's way of telling a live session ctx from its no-op placeholder). */
function makeCtx(extra: Record<string, unknown> = {}) {
  return { abort: () => undefined, compact: vi.fn(), ...extra };
}

function route(msg: unknown, sender: Sent, ctx: unknown = CTX): void {
  _routeClientMessageFrom(
    sender as never,
    msg as never,
    ctx as never,
  );
}

beforeEach(() => {
  h.callSupervisor.mockReset();
  h.callSupervisor.mockResolvedValue({ id: "daemon-1", delivered: true });
  _setMessageBufferForTest([]);
  delete process.env["REMOTE_PI_DAEMON"];
});

afterEach(() => {
  delete process.env["REMOTE_PI_DAEMON"];
});

// ── Pure helpers ──────────────────────────────────────────────────────────────

describe("_splitSlashCommand", () => {
  test("splits name and args", () => {
    expect(_splitSlashCommand("/compact keep the API notes")).toEqual({
      name: "compact",
      args: "keep the API notes",
    });
  });

  test("bare command has empty args", () => {
    expect(_splitSlashCommand("/new")).toEqual({ name: "new", args: "" });
  });

  test("extra whitespace around args is trimmed", () => {
    expect(_splitSlashCommand("/name   my session  ")).toEqual({
      name: "name",
      args: "my session",
    });
  });

  test("keeps the `skill:` prefix as part of the name", () => {
    expect(_splitSlashCommand("/skill:review the diff")).toEqual({
      name: "skill:review",
      args: "the diff",
    });
  });

  test("rejects non-commands and a lone slash", () => {
    expect(_splitSlashCommand("hello")).toBeNull();
    expect(_splitSlashCommand("/")).toBeNull();
    expect(_splitSlashCommand("//")).toBeNull();
    expect(_splitSlashCommand("")).toBeNull();
  });
});

describe("_formatBashResult", () => {
  test("plain output carries no trailer", () => {
    expect(_formatBashResult("main\n", "", 0, false)).toBe("main");
  });

  test("non-zero exit is visible", () => {
    expect(_formatBashResult("boom", "", 2, false)).toBe("boom\n[exit 2]");
  });

  test("a killed process says so instead of a code", () => {
    expect(_formatBashResult("partial", "", 143, true)).toBe("partial\n[killed]");
  });

  test("silence is states as such, not an empty card", () => {
    expect(_formatBashResult("", "", 0, false)).toBe("(no output)");
  });

  test("stderr is merged like Pi's own bash output", () => {
    expect(_formatBashResult("out", "err", 0, false)).toBe("out\nerr");
  });

  test("output is capped", () => {
    const huge = "x".repeat(BASH_OUTPUT_MAX_CHARS * 2);
    const formatted = _formatBashResult(huge, "", 0, false);
    expect(formatted.length).toBeLessThan(BASH_OUTPUT_MAX_CHARS + 64);
    expect(formatted.endsWith("[output truncated]")).toBe(true);
  });
});

describe("_sanitizeShellOutput", () => {
  test("drops control characters but keeps newlines and tabs", () => {
    expect(_sanitizeShellOutput("a\u0007b\u001B[0mc\nd\te")).toBe("ab[0mc\nd\te");
  });
});

describe("BUILTIN_COMMANDS", () => {
  test("names are unique", () => {
    const names = BUILTIN_COMMANDS.map((c) => c.name);
    expect(new Set(names).size).toBe(names.length);
  });

  test("covers the SDK's 22 builtins plus remote-pi's own /thinking", () => {
    expect(BUILTIN_COMMANDS).toHaveLength(23);
    const names = BUILTIN_COMMANDS.map((c) => c.name);
    for (const builtin of [
      "settings", "model", "scoped-models", "export", "import", "share", "copy",
      "name", "session", "changelog", "hotkeys", "fork", "clone", "tree",
      "trust", "login", "logout", "new", "compact", "resume", "reload", "quit",
    ]) {
      expect(names).toContain(builtin);
    }
    expect(names).toContain("thinking");
  });

  test("the phone-runnable set is exactly the five typed-action names", () => {
    const runnable = BUILTIN_COMMANDS.filter((c) => c.scope === "all").map((c) => c.name);
    expect(runnable.sort()).toEqual(["compact", "model", "name", "new", "thinking"]);
  });

  test("every entry is described (the palette subtitle)", () => {
    for (const command of BUILTIN_COMMANDS) {
      expect(command.description.length).toBeGreaterThan(0);
    }
  });
});

// ── list_commands ─────────────────────────────────────────────────────────────

describe("list_commands", () => {
  test("answers with the builtins even with no Pi bound", () => {
    _setPiForTest(null);
    const sender = makeSender();
    route({ type: "list_commands", id: "l1" }, sender);
    const reply = sender.sent[0] as Extract<ServerMessage, { type: "commands_list" }>;
    expect(reply.type).toBe("commands_list");
    expect(reply.in_reply_to).toBe("l1");
    expect(reply.commands).toHaveLength(23);
    expect(reply.commands.find((c) => c.name === "compact")).toMatchObject({
      source: "builtin",
      scope: "all",
      supported: true,
    });
    expect(reply.commands.find((c) => c.name === "login")).toMatchObject({
      scope: "tui",
      supported: false,
    });
  });

  test("merges the session's extension/skill/template commands, marked daemon-only", () => {
    _setPiForTest(makePi({
      getCommands: () => [
        { name: "deploy", description: "Ship it", source: "extension" },
        { name: "review", description: "Review", source: "prompt" },
        { name: "skill:explain", description: "Explain", source: "skill" },
      ],
    }));
    const commands = _commandsForSession(false);
    const byName = new Map(commands.map((c) => [c.name, c]));
    expect(byName.get("deploy")).toMatchObject({ source: "extension", scope: "daemon", supported: false });
    expect(byName.get("review")).toMatchObject({ source: "prompt", scope: "daemon" });
    expect(byName.get("skill:explain")).toMatchObject({ source: "skill", scope: "daemon" });
    // Supported flips with the room type, not with the command.
    const inDaemon = _commandsForSession(true);
    expect(inDaemon.find((c) => c.name === "deploy")?.supported).toBe(true);
  });
});

// ── command_invoke: builtins remote-pi implements ─────────────────────────────

describe("command_invoke — implemented builtins", () => {
  test('/name sets the session name', async () => {
    const pi = makePi();
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "command_invoke", id: "c1", text: "/name nightly build" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(pi.setSessionName).toHaveBeenCalledWith("nightly build");
    expect(sender.last()).toMatchObject({ type: "action_ok", action: "command_invoke" });
  });

  test('/name without an argument explains the usage', async () => {
    _setPiForTest(makePi());
    const sender = makeSender();
    route({ type: "command_invoke", id: "c2", text: "/name" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      action: "command_invoke",
      error: "usage: /name <session name>",
    });
  });

  test('/thinking maps onto setThinkingLevel', async () => {
    const pi = makePi();
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "command_invoke", id: "c3", text: "/thinking xhigh" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(pi.setThinkingLevel).toHaveBeenCalledWith("xhigh");
  });

  test('/thinking rejects a level outside the fixed enum', async () => {
    _setPiForTest(makePi());
    const sender = makeSender();
    route({ type: "command_invoke", id: "c4", text: "/thinking max" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_error", action: "command_invoke" });
    expect((sender.last() as { error: string }).error).toContain("usage: /thinking");
  });

  test('/compact passes the instructions plus the English-summary rule', async () => {
    _setPiForTest(makePi());
    const compact = vi.fn();
    const sender = makeSender();
    route(
      { type: "command_invoke", id: "c5", text: "/compact keep the migration notes" },
      sender,
      makeCtx({ compact }),
    );
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(compact).toHaveBeenCalledTimes(1);
    const arg = compact.mock.calls[0]![0] as { customInstructions: string };
    expect(arg.customInstructions).toContain("keep the migration notes");
    expect(arg.customInstructions).toContain("English");
  });

  test('/model resolves "provider/id" through the live registry and persists the pick', async () => {
    const model = { id: "claude-opus-4-7", name: "Opus", provider: "anthropic", reasoning: true, contextWindow: 1 };
    const registry = {
      refresh: vi.fn(),
      getAvailable: () => [model],
      find: vi.fn((provider: string, id: string) =>
        provider === "anthropic" && id === "claude-opus-4-7" ? model : undefined),
    };
    const pi = makePi();
    _setPiForTest(pi);
    const sender = makeSender();
    route(
      { type: "command_invoke", id: "c6", text: "/model anthropic/claude-opus-4-7" },
      sender,
      makeCtx({ modelRegistry: registry }),
    );
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(registry.find).toHaveBeenCalledWith("anthropic", "claude-opus-4-7");
    expect(pi.setModel).toHaveBeenCalledWith(model);
    expect(sender.last()).toMatchObject({ type: "action_ok", action: "command_invoke" });
  });

  test('/model with an unknown reference fails instead of silently keeping the old one', async () => {
    const registry = { refresh: vi.fn(), getAvailable: () => [], find: () => undefined };
    _setPiForTest(makePi());
    const sender = makeSender();
    route(
      { type: "command_invoke", id: "c7", text: "/model nope/nope" },
      sender,
      makeCtx({ modelRegistry: registry }),
    );
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect((sender.last() as { error: string }).error).toContain("unknown model");
  });

  test('/model with no argument points at the picker', async () => {
    _setPiForTest(makePi());
    const sender = makeSender();
    route({ type: "command_invoke", id: "c8", text: "/model" }, sender, makeCtx({
      modelRegistry: { refresh: vi.fn(), getAvailable: () => [], find: () => undefined },
    }));
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect((sender.last() as { error: string }).error).toContain("usage: /model");
  });
});

// ── command_invoke: everything else ───────────────────────────────────────────

describe("command_invoke — classification", () => {
  test("a TUI-only builtin is refused by name", async () => {
    _setPiForTest(makePi());
    const sender = makeSender();
    route({ type: "command_invoke", id: "d1", text: "/settings" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      action: "command_invoke",
      error: "/settings is only available in the Pi TUI, not from the app",
    });
  });

  test("an unknown name never reaches the model", async () => {
    _setPiForTest(makePi());
    const sender = makeSender();
    route({ type: "command_invoke", id: "d2", text: "/nope please" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      error: "unknown command: /nope",
    });
  });

  test("an extension command in a TUI room explains why it can't run", async () => {
    _setPiForTest(makePi({ getCommands: () => [{ name: "deploy", source: "extension" }] }));
    const sender = makeSender();
    route({ type: "command_invoke", id: "d3", text: "/deploy prod" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_error", action: "command_invoke" });
    expect((sender.last() as { error: string }).error).toContain("supervised daemon");
    expect(h.callSupervisor).not.toHaveBeenCalled();
  });

  test("an extension command in a daemon room goes over the RPC channel verbatim", async () => {
    process.env["REMOTE_PI_DAEMON"] = "1";
    h.callSupervisor.mockResolvedValue({
      id: "daemon-1",
      delivered: true,
      response: { command: "prompt", success: true },
    });
    _setPiForTest(makePi({ getCommands: () => [{ name: "deploy", source: "extension" }] }));
    const sender = makeSender();
    route({ type: "command_invoke", id: "d4", text: "/deploy prod" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_ok", action: "command_invoke" });
    expect(h.callSupervisor).toHaveBeenCalledWith({
      op: "rpc",
      id: expect.any(String),
      command: { type: "prompt", message: "/deploy prod", streamingBehavior: "steer" },
    });
  });

  test("a skill command travels as text (the Pi expands it)", async () => {
    process.env["REMOTE_PI_DAEMON"] = "1";
    h.callSupervisor.mockResolvedValue({
      id: "daemon-1",
      delivered: true,
      response: { command: "prompt", success: true },
    });
    _setPiForTest(makePi({ getCommands: () => [{ name: "skill:explain", source: "skill" }] }));
    const sender = makeSender();
    route({ type: "command_invoke", id: "d5", text: "/skill:explain the parser" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(h.callSupervisor).toHaveBeenCalledWith(expect.objectContaining({
      op: "rpc",
      command: { type: "prompt", message: "/skill:explain the parser", streamingBehavior: "steer" },
    }));
  });

  test("the child's own rejection text is surfaced, not swallowed", async () => {
    process.env["REMOTE_PI_DAEMON"] = "1";
    h.callSupervisor.mockResolvedValue({
      id: "daemon-1",
      delivered: true,
      response: { command: "prompt", success: false, error: "No model selected" },
    });
    _setPiForTest(makePi({ getCommands: () => [{ name: "deploy", source: "extension" }] }));
    const sender = makeSender();
    route({ type: "command_invoke", id: "d6", text: "/deploy" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      error: "No model selected",
    });
  });

  test("a daemon that vanished reports the supervisor error", async () => {
    process.env["REMOTE_PI_DAEMON"] = "1";
    h.callSupervisor.mockRejectedValue(new Error("daemon abc not running"));
    _setPiForTest(makePi({ getCommands: () => [{ name: "deploy", source: "extension" }] }));
    const sender = makeSender();
    route({ type: "command_invoke", id: "d7", text: "/deploy" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      error: "daemon abc not running",
    });
  });
});

// ── bash_exec ────────────────────────────────────────────────────────────────

describe("bash_exec", () => {
  test("runs through the Pi's shell and answers with the card's output", async () => {
    const pi = makePi({
      exec: vi.fn(async () => ({ stdout: "on branch main\n", stderr: "", code: 0, killed: false })),
    });
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b1", command: "git status -sb" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_ok", action: "bash_exec" });
    // Shell invocation: `bash -c <command>`, never an argv split of the string.
    expect(pi.exec).toHaveBeenCalledWith(
      expect.any(String),
      [expect.any(String), "git status -sb"],
      expect.objectContaining({ cwd: expect.any(String) }),
    );
    // The exec output reaches the model the way a TUI `!` does.
    expect(pi.sendMessage).toHaveBeenCalledWith(
      expect.objectContaining({ customType: "bash-exec", display: false }),
      { triggerTurn: false },
    );
    // The transcript pair survives a re-sync: request (toolCall block) + result.
    const buffer = _getMessageBufferForTest() as Array<Record<string, unknown>>;
    expect(buffer).toHaveLength(2);
    expect(buffer[0]).toMatchObject({ role: "assistant" });
    expect(buffer[1]).toMatchObject({ role: "toolResult", toolName: "bash", isError: false });
  });

  test("!! (exclude_from_context) keeps the output out of the agent's context", async () => {
    const pi = makePi();
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b2", command: "pwd", exclude_from_context: true }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(pi.sendMessage).not.toHaveBeenCalled();
  });

  test("a non-zero exit still returns the output it produced", async () => {
    const pi = makePi({
      exec: vi.fn(async () => ({ stdout: "", stderr: "no such file", code: 1, killed: false })),
    });
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b3", command: "cat nope" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_ok", action: "bash_exec" });
    const buffer = _getMessageBufferForTest() as Array<Record<string, unknown>>;
    expect(buffer[1]).toMatchObject({ content: "no such file\n[exit 1]", isError: false });
  });

  test("a killed command is reported as a failed card", async () => {
    const pi = makePi({
      exec: vi.fn(async () => ({ stdout: "partial", stderr: "", code: 143, killed: true })),
    });
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b4", command: "sleep 999", timeout_ms: 1000 }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    const buffer = _getMessageBufferForTest() as Array<Record<string, unknown>>;
    expect(buffer[1]).toMatchObject({ isError: true, content: "partial\n[killed]" });
    expect(pi.exec).toHaveBeenCalledWith(
      expect.any(String),
      expect.any(Array),
      expect.objectContaining({ timeout: 1000 }),
    );
  });

  test("an empty command is refused before spawning anything", async () => {
    const pi = makePi();
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b5", command: "   " }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_error", error: "command is required" });
    expect(pi.exec).not.toHaveBeenCalled();
  });

  test("a failed spawn reports both the card and the action error", async () => {
    const pi = makePi({ exec: vi.fn(async () => { throw new Error("bash not found"); }) });
    _setPiForTest(pi);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b6", command: "ls" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({ type: "action_error", error: "bash not found" });
  });

  test("a room with no Pi bound says so instead of timing out", async () => {
    _setPiForTest(null);
    const sender = makeSender();
    route({ type: "bash_exec", id: "b7", command: "ls" }, sender);
    await vi.waitFor(() => expect(sender.sent).toHaveLength(1));
    expect(sender.last()).toMatchObject({
      type: "action_error",
      error: "no Pi session bound yet",
    });
  });
});
