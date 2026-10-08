// Pi → App file hand-off (`send_to_phone` tool + `file_get` handler).
//
// The mirror of the app's attachment upload: the phone sends images/text files
// to the Pi, this sends a file that already lives on the Pi's disk back to the
// phone. Same content-first rule as the upload path — what counts as an image
// or as text is decided by the BYTES, never by the name.
//
// Why the size cap is what it is: the relay accepts a 4 MiB outer envelope
// (`RELAY_MAX_CT_MIB`) measured on `ct`, which is Base64 of the inner JSON. So
// B original bytes → 4/3 B (inner) → 16/9 B (ct) ≈ 1.78 B, and 16/9·B ≤ 4 MiB
// gives B ≤ ~2.3 MB. We cap at 2 MiB and DOWNSCALE images to fit (the SDK's own
// `resizeImage`, Photon/WASM — no new dependency); anything that still doesn't
// fit is refused with a message that says what to do instead.

import { closeSync, openSync, readSync, realpathSync, statSync } from "node:fs";
import { basename, extname } from "node:path";
import { Type } from "typebox";
import { resizeImage } from "@earendil-works/pi-coding-agent";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage, WireFileOffer } from "../protocol/types.js";

/** Hard ceiling for the bytes we put on the wire (see the module comment). */
export const ATTACHMENT_MAX_BYTES = 2 * 1024 * 1024;

/**
 * Text ceiling. The content travels as base64 (not as a raw JSON string), so
 * escape-doubling no longer applies — but 1 MiB of text in a chat bubble is
 * already past anything readable on a phone, and it keeps the envelope small.
 */
export const ATTACHMENT_TEXT_MAX_BYTES = 1 * 1024 * 1024;

/** Longest edge after a downscale. The card renders at 300×220 CSS px, so even
 *  a 3× screen is covered with room to spare. */
export const ATTACHMENT_MAX_DIM = 1600;

export const SEND_TO_PHONE_TOOL = "send_to_phone";
export const ATTACHMENT_CUSTOM_TYPE = "remote-pi:attachment";

/** Metadata persisted for history replay (the `attachment` event, minus `ts`). */
export interface AttachmentMeta {
  id: string;
  name: string;
  path: string;
  mime: string;
  size: number;
  note?: string;
  resized?: boolean;
  original_size?: number;
}

/** The `file_offer` ServerMessage: the offer plus its envelope fields. */
export type FileOfferMessage = WireFileOffer & { type: "file_offer"; in_reply_to?: string };

export type AttachmentEncodeResult =
  | { ok: true; meta: AttachmentMeta; data: string }
  | { ok: false; code: "not_found" | "too_large" | "unsupported" | "internal_error"; message: string };

// ── content sniffing ─────────────────────────────────────────────────────────

/** Image magic we accept, keyed by the mime we report for it. */
const IMAGE_MIME_BY_MAGIC: ReadonlyArray<{ mime: string; matches: (b: Buffer) => boolean }> = [
  { mime: "image/png", matches: (b) => b.length > 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
  { mime: "image/jpeg", matches: (b) => b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  { mime: "image/gif", matches: (b) => b.length > 6 && (b.subarray(0, 6).toString("latin1") === "GIF87a" || b.subarray(0, 6).toString("latin1") === "GIF89a") },
  { mime: "image/webp", matches: (b) => b.length > 12 && b.subarray(0, 4).toString("latin1") === "RIFF" && b.subarray(8, 12).toString("latin1") === "WEBP" },
  { mime: "image/bmp", matches: (b) => b.length > 2 && b[0] === 0x42 && b[1] === 0x4d },
];

/** The image mime for these bytes, or null when it isn't a supported image. */
export function _sniffImageMime(bytes: Buffer): string | null {
  for (const { mime, matches } of IMAGE_MIME_BY_MAGIC) {
    try {
      if (matches(bytes)) return mime;
    } catch {
      // A truncated buffer throws inside some matchers; treat as "not this one".
    }
  }
  return null;
}

/**
 * Decode as text, or null when the bytes are not text.
 *
 * Same rules the app applies before accepting an upload: an explicit UTF-16 BOM
 * (mandatory there, since UTF-16 text usually decodes as valid UTF-8 by
 * accident), an optional UTF-8 BOM, otherwise strict UTF-8 with no NUL byte.
 * The check is on the content, so `Makefile`, `.gitignore` and a binary `.txt`
 * land on the right side of the line without any extension table.
 */
export function _decodeTextStrict(bytes: Buffer): string | null {
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xfe) {
    return _decodeUtf16(bytes.subarray(2), true);
  }
  if (bytes.length >= 2 && bytes[0] === 0xfe && bytes[1] === 0xff) {
    return _decodeUtf16(bytes.subarray(2), false);
  }
  if (bytes.includes(0)) return null;
  const body = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf
    ? bytes.subarray(3)
    : bytes;
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(body);
  } catch {
    return null;
  }
}

