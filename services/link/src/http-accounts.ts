import {
  beginAccountAuthentication, beginAccountRegistration,
  completeAccountAuthentication, completeAccountRegistration,
  loadAccountKeyEnvelope, storeAccountKeyEnvelope, type LoopdyPasskeyConfiguration,
} from "./account-auth.js";
import { verifyDeviceRequest } from "./device-auth.js";
import type { LinkEnv } from "./user-link.js";
import type { HTTPRouteContext } from "./http-route-context.js";
import {
  bearerToken, MAX_PROFILE_BODY_CHARACTERS, parseJSON, readBoundedBody, readJSONObject,
  requiredNonnegativeInteger, requiredPositiveInteger, requiredString,
} from "./http-request.js";
import { json } from "./http-response.js";

export const registrationOptions = passkeyOptions(beginAccountRegistration);
export const authenticationOptions = passkeyOptions(beginAccountAuthentication);
export const registrationVerify = passkeyVerify(completeAccountRegistration);
export const authenticationVerify = passkeyVerify(completeAccountAuthentication);

function passkeyOptions(begin: typeof beginAccountRegistration | typeof beginAccountAuthentication) {
  return async ({ request, env, now }: HTTPRouteContext): Promise<Response> => {
    await readJSONObject(request);
    const started = await begin(env.ACCOUNTS, passkeyConfiguration(env), now);
    return json({ version: 1, ...started });
  };
}

function passkeyVerify(complete: typeof completeAccountRegistration | typeof completeAccountAuthentication) {
  return async ({ request, env, now }: HTTPRouteContext): Promise<Response> => {
    const body = await readJSONObject(request);
    const session = await complete(
      env.ACCOUNTS,
      passkeyConfiguration(env),
      { flowId: requiredString(body.flowId, "flowId"), response: body.response },
      now,
    );
    return json({ version: 1, session });
  };
}

export async function storeKeyEnvelope({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const body = await readJSONObject(request);
  await storeAccountKeyEnvelope(
    env.ACCOUNTS,
    bearerToken(request),
    requiredString(body.envelope, "envelope"),
    now,
  );
  return json({ version: 1, state: "ready" });
}

export async function loadKeyEnvelope({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const envelope = await loadAccountKeyEnvelope(env.ACCOUNTS, bearerToken(request), now);
  return json({ version: 1, envelope });
}

export async function loadProfile({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const verified = await verifyDeviceRequest(request, "", env.ACCOUNTS, now);
  const profile = await env.USER_LINKS.getByName(verified.accountCoordinate).loadAccountProfile();
  return json({ version: 1, profile });
}

export async function saveProfile({ request, env, now }: HTTPRouteContext): Promise<Response> {
  const rawBody = await readBoundedBody(request, MAX_PROFILE_BODY_CHARACTERS);
  const verified = await verifyDeviceRequest(request, rawBody, env.ACCOUNTS, now, {
    maximumBodyCharacters: MAX_PROFILE_BODY_CHARACTERS,
  });
  const body = parseJSON(rawBody);
  const profile = await env.USER_LINKS.getByName(verified.accountCoordinate).saveAccountProfile({
    expectedRevision: requiredNonnegativeInteger(body.expectedRevision, "expectedRevision"),
    encryptedDisplayName: requiredString(body.encryptedDisplayName, "encryptedDisplayName"),
    avatar: body.avatar as never,
    updatedAt: requiredPositiveInteger(body.updatedAt, "updatedAt"),
  });
  return json({ version: 1, profile });
}

function passkeyConfiguration(env: LinkEnv): LoopdyPasskeyConfiguration {
  return {
    rpName: "Loopdy",
    rpID: env.PASSKEY_RP_ID,
    expectedOrigin: env.PASSKEY_ORIGIN,
    challengeTTLSeconds: 300,
    sessionTTLSeconds: 900,
  };
}
