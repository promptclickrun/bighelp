import {
  approvePairingChallenge, beginPairingChallenge, claimPairingChallenge, inspectPairingChallenge,
} from "./pairing.js";
import { registerDeviceDirectory, verifyDeviceRequest } from "./device-auth.js";
import type { PublicLinkDevice } from "./contracts.js";
import type { HTTPRouteContext } from "./http-route-context.js";
import { parseJSON, readBoundedBody, readJSONObject, requiredPositiveInteger, requiredString } from "./http-request.js";
import { HTTPError, json } from "./http-response.js";

export async function beginPairing({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const body = await readJSONObject(request);
  const challenge = await beginPairingChallenge(
    env.ACCOUNTS,
    {
      deviceId: requiredString(body.deviceId, "deviceId"),
      signingPublicKeySPKI: requiredString(body.signingPublicKeySPKI, "signingPublicKeySPKI"),
      agreementPublicKey: requiredString(body.agreementPublicKey, "agreementPublicKey"),
      claimSecretHash: requiredString(body.claimSecretHash, "claimSecretHash"),
      timestamp: requiredPositiveInteger(body.timestamp, "timestamp"),
      nonce: requiredString(body.nonce, "nonce"),
      proof: requiredString(body.proof, "proof"),
    },
    now,
  );
  return json({ version: 1, ...challenge }, 201);
}

export async function inspectPairing({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const rawBody = await readBoundedBody(request);
  await verifyDeviceRequest(request, rawBody, env.ACCOUNTS, now);
  const body = parseJSON(rawBody);
  const flowId = body.flowId;
  if (flowId !== undefined && typeof flowId !== "string") {
    throw new HTTPError(400, "request_invalid", "flowId is invalid");
  }
  const inspection = await inspectPairingChallenge(
    env.ACCOUNTS,
    {
      ...(typeof flowId === "string" ? { flowId } : {}),
      code: requiredString(body.code, "code"),
    },
    now,
  );
  return json({ version: 1, ...inspection });
}

export async function approvePairing({ request, env, now }: HTTPRouteContext, flowId: string): Promise<Response> {
  const rawBody = await readBoundedBody(request);
  const verified = await verifyDeviceRequest(request, rawBody, env.ACCOUNTS, now);
  const body = parseJSON(rawBody);
  let device: PublicLinkDevice | undefined;
  await approvePairingChallenge(
    env.ACCOUNTS,
    {
      flowId,
      code: requiredString(body.code, "code"),
      accountCoordinate: verified.accountCoordinate,
      authorizationEpoch: verified.authorizationEpoch,
      encryptedName: requiredString(body.encryptedName, "encryptedName"),
      grantEnvelope: requiredString(body.grantEnvelope, "grantEnvelope"),
    },
    now,
    async (approval) => {
      device = await env.USER_LINKS.getByName(verified.accountCoordinate).registerDevice({
        deviceId: approval.deviceId,
        publicKey: approval.signingPublicKeySPKI,
        role: "host",
        kind: "hermes_host",
        encryptedName: approval.encryptedName,
        revision: 1,
        createdAt: now,
      });
      await registerDeviceDirectory(env.ACCOUNTS, {
        accountCoordinate: verified.accountCoordinate,
        deviceId: approval.deviceId,
        publicKeySPKI: approval.signingPublicKeySPKI,
        authorizationEpoch: approval.authorizationEpoch,
        createdAt: now,
      });
    },
  );
  if (!device) throw new HTTPError(503, "device_unavailable", "Device registration was not confirmed");
  return json({ version: 1, state: "approved", device });
}

export async function claimPairing({ request, env, now }: HTTPRouteContext, flowId: string): Promise<Response> {
  const body = await readJSONObject(request);
  const claim = await claimPairingChallenge(
    env.ACCOUNTS,
    {
      flowId,
      claimSecret: requiredString(body.claimSecret, "claimSecret"),
      timestamp: requiredPositiveInteger(body.timestamp, "timestamp"),
      nonce: requiredString(body.nonce, "nonce"),
      proof: requiredString(body.proof, "proof"),
    },
    now,
  );
  return json({
    version: 1,
    state: "claimed",
    deviceId: claim.deviceId,
    authorizationEpoch: claim.authorizationEpoch,
    grantEnvelope: claim.grantEnvelope,
    socketPath: "/v1/socket",
  });
}
