/**
 * Mesh-membership types — pi-remote side. Mirrors the wire shape defined
 * in plan/24-mesh-membership.md and must stay bit-compatible with the Dart
 * (app) and Rust (relay) implementations of the same protocol.
 *
 * On the wire, JSON field names are `snake_case` (per the plan); this module
 * exposes `camelCase` for ergonomic TS use. Conversion happens at the
 * (de)serialization boundary in `verify.ts` / `canonical.ts`.
 */
export {};
//# sourceMappingURL=types.js.map