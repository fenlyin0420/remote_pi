export type PairErrorCode = "token_expired" | "token_consumed" | "token_unknown" | "internal_error";
export type StreamingBehavior = "steer";
export type QueuedMessageItem = {
    id: string;
    text: string;
    editable: boolean;
    created_at: number;
};
export type ExtensionUiMethod = "select" | "confirm" | "input" | "editor" | "notify";
export type AskQuestionWireType = "single" | "multi" | "preview";
export interface AskOptionWire {
    value: string;
    label: string;
    description?: string;
    /** Preview-pane content (preview questions only). */
    preview?: string;
    /** pi-ask addition: option allows freeform custom entry. */
    freeform?: boolean;
}
export interface AskQuestionWire {
    id: string;
    label: string;
    prompt: string;
    type: AskQuestionWireType;
    required: boolean;
    /** pi-ask addition: type actually presented after live toggle / policy. */
    presentedType?: AskQuestionWireType;
    /** pi-ask addition: type originally requested by the model. */
    requestedType?: AskQuestionWireType;
    options: AskOptionWire[];
}
/** Optional pi-ask enrichment on an extension_ui_request — lets the app render
 *  the full flow (multi/preview/notes) instead of the degraded SDK select. A
 *  flow maps to ONE request carrying every question; the app renders a
 *  full-screen modal and submits ONE response with all answers (pi-ask resolves
 *  a flow in a single submit). When `ask` is absent the SDK method/options
 *  drive rendering (future generic prompts). */
export interface AskEnrichmentWire {
    flow_id: string;
    tool_call_id: string | null;
    /** pi-ask RemoteAskSource: "tool" | "answer" | "answer:again" | "ask:replay". */
    source: string;
    title: string | null;
    questions: AskQuestionWire[];
}
/** pi-ask RemoteAskAnswer — one question's answered parts.
 *
 *  CASING EXCEPTION: inside the `ask` envelope the keys mirror pi-ask's own
 *  schema VERBATIM (camelCase: `presentedType`, `requestedType`, `customText`,
 *  `optionNotes`) so the bridge can forward the response to pi-ask's submit
 *  event without a remap pass. The snake_case convention of this protocol
 *  applies at the frame level (`flow_id`, `tool_call_id`, `notify_type`). */
export interface AskAnswerWire {
    values?: string[];
    customText?: string;
    note?: string;
    optionNotes?: Record<string, string>;
}
/** Optional pi-ask enrichment on an extension_ui_response — carries the
 *  structured answer so multi/preview/notes survive the round-trip. */
export type AskResponseEnrichmentWire = {
    flow_id: string;
    kind: "answer";
    mode?: "submit" | "elaborate";
    answers: Record<string, AskAnswerWire>;
} | {
    flow_id: string;
    kind: "cancel";
};
/** ServerMessage: interactive extension prompt. Mirrors RpcExtensionUIRequest
 *  (select/confirm/input/editor/notify). The `ask` envelope is present when the
 *  prompt originates from a pi-ask flow, carrying the full question schema. */
export type ExtensionUiRequestWire = {
    type: "extension_ui_request";
    id: string;
    method: "select";
    title: string;
    options: string[];
    ask?: AskEnrichmentWire;
} | {
    type: "extension_ui_request";
    id: string;
    method: "confirm";
    title: string;
    message: string;
    ask?: AskEnrichmentWire;
} | {
    type: "extension_ui_request";
    id: string;
    method: "input";
    title: string;
    placeholder?: string;
    ask?: AskEnrichmentWire;
} | {
    type: "extension_ui_request";
    id: string;
    method: "editor";
    title: string;
    prefill?: string;
    ask?: AskEnrichmentWire;
} | {
    type: "extension_ui_request";
    id: string;
    method: "notify";
    message: string;
    notify_type?: "info" | "warning" | "error";
};
/** ClientMessage: response to an extension_ui_request. Mirrors
 *  RpcExtensionUIResponse (value / confirmed / cancelled). The `ask` envelope
 *  carries pi-ask's structured answer when the app rendered the rich flow. */
