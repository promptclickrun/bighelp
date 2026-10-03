import { resolveAccessSession } from "./account-auth.js";
import { isV1DeviceKind, LoopdyLinkError, type PublicLinkDevice, type RegisterLinkDevice } from "./contracts.js";
import { registerDeviceDirectory, verifyDeviceRequest } from "./device-auth.js";
import {
  beginNotificationDeviceRevocation, completeNotificationDeviceRevocation, revokeNotificationGrants,
} from "./notification-grants.js";
import type { HTTPRouteContext } from "./http-route-context.js";
import { bearerToken, parseJSON, readBoundedBody, readJSONObject, requiredPositiveInteger, requiredString } from "./http-request.js";
import { json } from "./http-response.js";

interface DeviceRegistrationBody {
  deviceId: string;
  publicKeySPKI: string;
  role: RegisterLinkDevice["role"];
  kind: RegisterLinkDevice["kind"];
  encryptedName: string;
  revision: number;
}

export async function registerDevice({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const body = parseDeviceRegistration(await readJSONObject(request));
  const session = await resolveAccessSession(env.ACCOUNTS, bearerToken(request), now);
  const device = await env.USER_LINKS.getByName(session.accountCoordinate).registerDevice({
    deviceId: body.deviceId,
    publicKey: body.publicKeySPKI,
    role: body.role,
    kind: body.kind,
    encryptedName: body.encryptedName,
    revision: body.revision,
    createdAt: now,
  });
  // The per-account object owns the atomic enrollment cap. Do not publish
  // directory credentials until admission succeeds; retries are idempotent.
  await registerDeviceDirectory(env.ACCOUNTS, {
    accountCoordinate: session.accountCoordinate,
    deviceId: body.deviceId,
    publicKeySPKI: body.publicKeySPKI,
    authorizationEpoch: session.authorizationEpoch,
    createdAt: now,
  });
  return json({ version: 1, device }, 201);
}

export async function deliveryDiagnostics({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const verified = await verifyDeviceRequest(request, "", env.ACCOUNTS, now);
  const delivery = await env.USER_LINKS.getByName(verified.accountCoordinate).deliveryDiagnostics();
  return json({ version: 1, delivery });
}

export async function listDevices({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const verified = await verifyDeviceRequest(request, "", env.ACCOUNTS, now);
  const catalog = await env.USER_LINKS.getByName(verified.accountCoordinate).listDevices();
  // A persisted newer-runtime kind must not make older clients reject their
  // entire account catalog. Limit only this v1 projection; keep the device,
  // grants, routing, revocation and account deletion lifecycle untouched.
  const devices = catalog.devices.filter((device: PublicLinkDevice) => isV1DeviceKind(device.kind));
  return json({ version: 1, devices });
}

export async function renameDevice({ request, env, now }: HTTPRouteContext, deviceId: string): Promise<Response> {
  const rawBody = await readBoundedBody(request);
  const verified = await verifyDeviceRequest(request, rawBody, env.ACCOUNTS, now);
  const body = parseJSON(rawBody);
  const device = await env.USER_LINKS.getByName(verified.accountCoordinate).renameDevice({
    deviceId,
    expectedRevision: requiredPositiveInteger(body.expectedRevision, "expectedRevision"),
    encryptedName: requiredString(body.encryptedName, "encryptedName"),
  });
  return json({ version: 1, device });
}

export async function revokeDevice({ request, env, now }: HTTPRouteContext, deviceId: string): Promise<Response> {
  const rawBody = await readBoundedBody(request);
  const body = parseJSON(rawBody);
  const expectedRevision = requiredPositiveInteger(body.expectedRevision, "expectedRevision");
  const verified = await verifyDeviceRequest(request, rawBody, env.ACCOUNTS, now, {
    revocationRecovery: { deviceId, expectedRevision },
  });
  const stub = env.USER_LINKS.getByName(verified.accountCoordinate);
  // Fence every ordinary API in D1 before crossing into the owning object.
  // Only this device's exact prior-epoch signed DELETE can resume the
  // idempotent cleanup if any later boundary is interrupted.
  await beginNotificationDeviceRevocation(
    env, verified.accountCoordinate, deviceId, expectedRevision,
    verified.authorizationEpoch, now,
  );
  let device: PublicLinkDevice;
  try {
    device = await stub.revokeDevice({
      deviceId,
      expectedRevision,
      revokedAt: now,
    });
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error
      ? String((error as { code: unknown }).code) : "";
    if (["device_not_found", "stale_revision"].includes(code)) {
      throw new LoopdyLinkError(code, code === "device_not_found"
        ? "Device was not found" : "Device revision is stale");
    }
    throw error;
  }
  const notificationAuthorizationEpoch = device.authorizationEpoch - 1;
  await revokeNotificationGrants(env, verified.accountCoordinate, deviceId);
  const update = await env.ACCOUNTS.prepare(
    `UPDATE device_directory SET
       status = 'revoked', authorization_epoch = ?, revoked_at = ?
     WHERE device_id = ? AND account_coordinate = ? AND status = 'active'`,
  )
    .bind(device.authorizationEpoch, now, deviceId, verified.accountCoordinate)
    .run();
  if (update.meta.changes !== 1) {
    const directory = await env.ACCOUNTS.prepare(`SELECT status,authorization_epoch
      FROM device_directory WHERE device_id=? AND account_coordinate=?`)
      .bind(deviceId, verified.accountCoordinate)
      .first<{ status: string; authorization_epoch: number }>();
    if (directory?.status !== "revoked"
        || directory.authorization_epoch !== notificationAuthorizationEpoch + 1) {
      throw new LoopdyLinkError("device_conflict", "Device revocation was not confirmed");
    }
  }
  await completeNotificationDeviceRevocation(
    env, verified.accountCoordinate, deviceId, expectedRevision, notificationAuthorizationEpoch,
  );
  return json({ version: 1, device });
}

function parseDeviceRegistration(body: Record<string, unknown>): DeviceRegistrationBody {
  const revision = requiredPositiveInteger(body.revision, "revision");
  if (revision !== 1) {
    throw new LoopdyLinkError("device_invalid", "New device revision must be 1");
  }
  return {
    deviceId: requiredString(body.deviceId, "deviceId"),
    publicKeySPKI: requiredString(body.publicKeySPKI, "publicKeySPKI"),
    role: body.role as RegisterLinkDevice["role"],
    kind: body.kind as RegisterLinkDevice["kind"],
    encryptedName: requiredString(body.encryptedName, "encryptedName"),
    revision,
  };
}