/** UTF-16 with a mandatory BOM. `fatal` rejects lone surrogates, which is what
 *  keeps a mislabelled binary from decoding into plausible-looking mojibake. */
function _decodeUtf16(body: Buffer, littleEndian: boolean): string | null {
  if (body.length % 2 !== 0) return null;
  const buf = littleEndian ? body : Buffer.from(body).swap16();
  try {
    return new TextDecoder("utf-16le", { fatal: true }).decode(buf);
  } catch {
    return null;
  }
}

/** The mime we report for a text file: `text/plain` unless the name says better. */
function _textMime(path: string): string {
  const ext = extname(path).toLowerCase();
  if (ext === ".json") return "application/json";
  if (ext === ".svg") return "image/svg+xml";
  if (ext === ".html" || ext === ".htm") return "text/html";
  if (ext === ".csv" || ext === ".tsv") return "text/csv";
  if (ext === ".xml") return "application/xml";
  if (ext === ".md" || ext === ".markdown") return "text/markdown";
  return "text/plain";
}

// ── encoding ─────────────────────────────────────────────────────────────────

function _fail(code: Extract<AttachmentEncodeResult, { ok: false }>["code"], message: string): AttachmentEncodeResult {
  return { ok: false, code, message };
}

/**
 * Read `path` and return what should go on the wire: the metadata plus the
 * base64 payload. Never throws — a missing file, a directory, a binary blob or
 * something that will not fit under the cap all come back as a typed failure
 * the tool turns into a message the model can act on.
 */
