import { describe, expect, test } from "vitest";
import {
  FIRST_MESSAGE_MAX_CHARS,
  extractTextContent,
  firstUserMessageForSession,
} from "./first_message.js";

type Entry = { type?: string; message?: { role?: string; content?: unknown } };

/**
 * Builds a fake `ctx.sessionManager` exposing either a branch-only view
 * (`branch: true`), an entries-only view (default), or both (pass both).
 */
function makeCtx(
  entries: Entry[],
  opts?: { branch?: Entry[]; entries?: Entry[] },
) {
  return {
    sessionManager: {
      ...(opts?.branch !== undefined ? { getBranch: () => (opts.branch as Entry[]) } : {}),
      ...(opts?.entries !== undefined ? { getEntries: () => (opts.entries as Entry[]) } : {}),
      ...(opts?.branch !== undefined
        ? {}
        : { getEntries: () => entries as unknown as Entry[] }),
    },
  };
}

describe("extractTextContent", () => {
  test("string content is used as-is", () => {
    expect(extractTextContent({ content: "hello world" })).toBe("hello world");
  });

  test("block array yields its text blocks joined with a single space", () => {
    const content = [
      { type: "text", text: "first" },
      { type: "text", text: "second" },
    ];
    expect(extractTextContent({ content })).toBe("first second");
  });

  test("non-text blocks are ignored (only text blocks count)", () => {
    const content = [
      { type: "tool_result", content: "ignored" },
      { type: "text", text: "kept" },
      { type: "image_file", content: "not text" },
    ];
    expect(extractTextContent({ content })).toBe("kept");
  });

  test("no usable content → null (empty arrays yield '' — caller skips blank)", () => {
    expect(extractTextContent(null)).toBeNull();
    expect(extractTextContent(undefined)).toBeNull();
    expect(extractTextContent({})).toBeNull();
    expect(extractTextContent({ content: 42 })).toBeNull();
    expect(extractTextContent({ content: [] })).toBe("");
  });
});

describe("firstUserMessageForSession", () => {
  test("unknown ctx → null (never throws)", () => {
    expect(firstUserMessageForSession({})).toBeNull();
    expect(firstUserMessageForSession(null)).toBeNull();
    expect(firstUserMessageForSession({ sessionManager: null })).toBeNull();
  });

  test("empty session / no user message → null", () => {
    expect(firstUserMessageForSession(makeCtx([]))).toBeNull();
    expect(
      firstUserMessageForSession(
        makeCtx([
          { type: "message", message: { role: "assistant", content: "assistant reply" } },
        ]),
      ),
    ).toBeNull();
  });

  test("returns the first USER message, not the first assistant one", () => {
    expect(
      firstUserMessageForSession(
        makeCtx([
          { type: "message", message: { role: "assistant", content: "greeting" } },
          { type: "message", message: { role: "user", content: "what should we build?" } },
          { type: "message", message: { role: "assistant", content: "great" } },
        ]),
      ),
    ).toBe("what should we build?");
  });

  test("block-array user content → text blocks joined (whitespace normalized)", () => {
    expect(
      firstUserMessageForSession(
        makeCtx([
          {
            type: "message",
            message: {
              role: "user",
              content: [{ type: "text", text: "hello" }, { type: "text", text: "world" }],
            },
          },
        ]),
      ),
    ).toBe("hello world");
  });

  test("whitespace is collapsed and trimmed", () => {
    expect(
      firstUserMessageForSession(
        makeCtx([
          { type: "message", message: { role: "user", content: "  lots   of   spaces  " } },
        ]),
      ),
    ).toBe("lots of spaces");
  });

  test("a blank user message is skipped (falls through to the next user message)", () => {
    expect(
      firstUserMessageForSession(
        makeCtx([
          { type: "message", message: { role: "user", content: "   " } },
          { type: "message", message: { role: "user", content: "real opening" } },
        ]),
      ),
    ).toBe("real opening");
  });

  test("truncates to FIRST_MESSAGE_MAX_CHARS (no ellipsis)", () => {
    const long = "a".repeat(200);
    const out = firstUserMessageForSession(
      makeCtx([{ type: "message", message: { role: "user", content: long } }]),
    );
    expect(out).not.toBeNull();
    expect(out!.length).toBe(FIRST_MESSAGE_MAX_CHARS);
    expect(out).toBe(long.slice(0, FIRST_MESSAGE_MAX_CHARS));
  });

  test("uses getEntries() when no getBranch() is available", () => {
    expect(
      firstUserMessageForSession(
        makeCtx([
          { type: "message", message: { role: "user", content: "via entries" } },
        ]),
      ),
    ).toBe("via entries");
  });

  test("prefers getBranch() over getEntries() when both are present", () => {
    const ctx = makeCtx([], {
      branch: [{ type: "message", message: { role: "user", content: "branch msg" } }],
      entries: [{ type: "message", message: { role: "user", content: "entries msg" } }],
    });
    expect(firstUserMessageForSession(ctx)).toBe("branch msg");
  });

  test("never throws on a malformed session manager", () => {
    const ctx = {
      sessionManager: {
        getBranch: () => {
          throw new Error("boom");
        },
      },
    };
    expect(firstUserMessageForSession(ctx as unknown)).toBeNull();
  });
});
