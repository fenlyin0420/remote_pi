import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import type { ServerMessage, WireFileOffer } from "../protocol/types.js";
/** Hard ceiling for the bytes we put on the wire (see the module comment). */
export declare const ATTACHMENT_MAX_BYTES: number;
/**
 * Text ceiling. The content travels as base64 (not as a raw JSON string), so
 * escape-doubling no longer applies — but 1 MiB of text in a chat bubble is
 * already past anything readable on a phone, and it keeps the envelope small.
 */
export declare const ATTACHMENT_TEXT_MAX_BYTES: number;
/** Longest edge after a downscale. The card renders at 300×220 CSS px, so even
 *  a 3× screen is covered with room to spare. */
export declare const ATTACHMENT_MAX_DIM = 1600;
export declare const SEND_TO_PHONE_TOOL = "send_to_phone";
export declare const ATTACHMENT_CUSTOM_TYPE = "remote-pi:attachment";
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
    /** The tool call this image came out of, when it came out of one at all. */
    tool_call_id?: string;
}
/** The `file_offer` ServerMessage: the offer plus its envelope fields. */
export type FileOfferMessage = WireFileOffer & {
    type: "file_offer";
    in_reply_to?: string;
};
export type AttachmentEncodeResult = {
    ok: true;
    meta: AttachmentMeta;
    data: string;
} | {
    ok: false;
    code: "not_found" | "too_large" | "unsupported" | "internal_error";
    message: string;
};
/** The image mime for these bytes, or null when it isn't a supported image. */
export declare function _sniffImageMime(bytes: Buffer): string | null;
/**
 * Decode as text, or null when the bytes are not text.
 *
 * Same rules the app applies before accepting an upload: an explicit UTF-16 BOM
 * (mandatory there, since UTF-16 text usually decodes as valid UTF-8 by
 * accident), an optional UTF-8 BOM, otherwise strict UTF-8 with no NUL byte.
 * The check is on the content, so `Makefile`, `.gitignore` and a binary `.txt`
 * land on the right side of the line without any extension table.
 */
export declare function _decodeTextStrict(bytes: Buffer): string | null;
/**
 * Read `path` and return what should go on the wire: the metadata plus the
 * base64 payload. Never throws — a missing file, a directory, a binary blob or
 * something that will not fit under the cap all come back as a typed failure
 * the tool turns into a message the model can act on.
 */
export declare function _encodeAttachment(rawPath: string): Promise<AttachmentEncodeResult>;
/** One image block of a tool result, as the wire brings it. */
export interface InlineImageBlock {
    /** Base64 of the image bytes. */
    data: string;
    /** What the block claims to be; the bytes have the last word. */
    mimeType: string;
}
/** File extension for a mime we report, for the card's name. */
export declare function _imageExtForMime(mime: string): string;
/**
 * Every image block a tool result carries, in order.
 *
 * Live, `tool_execution_end` hands us the wrapper `{ content, details }`; the
 * history path sees a bare content-array. Both shapes are accepted (same rule
 * as `_stringifyToolResult`), and a block without bytes is skipped rather than
 * turned into an empty card.
 */
export declare function _imageBlocksFromToolResult(value: unknown): InlineImageBlock[];
/** Test seam: materialise tool images in a temp dir, not `~/.pi/remote`. */
export declare function _setInlineImageDirForTest(dir?: string): void;
/** Cards kept in the store. Each one is what a `file_get` reads later, so they
 *  cannot be dropped on the spot — but a session that screenshots all day must
 *  not leave the daemon growing a file per screenshot forever. Past this point
 *  the oldest cards lose their bytes (the app has long since cached the ones
 *  somebody actually looked at, and an ancient card shows the app's
 *  "gone" state instead of a broken image). */
export declare const INLINE_IMAGE_KEEP = 300;
/** Delete all but the `keep` newest files of the inline-image store. */
export declare function _pruneInlineImageStore(dir: string, keep: number): void;
/**
 * Encode one inline image block: write it under `~/.pi/remote/attachments` and
 * return what the wire needs. Both the live offer and the later `file_get` read
 * the file we wrote here, so the card keeps showing the picture it was born
 * with. Downscaling reuses the `send_to_phone` path — same cap, same reason
 * (see the module comment) — but the result is written to disk as well, since
 * the downscaled bytes exist nowhere else.
 */
export declare function _encodeInlineImage(block: InlineImageBlock, opts: {
    id: string;
    name?: string;
}): Promise<AttachmentEncodeResult>;
export interface SendToPhoneDeps {
    /** Push the live offer to every attached owner. */
    broadcast: (offer: FileOfferMessage) => void;
    /** Persist the metadata so a later `session_sync` replays the same card. */
    remember: (meta: AttachmentMeta) => void;
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
export declare function registerSendToPhoneTool(pi: ExtensionAPI, deps: SendToPhoneDeps): void;
/**
 * Answer a `file_get` with the bytes for one card.
 *
 * The app asks by `path` and names the card it wants filled
 * (`attachment_id`, the id the `attachment` history event carried), so the
 * reply upserts the existing bubble instead of adding a second one. A missing
 * or malformed id is not fatal: we mint one from the request id, and the app
 * still gets the content to show.
 */
export declare function handleFileGetRequest(msg: {
    id: string;
    path: string;
    attachment_id?: string;
}, reply: (m: ServerMessage) => void): Promise<void>;
