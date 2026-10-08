/**
 * `send_to_phone` — the Pi → App file hand-off.
 *
 * The invariants worth pinning here: what counts as an image / as text is
 * decided by the BYTES (never the name, same rule as the app's upload), the
 * 2 MiB cap is enforced by downscaling images rather than refusing them, and
 * every refusal comes back typed so the tool can tell the model what happened.
 */
import { describe, expect, test, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, readFileSync, readdirSync, rmSync, utimesSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage } from "../protocol/types.js";

const _resizeImageMock = vi.hoisted(() => vi.fn(async () => null as unknown));

vi.mock("@earendil-works/pi-coding-agent", async (importOriginal) => {
  const orig = await importOriginal<typeof import("@earendil-works/pi-coding-agent")>();
  return { ...orig, resizeImage: _resizeImageMock };
});

const {
  ATTACHMENT_MAX_BYTES,
  ATTACHMENT_TEXT_MAX_BYTES,
  _decodeTextStrict,
  _encodeAttachment,
  _encodeInlineImage,
  _imageBlocksFromToolResult,
  _pruneInlineImageStore,
  _setInlineImageDirForTest,
  _sniffImageMime,
  handleFileGetRequest,
  registerSendToPhoneTool,
} = await import("./attachment.js");

// Minimal valid-ish headers — the sniffer only looks at magic bytes.
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
const JPEG_MAGIC = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);

/** A real 2×2 PNG (valid CRC and all), so the sniffer and any decode agree. */
const PNG_2X2 = Buffer.from(
  "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR4nGP4z8DAwPAfjP//ZwAAIO4E/H1h0SQAAAAASUVORK5CYII=",
  "base64",
);

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "rp-attach-"));
  _resizeImageMock.mockReset();
  _resizeImageMock.mockResolvedValue(null);
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function write(name: string, bytes: Buffer | string): string {
  const path = join(dir, name);
  writeFileSync(path, bytes);
  return path;
}

/** A `resizeImage` stand-in that reports success with a fixed payload. */
function _mockResize(payload: { data: string; mimeType: string; wasResized?: boolean }): void {
  _resizeImageMock.mockResolvedValue({
    originalWidth: 4000,
    originalHeight: 3000,
    width: 1600,
    height: 1200,
    wasResized: true,
    ...payload,
  });
}

describe("content sniffing", () => {
  test("image magic wins over the file name", () => {
    expect(_sniffImageMime(Buffer.concat([PNG_MAGIC, Buffer.alloc(16)]))).toBe("image/png");
    expect(_sniffImageMime(Buffer.concat([JPEG_MAGIC, Buffer.alloc(16)]))).toBe("image/jpeg");
    expect(_sniffImageMime(Buffer.from("GIF89a...."))).toBe("image/gif");
    expect(_sniffImageMime(Buffer.concat([Buffer.from("RIFF"), Buffer.alloc(4), Buffer.from("WEBPVP8 ")]))).toBe("image/webp");
    expect(_sniffImageMime(Buffer.from("%PDF-1.7\n"))).toBeNull();
    expect(_sniffImageMime(Buffer.from("# notes\n"))).toBeNull();
  });

  test("text decoding follows the upload rules: BOM, no NUL, strict utf-8", () => {
    expect(_decodeTextStrict(Buffer.from("hello"))).toBe("hello");
    expect(_decodeTextStrict(Buffer.from([0xef, 0xbb, 0xbf, 0x68, 0x69]))).toBe("hi");
    expect(_decodeTextStrict(Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from("hi", "utf16le")]))).toBe("hi");
    expect(_decodeTextStrict(Buffer.from([0x61, 0x00, 0x62]))).toBeNull();          // NUL
    expect(_decodeTextStrict(Buffer.from([0xff, 0xfe, 0x00, 0xd8]))).toBeNull();   // lone surrogate
    expect(_decodeTextStrict(Buffer.from([0xff, 0xfe, 0x68]))).toBeNull();         // truncated code unit
    expect(_decodeTextStrict(Buffer.from([0xc3, 0x28]))).toBeNull();                // broken utf-8
  });
});

