import { LoopdyLinkError } from "./contracts.js";

export interface EncryptedLinkFrame {
  version: 1;
  type: "frame";
  id: string;
  senderDeviceId: string;
  senderEpoch: number;
  sequence: number;
  ack: number;
  ciphertext: string;
  targetDeviceId?: string;
  // Explicit host assertion, never inferred from opaque ciphertext. The relay
  // still retains a durable copy for receivers without the state-backed contract.
  deliveryClass?: "presentation";
}

export interface AcceptedLinkFrame {
  version: 1;
  type: "accepted";
  id: string;
  sequence: number;
}

export interface BackpressureLinkFrame {
  version: 1;
  type: "backpressure";
  id: string;
  sequence: number;
  retryAfterMs: 1000;
  reason: "storage_limit";
}

const FRAME_ID = /^[A-Za-z0-9_-]{16,128}$/;
const DEVICE_ID = /^[A-Za-z0-9_-]{1,96}$/;
const CIPHERTEXT = /^[A-Za-z0-9_-]{16,4000000}$/;
const MAX_CIPHERTEXT_CHARACTERS = 4_000_000;
const MAX_FRAME_CHARACTERS = 4_000_000;

export function parseEncryptedFrame(message: string): EncryptedLinkFrame {
  if (message.length > MAX_FRAME_CHARACTERS) {
    throw new LoopdyLinkError("frame_too_large", "Encrypted frame is too large");
  }
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    throw new LoopdyLinkError("frame_invalid", "Encrypted frame is invalid");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new LoopdyLinkError("frame_invalid", "Encrypted frame is invalid");
  }
  const frame = value as Record<string, unknown>;
  if (
    frame.version !== 1 ||
    frame.type !== "frame" ||
    typeof frame.id !== "string" ||
    !FRAME_ID.test(frame.id) ||
    typeof frame.senderDeviceId !== "string" ||
    !DEVICE_ID.test(frame.senderDeviceId) ||
    !positiveInteger(frame.senderEpoch) ||
    !positiveInteger(frame.sequence) ||
    !nonnegativeInteger(frame.ack) ||
    typeof frame.ciphertext !== "string" ||
    (frame.deliveryClass !== undefined && frame.deliveryClass !== "presentation") ||
    (frame.targetDeviceId !== undefined &&
      (typeof frame.targetDeviceId !== "string" || !DEVICE_ID.test(frame.targetDeviceId)))
  ) {
    throw new LoopdyLinkError("frame_invalid", "Encrypted frame is invalid");
  }
  if (frame.ciphertext.length > MAX_CIPHERTEXT_CHARACTERS) {
    throw new LoopdyLinkError("frame_too_large", "Encrypted frame is too large");
  }
  if (!CIPHERTEXT.test(frame.ciphertext)) {
    throw new LoopdyLinkError("frame_invalid", "Encrypted frame is invalid");
  }
  return {
    version: 1,
    type: "frame",
    id: frame.id,
    senderDeviceId: frame.senderDeviceId,
    senderEpoch: frame.senderEpoch,
    sequence: frame.sequence,
    ack: frame.ack,
    ciphertext: frame.ciphertext,
    ...(frame.targetDeviceId === undefined ? {} : { targetDeviceId: frame.targetDeviceId as string }),
    ...(frame.deliveryClass === undefined ? {} : { deliveryClass: "presentation" as const }),
  };
}

export function acceptedFrame(frame: EncryptedLinkFrame): AcceptedLinkFrame {
  return { version: 1, type: "accepted", id: frame.id, sequence: frame.sequence };
}

// Called only after parsing and authenticated sender/epoch/sequence validation.
export function backpressureFrame(frame: EncryptedLinkFrame): BackpressureLinkFrame {
  return {
    version: 1, type: "backpressure", id: frame.id, sequence: frame.sequence,
    retryAfterMs: 1000, reason: "storage_limit",
  };
}

function positiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

function nonnegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}