export type ExtensionUiResponseWire = {
    type: "extension_ui_response";
    id: string;
    value: string;
    ask?: AskResponseEnrichmentWire;
} | {
    type: "extension_ui_response";
    id: string;
    confirmed: boolean;
    ask?: AskResponseEnrichmentWire;
} | {
    type: "extension_ui_response";
    id: string;
    cancelled: true;
    ask?: AskResponseEnrichmentWire;
} | {
    type: "extension_ui_response";
    id: string;
    ask: AskResponseEnrichmentWire;
};
export type ClientMessage = {
    type: "pair_request";
    id: string;
    token: string;
    device_name: string;
} | {
    type: "user_message";
    id: string;
    text: string;
    images?: WireImage[];
    files?: WireFile[];
    streaming_behavior?: StreamingBehavior;
} | {
    type: "queued_message_set";
    id: string;
    text: string;
} | {
    type: "queued_message_clear";
    id: string;
    target_id?: string;
} | {
    type: "file_get";
    id: string;
    path: string;
    attachment_id?: string;
} | {
    type: "approve_tool";
    id: string;
    tool_call_id: string;
    decision: "allow" | "deny";
} | {
    type: "cancel";
    id: string;
    target_id: string;
} | {
    type: "ping";
    id: string;
} | {
    type: "session_sync";
    id: string;
    limit?: number;
} | {
    type: "session_new";
    id: string;
} | {
    type: "session_list";
    id: string;
} | {
    type: "session_switch";
    id: string;
    session: string;
} | {
    type: "session_compact";
    id: string;
} | {
    type: "model_set";
    id: string;
    provider: string;
    model_id: string;
} | {
    type: "thinking_set";
    id: string;
    level: ThinkingLevel;
} | {
    type: "list_models";
    id: string;
} | {
    type: "room_create";
    id: string;
    path: string;
    create_if_missing?: boolean;
    name?: string;
} | {
    type: "room_delete";
    id: string;
    path: string;
    name?: string;
} | {
    type: "command_invoke";
    id: string;
    text: string;
} | {
    type: "bash_exec";
    id: string;
    command: string;
    exclude_from_context?: boolean;
    timeout_ms?: number;
} | {
    type: "list_commands";
    id: string;
} | ExtensionUiResponseWire;
/**
 * Plan/30 — one inline image attachment on a `user_message`. Mirrors the
 * SDK's `ImageContent` ({@link https }) split across the wire: `data` is the
 * base64-encoded (compressed) image bytes, `mime` its content type
 * (e.g. `"image/jpeg"`). The Pi maps `{ data, mime }` → the SDK's
 * `{ type:"image", data, mimeType }` before handing it to the model.
 */
export interface WireImage {
    /** Base64-encoded image bytes (compressed app-side). */
    data: string;
    /** MIME type, e.g. `"image/jpeg"`. Maps to the SDK's `mimeType`. */
    mime: string;
}
/**
 * Text-file upload carried on a `user_message` (app → Pi). The app decides
 * what counts as text by inspecting the bytes — never the file name — so any
 * decodable text file travels, extension or not.
 *
 * The Pi does not inline the content into the prompt: it writes the file next
 * to its own state dir and tells the agent the absolute path, so the agent
 * reads/edits it with its normal tools. The app → Pi leg carries `text`; the
 * Pi → app legs (echo, history replay) carry `path` instead — the bytes are
 * already on disk and never travel back.
 */
export interface WireFile {
    /** File name as picked on the device (no directories). */
    name: string;
    /** UTF-8 content. App → Pi only. */
    text?: string;
    /** Absolute path on the Pi where the file landed. Pi → app only. */
    path?: string;
}
/**
 * A file the Pi hands to the phone (Pi → App), the mirror of `WireFile`.
 *
 * Unlike the upload direction the content DOES come back: the app has no other
 * way to see a file that lives on the Pi's disk. `data` is therefore always
 * present (base64 of the bytes) and bounded — see `ATTACHMENT_MAX_BYTES` in
 * `session/attachment.ts`, which is sized so the double-base64 envelope still
 * fits the relay's 4 MiB.
 */
