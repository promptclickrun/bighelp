export const LINK_LIMITS = {
  deviceIdCharacters: 96,
  publicKeyCharacters: 2_048,
  encryptedNameCharacters: 4_096,
  encryptedProfileDisplayNameCharacters: 4_096,
  encryptedProfileAvatarCharacters: 2_800_000,
  profileAvatarBytes: 2_000_000,
  listDevices: 128,
} as const;

export type LinkDeviceRole = "mobile" | "host";
// Existing version-1 clients decode this finite catalog strictly. New runtime
// kinds must negotiate client support before appearing in their device list.
export const V1_DEVICE_KINDS = ["phone", "tablet", "computer", "hermes_host"] as const;
export type LinkDeviceKind = typeof V1_DEVICE_KINDS[number];

export function isV1DeviceKind(value: unknown): value is LinkDeviceKind {
  return (V1_DEVICE_KINDS as readonly unknown[]).includes(value);
}
export type LinkDeviceLifecycle = "active" | "revoked";
export type LinkConnectionState = "online" | "recent" | "offline";
export type LinkPushState =
  | "permission_required"
  | "registering"
  | "ready"
  | "denied"
  | "retrying"
  | "unavailable"
  | "revoked";

export interface RegisterLinkDevice {
  deviceId: string;
  publicKey: string;
  role: LinkDeviceRole;
  kind: LinkDeviceKind;
  encryptedName: string;
  revision: number;
  createdAt: number;
}

export interface RenameLinkDevice {
  deviceId: string;
  expectedRevision: number;
  encryptedName: string;
}

export interface RevokeLinkDevice {
  deviceId: string;
  expectedRevision: number;
  revokedAt: number;
}

export interface AccountProfileAvatar {
  mimeType: "image/png" | "image/jpeg" | "image/webp";
  byteCount: number;
  sha256: string;
  encryptedData: string;
}

export interface SaveAccountProfile {
  expectedRevision: number;
  encryptedDisplayName: string;
  avatar: AccountProfileAvatar | null;
  updatedAt: number;
}

export interface PublicAccountProfile {
  revision: number;
  encryptedDisplayName: string;
  avatar: AccountProfileAvatar | null;
  updatedAt: number;
}

export interface PublicLinkDevice {
  deviceId: string;
  encryptedName: string;
  role: LinkDeviceRole;
  kind: LinkDeviceKind;
  lifecycle: LinkDeviceLifecycle;
  revision: number;
  authorizationEpoch: number;
  connection: LinkConnectionState;
  pushState: LinkPushState | null;
  pushRevision: number;
  createdAt: number;
  revokedAt: number | null;
  lastSeenBucket: number | null;
}

export interface PublicLinkDeviceList {
  devices: PublicLinkDevice[];
}

export class LoopdyLinkError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "LoopdyLinkError";
    this.code = code;
  }
}

const OPAQUE_ID = /^[A-Za-z0-9_-]+$/;

export function parseRegisterLinkDevice(value: RegisterLinkDevice): RegisterLinkDevice {
  const deviceId = opaqueId(value.deviceId, "deviceId");
  const publicKey = boundedString(
    value.publicKey,
    "publicKey",
    16,
    LINK_LIMITS.publicKeyCharacters,
  );
  const encryptedName = boundedString(
    value.encryptedName,
    "encryptedName",
    1,
    LINK_LIMITS.encryptedNameCharacters,
  );
  if (value.role !== "mobile" && value.role !== "host") {
    throw new LoopdyLinkError("invalid_device", "Device role is invalid");
  }
  if (!isV1DeviceKind(value.kind)) {
    throw new LoopdyLinkError("invalid_device", "Device kind is invalid");
  }
  if (value.role === "host" && value.kind !== "hermes_host") {
    throw new LoopdyLinkError("invalid_device", "Host kind is invalid");
  }
  positiveInteger(value.revision, "revision");
  positiveInteger(value.createdAt, "createdAt");
  return { ...value, deviceId, publicKey, encryptedName };
}

export function parseRenameLinkDevice(value: RenameLinkDevice): RenameLinkDevice {
  return {
    deviceId: opaqueId(value.deviceId, "deviceId"),
    expectedRevision: positiveInteger(value.expectedRevision, "expectedRevision"),
    encryptedName: boundedString(
      value.encryptedName,
      "encryptedName",
      1,
      LINK_LIMITS.encryptedNameCharacters,
    ),
  };
}

export function parseRevokeLinkDevice(value: RevokeLinkDevice): RevokeLinkDevice {
  return {
    deviceId: opaqueId(value.deviceId, "deviceId"),
    expectedRevision: positiveInteger(value.expectedRevision, "expectedRevision"),
    revokedAt: positiveInteger(value.revokedAt, "revokedAt"),
  };
}

export function parseSaveAccountProfile(value: SaveAccountProfile): SaveAccountProfile {
  return {
    expectedRevision: nonnegativeInteger(value.expectedRevision, "expectedRevision"),
    encryptedDisplayName: boundedString(
      value.encryptedDisplayName,
      "encryptedDisplayName",
      1,
      LINK_LIMITS.encryptedProfileDisplayNameCharacters,
    ),
    avatar: value.avatar === null ? null : parseAccountProfileAvatar(value.avatar),
    updatedAt: positiveInteger(value.updatedAt, "updatedAt"),
  };
}

function parseAccountProfileAvatar(value: AccountProfileAvatar): AccountProfileAvatar {
  if (!value || typeof value !== "object") {
    throw new LoopdyLinkError("invalid_account_profile", "Profile avatar is invalid");
  }
  if (!(["image/png", "image/jpeg", "image/webp"] as unknown[]).includes(value.mimeType)) {
    throw new LoopdyLinkError("invalid_account_profile", "Profile avatar MIME type is invalid");
  }
  const byteCount = positiveInteger(value.byteCount, "byteCount");
  if (byteCount > LINK_LIMITS.profileAvatarBytes) {
    throw new LoopdyLinkError("invalid_account_profile", "Profile avatar is too large");
  }
  const sha256 = boundedString(value.sha256, "sha256", 16, 128);
  const encryptedData = boundedString(
    value.encryptedData,
    "encryptedData",
    16,
    LINK_LIMITS.encryptedProfileAvatarCharacters,
  );
  return { mimeType: value.mimeType, byteCount, sha256, encryptedData };
}

function opaqueId(value: unknown, field: string): string {
  const parsed = boundedString(value, field, 1, LINK_LIMITS.deviceIdCharacters);
  if (!OPAQUE_ID.test(parsed)) {
    throw new LoopdyLinkError("invalid_device", `${field} is invalid`);
  }
  return parsed;
}

function boundedString(value: unknown, field: string, minimum: number, maximum: number): string {
  if (typeof value !== "string" || value.length < minimum || value.length > maximum) {
    throw new LoopdyLinkError("invalid_device", `${field} is invalid`);
  }
  return value;
}

function nonnegativeInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 0) {
    throw new LoopdyLinkError("invalid_device", `${field} is invalid`);
  }
  return Number(value);
}

function positiveInteger(value: unknown, field: string): number {
  if (!Number.isSafeInteger(value) || Number(value) < 1) {
    throw new LoopdyLinkError("invalid_device", `${field} is invalid`);
  }
  return Number(value);
}
