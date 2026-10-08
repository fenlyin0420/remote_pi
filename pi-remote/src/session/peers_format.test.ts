import { describe, expect, test } from "vitest";
import { formatPeerInventory } from "./peer_inventory.js";

/**
 * Pure-function tests for the `/remote-pi peers` output formatter (plan/25
 * Wave D). The formatter is exported from `index.ts` so it can be exercised
 * without booting the full extension.
 */

describe("formatPeerInventory", () => {
  test("locals only → renders `local:` block with sorted entries", () => {
    const out = formatPeerInventory(["agent-2", "sess-1"], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    agent-2",
        "    sess-1",
      ].join("\n"),
    );
  });

  test("excludes self from local list", () => {
    const out = formatPeerInventory(["orq", "agent-1"], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    agent-1",
      ].join("\n"),
    );
  });

  test("0 locals (excluding self) → renders `(none)` placeholder", () => {
    const out = formatPeerInventory(["orq"], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    (none)",
      ].join("\n"),
    );
  });

  test("locals + 2 remote PCs → grouped sections sorted by pc_label", () => {
    const out = formatPeerInventory([
      "agent-1",
      "trab:worker",
      "casa:sess-3",
      "casa:agent-1",
      "orq",
    ], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    agent-1",
        "",
        "  remote:casa",
        "    agent-1",
        "    sess-3",
        "",
        "  remote:trab",
        "    worker",
      ].join("\n"),
    );
  });

  test("remotes only (no locals besides self) → `(none)` for locals, then remote sections", () => {
    const out = formatPeerInventory(["orq", "casa:sess-3"], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    (none)",
        "",
        "  remote:casa",
        "    sess-3",
      ].join("\n"),
    );
  });

  test("entry with literal `:` but invalid prefix (empty side) stays in local", () => {
    // Defensive: ":foo" or "foo:" should not be classified as remote.
    const out = formatPeerInventory([":weird", "weird:", "real"], "orq");
    expect(out).toBe(
      [
        "  local:",
        "    :weird",
        "    real",
        "    weird:",
      ].join("\n"),
    );
  });
});