export interface WireFileOffer {
    /** Stable identity: `att_<toolCallId>` — same in the live offer, in the
     *  `session_history` event and in a `file_get` reply, so every side can
     *  upsert by id. */
    id: string;
    /** File name (no directories). */
    name: string;
    /** Absolute path on the Pi where the file lives. */
    path: string;
    /** Content type, e.g. `"image/png"`. */
    mime: string;
    /** Byte length of `data` (post-downscale for images). */
    size: number;
    /** Base64 of the bytes to show. */
    data: string;
    /** Optional caption written by the agent. */
    note?: string;
    /** Set when the Pi had to downscale/re-encode to fit the envelope. */
    resized?: boolean;
    /** Size on disk before any downscale, when it differs from `size`. */
    original_size?: number;
    /** The tool call whose result carried this image. Present only for images
     *  that came out of a tool's own result (a screenshot, a diagram a tool
     *  read): the app renders those INSIDE that tool's row instead of as a card
     *  of their own. Absent for `send_to_phone`, which is its own card. */
    tool_call_id?: string;
}
export type Usage = {
    input_tokens: number;
    output_tokens: number;
};
export type KnownErrorCode = "tool_approval_required" | "invalid_message" | "unsupported_type" | "too_large" | "rate_limited" | "timeout" | "internal_error";
export type ErrorCode = KnownErrorCode | (string & {});
export type SessionHistoryEvent = {
    ts: number;
    type: "user_input";
    id: string;
    text: string;
    images?: WireImage[];
    files?: WireFile[];
    model?: string;
} | {
    ts: number;
    type: "tool_request";
    tool_call_id: string;
    tool: string;
    args: Record<string, unknown>;
    /** LOCAL (fenlyin): the model that issued the call (per-row caption). */
    model?: string;
} | {
    ts: number;
    type: "tool_result";
    tool_call_id: string;
    result?: unknown;
    error?: string;
    /** The change the tool made, when it reports one (see `tool_result`). */
    diff?: string;
} | {
    ts: number;
    type: "agent_message";
    in_reply_to: string;
    text: string;
    usage?: Usage;
    /** LOCAL (fenlyin): the model that produced this text (per-row caption). */
    model?: string;
} | {
    ts: number;
    type: "agent_thinking";
    in_reply_to: string;
    text: string;
    duration_ms?: number;
    model?: string;
} | {
    ts: number;
    type: "attachment";
    id: string;
    name: string;
    path: string;
    mime: string;
    size: number;
    note?: string;
    resized?: boolean;
    original_size?: number;
    /** The tool call that produced the image, when a tool's result did —
     *  the app nests such a card inside that tool's row. */
    tool_call_id?: string;
    /** LOCAL (fenlyin): the model whose turn produced the file. */
    model?: string;
} | {
    ts: number;
    type: "compaction";
    summary: string;
    tokens_before: number;
    model?: string;
};
export type ServerMessage = {
    type: "pair_ok";
    in_reply_to: string;
    session_name: string;
    session_started_at: number;
    room_id: string;
    /**
     * Plan/27 Wave A: identifies the host coding agent driving this
     * pi-remote instance. `name` is hardcoded to "Pi coding agent"
     * today; future Pi forks (Claude Code, OpenCode) populate their own
     * here. `version` is the pi-remote `package.json` version.
     * Optional in the wire schema so app-side parsing tolerates older
     * Pi builds that predate this field — every new pairing emits both.
     */
    harness?: {
        name: string;
        version: string;
    };
    /**
     * Plan/27 Wave A: `os.hostname()` of the machine the Pi runs on.
     * App displays it in the device list so the user can distinguish
     * two paired PCs that happen to share a nickname or sit in the
     * same project folder.
     */
    hostname?: string;
} | {
    type: "pair_error";
    in_reply_to: string;
    code: PairErrorCode;
    message: string;
} | {
    type: "user_input";
    id: string;
    text: string;
    streaming_behavior?: StreamingBehavior;
} | {
    type: "user_message";
    id: string;
    text: string;
    images?: WireImage[];
    files?: WireFile[];
    streaming_behavior?: StreamingBehavior;
} | {
    type: "queued_message_state";
    id?: string;
    text?: string;
    items?: QueuedMessageItem[];
} | {
    type: "steer_consumed";
    id: string;
} | {
    type: "agent_chunk";
    in_reply_to: string;
    delta: string;
} | {
    type: "agent_thinking";
    in_reply_to: string;
    delta: string;
} | {
    type: "agent_done";
    in_reply_to: string;
    usage?: Usage;
} | (WireFileOffer & {
    type: "file_offer";
    in_reply_to?: string;
}) | {
    type: "agent_message";
    in_reply_to: string;
    text: string;
    usage?: Usage;
} | {
    type: "compaction";
    summary: string;
    tokens_before: number;
    ts?: number;
} | {
    type: "tool_request";
    tool_call_id: string;
    tool: string;
    args: Record<string, unknown>;
} | {
    type: "tool_result";
    tool_call_id: string;
    result?: unknown;
    error?: string;
    diff?: string;
} | {
    type: "error";
    in_reply_to?: string;
    code: ErrorCode;
    message: string;
} | {
    type: "cancelled";
    in_reply_to: string;
    target_id: string;
} | {
    type: "pong";
    in_reply_to: string;
} | {
    type: "bye";
    reason: ByeReason;
} | {
    type: "session_history";
    in_reply_to: string;
    session_started_at: number;
    events: SessionHistoryEvent[];
    eos: boolean;
    truncated: boolean;
} | {
    type: "action_ok";
    in_reply_to: string;
    action: ActionName;
} | {
    type: "action_error";
    in_reply_to: string;
    action: ActionName;
    error: string;
} | {
    type: "models_list";
    in_reply_to: string;
    models: WireModel[];
    current?: WireModel;
} | {
    type: "sessions_list";
    in_reply_to: string;
    sessions: WireSession[];
} | {
    type: "commands_list";
    in_reply_to: string;
    commands: WireCommand[];
} | {
    type: "extension_ui_request";
    id: string;
    method: "notify";
    message: string;
    notify_type?: "info" | "warning" | "error";
} | ExtensionUiRequestWire;
/**
 * Plan/28 — Stable names for the typed actions the app can request. Kept
 * as a closed string union so a switch in either side gets exhaustiveness
 * checking from the compiler.
 */