describe("_encodeAttachment", () => {
  test("a small image travels untouched — no re-encode, no loss", async () => {
    const path = write("shot.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(200)]));
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.meta.mime).toBe("image/png");
    expect(res.meta.size).toBe(208);
    expect(res.meta.resized).toBeUndefined();
    expect(_resizeImageMock).not.toHaveBeenCalled();
    expect(Buffer.from(res.data, "base64").length).toBe(208);
  });

  test("a .txt that is really a PNG is sent as an image", async () => {
    const path = write("lies.txt", Buffer.concat([PNG_MAGIC, Buffer.alloc(64)]));
    const res = await _encodeAttachment(path);
    expect(res.ok && res.meta.mime).toBe("image/png");
  });

  test("an over-cap image is downscaled and reports both sizes", async () => {
    const path = write("huge.jpg", Buffer.concat([JPEG_MAGIC, Buffer.alloc(ATTACHMENT_MAX_BYTES)]));
    _mockResize({ data: Buffer.alloc(1024, 7).toString("base64"), mimeType: "image/jpeg" });
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.meta.resized).toBe(true);
    expect(res.meta.original_size).toBe(ATTACHMENT_MAX_BYTES + JPEG_MAGIC.length);
    expect(res.meta.mime).toBe("image/jpeg");
    expect(_resizeImageMock).toHaveBeenCalledWith(
      expect.anything(),
      "image/jpeg",
      expect.objectContaining({ maxBytes: ATTACHMENT_MAX_BYTES }),
    );
  });

  test("an image that will not fit is refused with a reason, not truncated", async () => {
    const path = write("huge.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(ATTACHMENT_MAX_BYTES)]));
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.code).toBe("too_large");
    expect(res.message).toContain("huge.png");
  });

  test("text travels as base64 with a mime from the name", async () => {
    const path = write("notes.md", "# olá\nmundo\n");
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.meta.mime).toBe("text/markdown");
    expect(res.meta.name).toBe("notes.md");
    expect(Buffer.from(res.data, "base64").toString("utf8")).toBe("# olá\nmundo\n");
  });

  test("binary content is refused whatever the extension says", async () => {
    const path = write("app.zip", Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00, 0x01, 0x02]));
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(false);
    if (res.ok) return;
    expect(res.code).toBe("unsupported");
    expect(res.message).toContain("binary");
  });

  test("text over its own (smaller) ceiling is refused, images are not", async () => {
    const path = write("big.txt", "a".repeat(ATTACHMENT_TEXT_MAX_BYTES + 1));
    const res = await _encodeAttachment(path);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.code).toBe("unsupported");
  });

  test("missing, empty and directory paths fail distinctly", async () => {
    const missing = await _encodeAttachment(join(dir, "nope.png"));
    expect(missing.ok === false && missing.code).toBe("not_found");

    const empty = await _encodeAttachment(write("empty.txt", ""));
    expect(empty.ok === false && empty.code).toBe("unsupported");

    const sub = join(dir, "sub");
    mkdirSync(sub);
    const dirRes = await _encodeAttachment(sub);
    expect(dirRes.ok === false && dirRes.code).toBe("not_found");
  });

  test("a symlink is reported by its real path", async () => {
    const { symlinkSync } = await import("node:fs");
    const target = write("real.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(32)]));
    const link = join(dir, "link.png");
    symlinkSync(target, link);
    const res = await _encodeAttachment(link);
    expect(res.ok && res.meta.path).toBe(target);
  });
});