export async function _encodeAttachment(rawPath: string): Promise<AttachmentEncodeResult> {
  if (typeof rawPath !== "string" || rawPath.trim() === "") {
    return _fail("not_found", "No path given.");
  }
  let path: string;
  try {
    // realpath first: the wire reports the resolved path, so a symlink or a
    // `~` the shell expanded can never point somewhere the app didn't name.
    path = realpathSync(rawPath.trim());
  } catch {
    return _fail("not_found", `No such file: ${rawPath}`);
  }

  let size: number;
  try {
    const st = statSync(path);
    if (!st.isFile()) return _fail("not_found", `Not a regular file: ${path}`);
    size = st.size;
  } catch (err) {
    return _fail("not_found", `Cannot stat ${path}: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (size === 0) return _fail("unsupported", `${basename(path)} is empty.`);

  // Read a bounded prefix for sniffing: a 400 MB video must not be pulled into
  // memory just to learn that we will refuse it anyway. `+ 1` so a file that
  // grew between `stat` and `read` is detected as over-cap rather than
  // silently truncated into a "valid" image.
  const cap = Math.min(size, ATTACHMENT_MAX_BYTES) + 1;
  let head: Buffer;
  try {
    const fd = openSync(path, "r");
    try {
      const buf = Buffer.alloc(cap);
      const read = readSync(fd, buf, 0, cap, 0);
      head = buf.subarray(0, read);
    } finally {
      closeSync(fd);
    }
  } catch (err) {
    return _fail("internal_error", `Cannot read ${path}: ${err instanceof Error ? err.message : String(err)}`);
  }

  const imageMime = _sniffImageMime(head);
  if (imageMime) {
    if (size <= ATTACHMENT_MAX_BYTES) {
      // Small enough: ship the original bytes untouched (no re-encode, no loss).
      return {
        ok: true,
        data: head.toString("base64"),
        meta: { id: "", name: basename(path), path, mime: imageMime, size },
      };
    }
    const resized = await resizeImage(head, imageMime, {
      maxWidth: ATTACHMENT_MAX_DIM,
      maxHeight: ATTACHMENT_MAX_DIM,
      maxBytes: ATTACHMENT_MAX_BYTES,
    }).catch(() => null);
    if (!resized) {
      return _fail(
        "too_large",
        `${basename(path)} is ${size} bytes and could not be downscaled under the ` +
        `${ATTACHMENT_MAX_BYTES} byte limit. Share a link or a smaller export instead.`,
      );
    }
    return {
      ok: true,
      data: resized.data,
      meta: {
        id: "",
        name: basename(path),
        path,
        mime: resized.mimeType,
        size: Math.floor((resized.data.length * 3) / 4),
        resized: true,
        original_size: size,
      },
    };
  }

  if (size > ATTACHMENT_TEXT_MAX_BYTES) {
    return _fail(
      "unsupported",
      `${basename(path)} is ${size} bytes and is not an image. The phone channel carries images ` +
      `and text files up to ${ATTACHMENT_TEXT_MAX_BYTES} bytes; publish it somewhere and send the link.`,
    );
  }
  if (_decodeTextStrict(head) === null) {
    return _fail(
      "unsupported",
      `${basename(path)} is binary. The phone channel carries images and text files only — ` +
      `send a link, or a text export of it.`,
    );
  }
  return {
    ok: true,
    data: head.toString("base64"),
    meta: { id: "", name: basename(path), path, mime: _textMime(path), size },
  };
}

// ── the tool ─────────────────────────────────────────────────────────────────

export interface SendToPhoneDeps {
  /** Push the live offer to every attached owner. */
  broadcast: (offer: FileOfferMessage) => void;
  /** Persist the metadata so a later `session_sync` replays the same card. */
  remember: (meta: AttachmentMeta) => void;
}

function _humanSize(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${bytes} bytes`;
}

function _sentLine(meta: AttachmentMeta): string {
  const parts = [`Sent ${meta.name} (${meta.mime}, ${_humanSize(meta.size)})`];
  if (meta.resized && meta.original_size) parts.push(`downscaled from ${_humanSize(meta.original_size)}`);
  return `${parts.join(", ")} to the phone.`;
}

/**
 * Register `send_to_phone`. Registered tools are active by default (same rule
 * as `agent_send`), so the model can hand a file over without any setup.
 *
 * The tool deliberately publishes NO `tool_request`/`tool_result` to the app:
 * the attachment card IS the app's rendering of this call, and a second card
 * for the same event would just be noise. The model still gets a one-line
 * result (and the details object), so it can report honestly what happened.
 */
export function registerSendToPhoneTool(pi: ExtensionAPI, deps: SendToPhoneDeps): void {
  const Params = Type.Object({
    path: Type.String({
      description: "Absolute path of the file on this machine (image or text file).",
    }),
    note: Type.Optional(Type.String({
      description: "One short line shown under the card on the phone, in the user's language.",
    })),
  });

  pi.registerTool<typeof Params, AttachmentMeta & { ok: boolean; error?: string }>({
    name: SEND_TO_PHONE_TOOL,
    label: "Send To Phone",
    description:
      "Show a file from this machine in the phone app: it appears as a card in the chat " +
      "timeline (an image renders inline, a text file shows its name and a preview). Use it " +
      "to hand over a screenshot, a chart, a generated report or any other file the user " +
      "asked to see. One file per call. Images over 2 MB are downscaled automatically; " +
      "binary files and text over 1 MB are refused — send a link for those.",
    promptSnippet:
      "send_to_phone({path, note?}): puts a file from this machine into the chat on the phone " +
      "(image → inline thumbnail, text → name + preview; ≤2 MB images auto-downscaled, ≤1 MB text).",
    parameters: Params,
    execute: async (toolCallId, params) => {
      const { path, note } = params as { path: string; note?: string };
      const encoded = await _encodeAttachment(path);
      if (!encoded.ok) {
        // `ok: false` is what the model reads; details mirror it for the TUI.
        return {
          content: [{ type: "text", text: `Could not send the file: ${encoded.message}` }],
          details: { ok: false, error: encoded.message, id: "", name: "", path: "", mime: "", size: 0 },
        };
      }
      const meta: AttachmentMeta = {
        ...encoded.meta,
        id: `att_${toolCallId}`,
        ...(note && note.trim() ? { note: note.trim() } : {}),
      };
      deps.broadcast({ type: "file_offer", ...meta, data: encoded.data });
      deps.remember(meta);
      return { content: [{ type: "text", text: _sentLine(meta) }], details: { ...meta, ok: true } };
    },
  });
}

/** Card ids are `att_<toolCallId>`; anything else from the wire is replaced. */
const ATTACHMENT_ID_RE = /^att_[A-Za-z0-9_-]{1,64}$/;

/**
 * Answer a `file_get` with the bytes for one card.
 *
 * The app asks by `path` and names the card it wants filled
 * (`attachment_id`, the id the `attachment` history event carried), so the
 * reply upserts the existing bubble instead of adding a second one. A missing
 * or malformed id is not fatal: we mint one from the request id, and the app
 * still gets the content to show.
 */
export async function handleFileGetRequest(
  msg: { id: string; path: string; attachment_id?: string },
  reply: (m: ServerMessage) => void,
): Promise<void> {
  const encoded = await _encodeAttachment(msg.path);
  if (!encoded.ok) {
    reply({ type: "error", in_reply_to: msg.id, code: encoded.code, message: encoded.message });
    return;
  }
  const requested = typeof msg.attachment_id === "string" ? msg.attachment_id : "";
  reply({
    type: "file_offer",
    ...encoded.meta,
    id: ATTACHMENT_ID_RE.test(requested) ? requested : `att_get_${msg.id}`,
    data: encoded.data,
    in_reply_to: msg.id,
  });
}
