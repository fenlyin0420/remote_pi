import type { Broker } from "./broker.js";
import { BrokerRemote } from "./broker_remote.js";
import { PiForwardClient } from "../transport/pi_forward_client.js";
import type { RelayClient } from "../transport/relay_client.js";
import { type MeshTopologySnapshot } from "../mesh/siblings.js";
import type { Ed25519Keypair } from "../pairing/crypto.js";
/**
 * Cross-PC mesh bridge composition. Discovery finishes before either transport
 * half is constructed, and the returned bridge stays dormant until its caller
 * has re-checked lifecycle ownership and calls `activate()`.
 */
export interface AttachBridgeOptions {
    /** The leader's local Broker (from SessionPeer.localBroker()). */
    broker: Broker;
    /** Live relay connection. Caller owns its lifecycle. */
    relay: RelayClient;
    /** Relay URL in http(s):// form — for standalone topology discovery. */
    relayUrl: string;
    /** This host's Ed25519 identity (machine Pi-key). */
    keypair: Ed25519Keypair;
    /** Retained Pi-produced topology. Supplying it bypasses discovery. */
    topology?: MeshTopologySnapshot;
    /** Standalone discovery deadline per mesh request. Defaults to 5 seconds. */
    meshRequestTimeoutMs?: number;
    /** Diagnostic logger. Defaults to a no-op (avoids TUI leaks). */
    log?: (msg: string) => void;
}
export interface CrossPcBridge {
    brokerRemote: BrokerRemote;
    piForward: PiForwardClient;
    topology: MeshTopologySnapshot;
    /** Publish the already-built router exactly once. */
    activate(): void;
    /** Safe before or after activation; tears down both halves exactly once. */
    detach(): void;
}
export declare function attachCrossPcBridge(opts: AttachBridgeOptions): Promise<CrossPcBridge>;