describe("images a tool returned inline", () => {
  let store: string;

  beforeEach(() => {
    store = join(dir, "attachments");
    _setInlineImageDirForTest(store);
  });

  afterEach(() => {
    _setInlineImageDirForTest(undefined);
  });

  test("finds the image blocks of both result shapes", () => {
    const block = { type: "image", data: PNG_2X2.toString("base64"), mimeType: "image/png" };
    // Live: the `{ content, details }` wrapper.
    expect(_imageBlocksFromToolResult({
      content: [{ type: "text", text: "Virtual desktop screenshot." }, block],
      details: { display: ":99" },
    })).toEqual([{ data: block.data, mimeType: "image/png" }]);
    // Re-sync: the bare content-array.
    expect(_imageBlocksFromToolResult([block])).toHaveLength(1);
    // Anything else: no blocks, no cards.
    expect(_imageBlocksFromToolResult({ content: [{ type: "text", text: "plain" }] })).toEqual([]);
    expect(_imageBlocksFromToolResult([{ type: "image", mimeType: "image/png" }])).toEqual([]);
    expect(_imageBlocksFromToolResult("ok")).toEqual([]);
    expect(_imageBlocksFromToolResult(undefined)).toEqual([]);
  });

  test("materialises the bytes under the card id and keeps the claimed name", async () => {
    const res = await _encodeInlineImage(
      { data: PNG_2X2.toString("base64"), mimeType: "image/png" },
      { id: "att_tc-42", name: "computer_screen-shot.png" },
    );
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.meta).toMatchObject({ id: "att_tc-42", name: "computer_screen-shot.png", mime: "image/png", size: PNG_2X2.length });
    // The card's path is OUR copy, not wherever the tool had it: a later
    // `file_get` reads this file, and tools reuse their file names.
    expect(res.meta.path).toBe(join(store, "att_tc-42.png"));
    expect(readFileSync(res.meta.path).equals(PNG_2X2)).toBe(true);
    expect(res.data).toBe(PNG_2X2.toString("base64"));
    expect(res.meta.resized).toBeUndefined();
  });

  test("names the card after the bytes: a missing extension is added", async () => {
    const res = await _encodeInlineImage(
      { data: PNG_2X2.toString("base64"), mimeType: "image/png" },
      { id: "att_tc-43", name: "computer_screen" },
    );
    expect(res.ok && res.meta.name).toBe("computer_screen.png");
  });

  test("a block that lies about being an image gets no card", async () => {
    const res = await _encodeInlineImage(
      { data: Buffer.from("not an image at all").toString("base64"), mimeType: "image/png" },
      { id: "att_tc-44", name: "fake.png" },
    );
    expect(res.ok).toBe(false);
    expect(res.ok === false && res.code).toBe("unsupported");
  });

  test("an oversized image is downscaled and the resized bytes are what get stored", async () => {
    const payload = Buffer.alloc(2048, 7).toString("base64");
    _mockResize({ data: payload, mimeType: "image/jpeg" });
    const res = await _encodeInlineImage(
      { data: Buffer.concat([PNG_MAGIC, Buffer.alloc(ATTACHMENT_MAX_BYTES)]).toString("base64"), mimeType: "image/png" },
      { id: "att_tc-45", name: "huge.png" },
    );
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(res.meta).toMatchObject({ resized: true, mime: "image/jpeg", original_size: ATTACHMENT_MAX_BYTES + PNG_MAGIC.length });
    expect(res.meta.size).toBe(2048);
    // The extension follows the mime we actually stored.
    expect(res.meta.path).toBe(join(store, "att_tc-45.jpg"));
    expect(readFileSync(res.meta.path).equals(Buffer.alloc(2048, 7))).toBe(true);
    expect(res.meta.name).toBe("huge.jpg");
  });

  test("a card id can never escape the store", async () => {
    const res = await _encodeInlineImage(
      { data: PNG_2X2.toString("base64"), mimeType: "image/png" },
      { id: "att_../../etc/passwd", name: "x.png" },
    );
    expect(res.ok).toBe(true);
    if (!res.ok) return;
    expect(dirname(res.meta.path)).toBe(store);
    expect(basename(res.meta.path)).toBe("att_etcpasswd.png");
  });

  test("the store keeps its newest cards instead of growing forever", () => {
    mkdirSync(store, { recursive: true });
    const stamps = [1, 2, 3, 4];
    for (const stamp of stamps) {
      const path = join(store, `att_t${stamp}.png`);
      writeFileSync(path, PNG_2X2);
      utimesSync(path, stamp, stamp);
    }
    _pruneInlineImageStore(store, 2);
    expect(readdirSync(store).sort()).toEqual(["att_t3.png", "att_t4.png"]);
  });
});

