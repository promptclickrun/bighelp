import { type LinkDeviceRole, LoopdyLinkError } from "./contracts.js";

export interface LinkSocketAttachment {
  version: 1;
  deviceId: string;
  role: LinkDeviceRole;
  authorizationEpoch: number;
  hostGrant: string | null;
  lastAcknowledgedSequence: number;
  // Missing v1 additions mean unsupported / zero on pre-upgrade sockets.
  backpressureV1?: boolean;
  directedFramesV1?: boolean;
  deliveryCursor?: number;
  stateBackedPresentationV1?: boolean;
  // Fences the metadata-only live receipt window from replaced connections.
  presentationConnectionId?: string;
}

const DEVICE_ID = /^[A-Za-z0-9_-]{1,96}$/;

export function parseSocketAttachment(value: unknown): LinkSocketAttachment {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new LoopdyLinkError("socket_attachment_invalid", "Socket attachment is invalid");
  }
  const attachment = value as Record<string, unknown>;
  if (
    attachment.version !== 1 ||
    typeof attachment.deviceId !== "string" ||
    !DEVICE_ID.test(attachment.deviceId) ||
    (attachment.role !== "mobile" && attachment.role !== "host") ||
    !Number.isSafeInteger(attachment.authorizationEpoch) ||
    Number(attachment.authorizationEpoch) < 1 ||
    !Number.isSafeInteger(attachment.lastAcknowledgedSequence) ||
    Number(attachment.lastAcknowledgedSequence) < 0 ||
    (attachment.backpressureV1 !== undefined && typeof attachment.backpressureV1 !== "boolean") ||
    (attachment.directedFramesV1 !== undefined && typeof attachment.directedFramesV1 !== "boolean") ||
    (attachment.stateBackedPresentationV1 !== undefined && typeof attachment.stateBackedPresentationV1 !== "boolean") ||
    (attachment.presentationConnectionId !== undefined &&
      (typeof attachment.presentationConnectionId !== "string" || !DEVICE_ID.test(attachment.presentationConnectionId))) ||
    (attachment.deliveryCursor !== undefined &&
      (!Number.isSafeInteger(attachment.deliveryCursor) || Number(attachment.deliveryCursor) < 0)) ||
    !(
      attachment.hostGrant === null ||
      (typeof attachment.hostGrant === "string" && DEVICE_ID.test(attachment.hostGrant))
    )
  ) {
    throw new LoopdyLinkError("socket_attachment_invalid", "Socket attachment is invalid");
  }
  return {
    version: 1,
    deviceId: attachment.deviceId,
    role: attachment.role,
    authorizationEpoch: Number(attachment.authorizationEpoch),
    hostGrant: attachment.hostGrant,
    lastAcknowledgedSequence: Number(attachment.lastAcknowledgedSequence),
    ...(attachment.backpressureV1 === undefined ? {} : { backpressureV1: attachment.backpressureV1 as boolean }),
    ...(attachment.directedFramesV1 === undefined ? {} : { directedFramesV1: attachment.directedFramesV1 as boolean }),
    ...(attachment.deliveryCursor === undefined ? {} : { deliveryCursor: Number(attachment.deliveryCursor) }),
    ...(attachment.stateBackedPresentationV1 === undefined ? {} : { stateBackedPresentationV1: attachment.stateBackedPresentationV1 as boolean }),
    ...(attachment.presentationConnectionId === undefined ? {} : { presentationConnectionId: attachment.presentationConnectionId as string }),
  };
}