export type ActionName = "session_new" | "session_compact" | "model_set" | "thinking_set" | "room_create" | "room_delete" | "command_invoke" | "bash_exec" | "list_commands" | "session_list" | "session_switch";
/**
 * One entry of the app's `/` palette (reply to `list_commands`).
 *
 * `source` says where the name came from; `scope` and `supported` say
 * whether THIS room can actually run it, so the app greys a dead entry out
 * instead of offering it and failing.
 *
 * `scope: "daemon"` marks the names that need Pi's RPC stdin channel, which
 * only a supervisor-spawned daemon has. A TUI-hosted Pi has no equivalent: an
 * extension cannot reach `AgentSession.prompt`, so extension commands, skills
 * and prompt templates are unreachable there — remote-pi says so instead of
 * letting the text fall through to the model as a literal message.
 */
export interface WireCommand {
    /** Name without the leading slash. E.g. `"compact"`, `"skill:review"`. */
    name: string;
    /** Shown as the palette subtitle. Absent for names the SDK didn't describe. */
    description?: string;
    source: "builtin" | "extension" | "prompt" | "skill";
    scope: "all" | "daemon" | "tui";
    /** False when remote-pi recognises the name but has no implementation here
     *  (a TUI-only builtin). The app renders it disabled. */
    supported: boolean;
}
/**
 * Plan/59 — one entry of the session picker's catalogue (reply to
 * `session_list`). Mirrors the SDK's `SessionInfo` onto the wire, trimmed
 * to what the app renders: display name (falling back to the first user
 * message), size, last activity and whether this is the session the room
 * is currently on. `id` is the session file's UUID — the app hands it back
 * verbatim on `session_switch`.
 */
export interface WireSession {
    id: string;
    /** User-set display name; absent when the session never named itself. */
    name?: string;
    /** First user message, truncated — the picker's subtitle. */
    first_message: string;
    message_count: number;
    /** ISO-8601 of the session file's last write. */
    modified: string;
    /** True for the session the room is currently on. */
    is_current: boolean;
}
/**
 * Plan/28 — Mirror of the SDK's `ThinkingLevel` (defined in
 * `@earendil-works/pi-agent-core/types`). Re-declared locally so the wire
 * protocol owns its own enum and we don't leak SDK-internal types onto
 * the app's network surface.
 *
 * Note: `"xhigh"` is only honored by select model families — the SDK uses
 * each `Model.thinkingLevelMap` to decide if the requested level is
 * supported, falling back to a sensible neighbour when not. The app
 * surfaces every button but can grey out unsupported ones using the
 * model's metadata if the picker fetches it later.
 *
 * `"auto"` is a session-level concept newer Pi builds resolve per request
 * from the task complexity; builds that predate it clamp an unknown level
 * (to `"off"`), so callers must probe support before seeding it.
 */
export type ThinkingLevel = "off" | "auto" | "minimal" | "low" | "medium" | "high" | "xhigh";
/**
 * Plan/28 — Wire shape for one model entry in the app's model picker.
 *
 * Subset of the SDK's `Model<Api>` interface — only the fields the app
 * actually renders. Cost / max-tokens / API class are left off the wire
 * deliberately; if the app's picker grows to need them, they get added
 * here and to the handler's mapping in `index.ts` in one diff.
 */
export interface WireModel {
    /** Stable identifier inside the provider's catalog. E.g. `"claude-opus-4-7"`. */
    id: string;
    /** Display name for the picker row. E.g. `"Claude Opus 4.7"`. */
    name: string;
    /** Provider slug. E.g. `"anthropic"`, `"openai"`. */
    provider: string;
    /** Whether the model supports the thinking surface (`reasoning: true`
     *  in the SDK). Useful so the app can decide whether the thinking
     *  segmented control should be enabled when this model is selected. */
    reasoning: boolean;
    /** Context window in tokens, for display in the picker subtitle. */
    context_window: number;
    /** Plan/30: true when the model accepts image input (SDK `Model.input`
     *  includes `"image"`). The app uses it to enable/disable the attach
     *  button — a text-only model greys out image attachments. */
    vision: boolean;
}
export type ByeReason = "peer_stop" | "session_replaced" | "shutdown";