describe("send_to_phone tool", () => {
  function harness() {
    const tools: Array<{ name: string; execute: (id: string, params: unknown) => Promise<unknown> }> = [];
    const broadcast: unknown[] = [];
    const remembered: unknown[] = [];
    const pi = {
      registerTool: (t: { name: string; execute: (id: string, params: unknown) => Promise<unknown> }) => {
        tools.push(t);
        return undefined;
      },
    } as unknown as ExtensionAPI;
    registerSendToPhoneTool(pi, {
      broadcast: (offer) => broadcast.push(offer),
      remember: (meta) => remembered.push(meta),
    });
    return { tool: tools[0], broadcast, remembered };
  }

  test("broadcasts the offer, remembers it, and tells the model what happened", async () => {
    const { tool, broadcast, remembered } = harness();
    const path = write("chart.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(500)]));
    const res = (await tool.execute("tc-7", { path, note: "  throughput  " })) as {
      content: { text: string }[];
      details: { ok: boolean; id: string };
    };
    expect(broadcast).toHaveLength(1);
    const offer = broadcast[0] as { type: string; id: string; data: string; name: string; note?: string };
    expect(offer.type).toBe("file_offer");
    expect(offer.id).toBe("att_tc-7");
    expect(offer.name).toBe("chart.png");
    expect(offer.note).toBe("throughput");
    expect(offer.data.length).toBeGreaterThan(0);
    expect(remembered).toEqual([expect.objectContaining({ id: "att_tc-7", path, mime: "image/png" })]);
    expect(res.content[0].text).toBe("Sent chart.png (image/png, 508 bytes) to the phone.");
    expect(res.details.ok).toBe(true);
  });

  test("the tool result says when the file was downscaled", async () => {
    const { tool } = harness();
    const path = write("huge.jpg", Buffer.concat([JPEG_MAGIC, Buffer.alloc(ATTACHMENT_MAX_BYTES)]));
    _mockResize({ data: Buffer.alloc(2048, 1).toString("base64"), mimeType: "image/jpeg" });
    const res = (await tool.execute("tc-8", { path })) as { content: { text: string }[] };
    expect(res.content[0].text).toContain("downscaled from 2.0 MB");
  });

  test("a refusal never reaches the wire and explains itself to the model", async () => {
    const { tool, broadcast, remembered } = harness();
    const res = (await tool.execute("tc-9", { path: join(dir, "ghost.png") })) as {
      content: { text: string }[];
      details: { ok: boolean; error?: string };
    };
    expect(broadcast).toHaveLength(0);
    expect(remembered).toHaveLength(0);
    expect(res.details.ok).toBe(false);
    expect(res.content[0].text).toContain("No such file");
  });
});

describe("file_get", () => {
  test("answers with the requested card id so the app upserts", async () => {
    const path = write("chart.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(64)]));
    const sent: ServerMessage[] = [];
    await handleFileGetRequest({ id: "g-1", path, attachment_id: "att_tc-3" }, (m) => sent.push(m));
    expect(sent).toHaveLength(1);
    const offer = sent[0] as { type: string; id: string; in_reply_to: string; data: string };
    expect(offer.type).toBe("file_offer");
    expect(offer.id).toBe("att_tc-3");
    expect(offer.in_reply_to).toBe("g-1");
    expect(offer.data.length).toBeGreaterThan(0);
  });

  test("a missing card id is replaced, never echoed back verbatim", async () => {
    const path = write("chart.png", Buffer.concat([PNG_MAGIC, Buffer.alloc(64)]));
    const sent: ServerMessage[] = [];
    await handleFileGetRequest({ id: "g-2", path, attachment_id: "../../etc/passwd" }, (m) => sent.push(m));
    expect((sent[0] as { id: string }).id).toBe("att_get_g-2");
  });

  test("a file that vanished answers with an error the app can show", async () => {
    const sent: ServerMessage[] = [];
    await handleFileGetRequest({ id: "g-3", path: join(dir, "tmp.png") }, (m) => sent.push(m));
    expect(sent[0]).toMatchObject({ type: "error", in_reply_to: "g-3", code: "not_found" });
  });
});
