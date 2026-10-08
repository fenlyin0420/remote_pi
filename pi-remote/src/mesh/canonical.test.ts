import { describe, expect, test } from "vitest";
import { canonicalize, canonicalBytes } from "./canonical.js";

describe("canonical JSON encoder", () => {
  test("primitives match JSON.stringify shape", () => {
    expect(canonicalize(null)).toBe("null");
    expect(canonicalize(true)).toBe("true");
    expect(canonicalize(false)).toBe("false");
    expect(canonicalize(0)).toBe("0");
    expect(canonicalize(42)).toBe("42");
    expect(canonicalize(-7)).toBe("-7");
    expect(canonicalize("hello")).toBe('"hello"');
    expect(canonicalize("with \"quote\"")).toBe('"with \\"quote\\""');
  });

  test("object keys are sorted lexicographically", () => {
    expect(canonicalize({ b: 1, a: 2 })).toBe('{"a":2,"b":1}');
    expect(canonicalize({ z: 1, a: 2, m: 3 })).toBe('{"a":2,"m":3,"z":1}');
  });

  test("no whitespace anywhere", () => {
    const out = canonicalize({ a: [1, 2, 3], b: { c: "x" } });
    expect(out).not.toMatch(/\s/);
    expect(out).toBe('{"a":[1,2,3],"b":{"c":"x"}}');
  });

  test("arrays preserve insertion order", () => {
    expect(canonicalize([3, 1, 2])).toBe("[3,1,2]");
    expect(canonicalize(["b", "a"])).toBe('["b","a"]');
  });

  test("recursive: nested objects sort at every level", () => {
    const input = {
      members: [
        { remote_epk: "k1", relay_url: "u1", paired_at: "t1" },
        { remote_epk: "k2", relay_url: "u2", paired_at: "t2", nickname: "n2" },
      ],
      version: 5,
      owner_pk: "OWNER",
      issued_at: 1700000000000,
    };
    const out = canonicalize(input);
    expect(out).toBe(
      '{"issued_at":1700000000000,"members":' +
      '[{"paired_at":"t1","relay_url":"u1","remote_epk":"k1"},' +
      '{"nickname":"n2","paired_at":"t2","relay_url":"u2","remote_epk":"k2"}],' +
      '"owner_pk":"OWNER","version":5}',
    );
  });

  test("deterministic: same logical input → same bytes", () => {
    const a = { b: 1, a: { y: 2, x: 1 }, c: [3, 2, 1] };
    const b = { a: { x: 1, y: 2 }, c: [3, 2, 1], b: 1 };
    expect(canonicalize(a)).toBe(canonicalize(b));
  });

  test("undefined fields dropped (object); becomes null in arrays", () => {
    expect(canonicalize({ a: 1, b: undefined })).toBe('{"a":1}');
    // eslint-disable-next-line no-sparse-arrays
    expect(canonicalize([1, undefined, 2])).toBe("[1,null,2]");
  });

  test("non-finite numbers throw", () => {
    expect(() => canonicalize(NaN)).toThrow();
    expect(() => canonicalize(Infinity)).toThrow();
  });

  test("UTF-8 bytes round-trip via canonicalBytes", () => {
    const obj = { name: "Renée 🦀" };
    const bytes = canonicalBytes(obj);
    expect(bytes).toBeInstanceOf(Uint8Array);
    const decoded = new TextDecoder().decode(bytes);
    expect(decoded).toBe(canonicalize(obj));
    // Should be valid JSON we can re-parse
    expect(JSON.parse(decoded)).toEqual(obj);
  });

  test("idempotence: parse-then-canonicalize yields same string", () => {
    const obj = {
      version: 18,
      issued_at: 1747958400000,
      owner_pk: "OWNERB64",
      members: [{ remote_epk: "K", relay_url: "U", paired_at: "T" }],
    };
    const once = canonicalize(obj);
    const reparsed = JSON.parse(once);
    const twice = canonicalize(reparsed);
    expect(twice).toBe(once);
  });
});
