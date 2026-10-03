import { DEVICE_AUTH_HEADERS, lookupDeviceAccountCoordinate } from "./device-auth.js";
import { revokeNotificationInstallationGrants, handleNotificationRequest } from "./notification-grants.js";
import { handleNotificationIdentityRequest } from "./notification-identity.js";
import { BuzzKitBackendError } from "./buzzkit.js";
import type { LinkEnv } from "./user-link.js";
import type { HTTPRouteContext } from "./http-route-context.js";
import { HTTPError, errorResponse, json, notFound } from "./http-response.js";
import {
  registrationOptions, registrationVerify, authenticationOptions, authenticationVerify,
  storeKeyEnvelope, loadKeyEnvelope, loadProfile, saveProfile,
} from "./http-accounts.js";
import { beginPairing, inspectPairing, approvePairing, claimPairing } from "./http-pairing.js";
import { registerDevice, deliveryDiagnostics, listDevices, renameDevice, revokeDevice } from "./http-devices.js";
import { deleteCurrentAccount } from "./account-deletion.js";

// Method mismatches on ordinary Link routes remain 404, not 405. Notification
// identity/grant handlers retain their own method and error policies and run first.
const ROUTES = new Map<string, (context: HTTPRouteContext) => Promise<Response>>([
  ["GET /.well-known/apple-app-site-association", appleAssociation],
  ["GET /health", health],
  ["POST /v1/pairing/challenges", beginPairing],
  ["POST /v1/pairing/challenges/inspect", inspectPairing],
  ["POST /v1/accounts/registration/options", registrationOptions],
  ["POST /v1/accounts/registration/verify", registrationVerify],
  ["POST /v1/accounts/authentication/options", authenticationOptions],
  ["POST /v1/accounts/authentication/verify", authenticationVerify],
  ["PUT /v1/accounts/key-envelope", storeKeyEnvelope],
  ["GET /v1/accounts/key-envelope", loadKeyEnvelope],
  ["GET /v1/accounts/profile", loadProfile],
  ["PUT /v1/accounts/profile", saveProfile],
  ["DELETE /v1/accounts/current", deleteCurrentAccount],
  ["POST /v1/devices", registerDevice],
  ["GET /v1/delivery/diagnostics", deliveryDiagnostics],
  ["GET /v1/devices", listDevices],
]);
const PARAMETER_ROUTES = [
  { method: "POST", path: /^\/v1\/pairing\/challenges\/([A-Za-z0-9_-]{22,96})\/approve$/, handle: approvePairing },
  { method: "POST", path: /^\/v1\/pairing\/challenges\/([A-Za-z0-9_-]{22,96})\/claim$/, handle: claimPairing },
  { method: "PATCH", path: /^\/v1\/devices\/([A-Za-z0-9_-]{1,96})\/name$/, handle: renameDevice },
  { method: "DELETE", path: /^\/v1\/devices\/([A-Za-z0-9_-]{1,96})$/, handle: revokeDevice },
] as const;

export async function handleLoopdyLinkRequest(request: Request, env: LinkEnv): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (url.protocol !== "https:") {
      throw new HTTPError(400, "https_required", "Loopdy Link requires HTTPS");
    }
    const now = Math.floor(Date.now() / 1_000);
    if (url.search || url.hash) return notFound();
    const notificationIdentityResponse = await handleNotificationIdentityRequest(
      request,
      env,
      now,
      async (principal) => {
        try {
          await revokeNotificationInstallationGrants(
            env,
            principal.ownerCoordinate,
            principal.credentialId,
          );
        } catch (error) {
          if (error instanceof BuzzKitBackendError) {
            throw new HTTPError(
              503,
              "notification_cleanup_unavailable",
              "Notification provider cleanup was not confirmed. Try revocation again.",
            );
          }
          throw error;
        }
      },
    );
    if (notificationIdentityResponse) return notificationIdentityResponse;
    const notificationResponse = await handleNotificationRequest(request, env, now);
    if (notificationResponse) return notificationResponse;

    // Forward the handshake directly, preserving both Request identity and the
    // original fetch rejection behavior rather than awaiting it in a JSON route.
    if (request.method === "GET" && url.pathname === "/v1/socket") {
      if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        throw new HTTPError(426, "socket_upgrade_required", "WebSocket upgrade is required");
      }
      // Resolve the per-user Durable Object from the device directory only.
      // The original Request must cross this boundary unchanged so Cloudflare
      // can keep the complete WebSocket handshake associated with the outer
      // connection. UserLink performs the device signature, epoch, and nonce
      // verification before accepting the socket.
      const deviceId = request.headers.get(DEVICE_AUTH_HEADERS.deviceId) ?? "";
      const accountCoordinate = await lookupDeviceAccountCoordinate(env.ACCOUNTS, deviceId);
      return env.USER_LINKS.getByName(accountCoordinate).fetch(request);
    }

    const context = { request, env, now };
    const handler = ROUTES.get(`${request.method} ${url.pathname}`);
    if (handler) return await handler(context);
    for (const route of PARAMETER_ROUTES) {
      if (request.method !== route.method) continue;
      const match = route.path.exec(url.pathname);
      if (match) return await route.handle(context, match[1]!);
    }
    return notFound();
  } catch (error) {
    return errorResponse(error);
  }
}

async function appleAssociation({ env }: HTTPRouteContext): Promise<Response> {
  const appID = String(env.APPLE_APP_ID ?? "").trim();
  if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]{3,255}$/.test(appID)) {
    throw new HTTPError(
      503,
      "associated_domains_unavailable",
      "Loopdy Link passkey association is unavailable",
    );
  }
  return json({ webcredentials: { apps: [appID] } });
}

async function health(): Promise<Response> {
  return json({ version: 1, service: "loopdy-link", status: "ok" });
}
