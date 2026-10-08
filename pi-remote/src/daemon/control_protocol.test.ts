import { describe, expect, test } from "vitest";
import {
  encodeReply,
  encodeRequest,
  parseReply,
  parseRequest,
  type ControlRequest,
} from "./control_protocol.js";

describe("control_protocol — request/reply framing", () => {
  test("encodeRequest produces a JSON line with trailing newline", () => {
    const out = encodeRequest({ op: "list" });
    expect(out.endsWith("\n")).toBe(true);
    expect(out.slice(0, -1)).toBe('{"op":"list"}');
  });

  test("parseRequest round-trips every op", () => {
    const ops: ControlRequest[] = [
      { op: "list" },
      { op: "status" },
      { op: "start_all" },
      { op: "stop_all" },
      { op: "restart_all" },
      { op: "send", id: "abc12345", text: "Refactor X" },
      { op: "register", cwd: "/Users/x/Movies" },
      { op: "unregister", id: "abc12345" },
    ];
    for (const req of ops) {
      const wire = encodeRequest(req);
      const parsed = parseRequest(wire.trim());
      expect(parsed).toEqual(req);
    }
  });

  test("parseRequest rejects malformed JSON", () => {
    expect(() => parseRequest("{not json")).toThrow(/malformed/i);
    expect(() => parseRequest("123")).toThrow(/object/i);
    expect(() => parseRequest("null")).toThrow(/object/i);
  });

  test("parseRequest rejects missing op", () => {
    expect(() => parseRequest('{"foo":"bar"}')).toThrow(/op/);
  });

  test("encodeReply / parseReply round-trip ok=true", () => {
    const wire = encodeReply({ ok: true, data: { daemons: [] } });
    const parsed = parseReply(wire.trim());
    expect(parsed).toEqual({ ok: true, data: { daemons: [] } });
  });

  test("encodeReply / parseReply round-trip ok=false", () => {
    const wire = encodeReply({ ok: false, error: "daemon not found" });
    expect(parseReply(wire.trim())).toEqual({ ok: false, error: "daemon not found" });
  });

  test("parseReply rejects missing ok field", () => {
    expect(() => parseReply('{"data":{}}')).toThrow(/ok/);
  });
});
