import type { AckResult } from "../session/peer.js";
type MeshAckResult = {
    content: [{
        type: "text";
        text: string;
    }];
    isError?: true;
};
export declare function formatMeshAckResult(to: string, ack: AckResult): MeshAckResult;
export {};
