import type { PeerInfo } from "./broker.js";
/** Shared wire limits measured in JavaScript UTF-16 code units (`.length`). */
export declare const MAX_PEERS_UPDATE_ENTRIES = 1024;
export declare const MAX_CWD_LENGTH = 4096;
export declare const MAX_NAME_LENGTH = 256;
export declare const MAX_ADDRESS_LENGTH = 4352;
export declare function isBoundedPeerInfo(value: unknown): value is PeerInfo;
export declare function isBoundedPeerRoster(infos: readonly PeerInfo[]): boolean;
export declare function isBoundedPeerAddresses(addresses: readonly unknown[]): boolean;
