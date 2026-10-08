/**
 * JCS-like canonical JSON encoder for the mesh membership protocol.
 *
 * **Spec**: plan/24-mesh-membership.md — "chaves ordenadas alfabeticamente +
 * separadores `,` e `:` sem espaços. Mesma regra em Dart, Rust, TypeScript."
 *
 * **Bit-compatibility contract** (must hold across the 3 implementations):
 *   - Object keys sorted lexicographically by UTF-16 code unit order
 *     (matches Dart's String compareTo, Rust's BTreeMap<String, _>, and
 *     JS's Array.prototype.sort() default).
 *   - No whitespace between any tokens.
 *   - Arrays preserve insertion order (caller's responsibility to sort if
 *     determinism across producers matters — verifier doesn't enforce).
 *   - Numbers serialized via JSON.stringify default (no trailing zeros).
 *     Mesh schema only carries integers (`version`, `issued_at`), so the
 *     fragile float-formatting space is avoided by design.
 *   - Strings UTF-8 encoded, JSON-escape rules per RFC 8259 (control chars
 *     and `\\`, `"` escaped; raw UTF-8 for printable code points). Matches
 *     `dart:convert.jsonEncode` and `serde_json::to_string` defaults.
 *   - `null` preserved; `undefined`/functions/symbols dropped (mirrors
 *     JSON.stringify).
 *
 * Verification path: receiver canonicalizes nothing — it verifies the
 * raw blob bytes as-received against the signature. This module is used
 * only on the *sender* side, and on the *test* side to construct fixtures
 * for `verify.test.ts`.
 */

export function canonicalize(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("canonical: non-finite number cannot be JSON-encoded");
    }
    return JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    // Inside arrays, undefined → null (mirrors JSON.stringify).
    const items = value.map((v) => (v === undefined ? "null" : canonicalize(v)));
    return "[" + items.join(",") + "]";
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).filter((k) => obj[k] !== undefined).sort();
    const pairs = keys.map((k) => JSON.stringify(k) + ":" + canonicalize(obj[k]));
    return "{" + pairs.join(",") + "}";
  }
  // undefined / functions / symbols at the root → JSON.stringify returns
  // undefined; we surface as "null" for callers that wrap us.
  return "null";
}

const TEXT_ENCODER = new TextEncoder();

/** Canonical JSON string as UTF-8 bytes. The exact bytes that get signed. */
export function canonicalBytes(value: unknown): Uint8Array {
  return TEXT_ENCODER.encode(canonicalize(value));
}
