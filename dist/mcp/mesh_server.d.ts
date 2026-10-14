#!/usr/bin/env node
/**
 * MCP server that bridges Claude Code to the remote-pi agent mesh.
 *
 * Spawned by Claude Code as an MCP server subprocess (stdio).
 * Joins the mesh through the shared `MeshNode` abstraction — the SAME
 * composition the Pi extension uses — so Claude is a first-class mesh
 * participant: it can lead the local UDS broker when no Pi/daemon is up,
 * and (as leader) bring up its own cross-PC relay bridge with its own
 * Pi-key. As a follower it rides the existing leader's bridge.
 *
 * Launched by `remote-pi claude` (registers this in Claude's local MCP
 * scope). Args: [--cwd <path>] [--name <agentName>] [--no-bridge]
 * Env: REMOTE_PI_MCP_CWD, REMOTE_PI_MCP_NAME
 */
export {};
