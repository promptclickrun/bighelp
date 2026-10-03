// src/crypto.ts
function currentStorageKeyVersion(keys) {
  const versions = Object.keys(keys).filter((version2) => /^v[1-9][0-9]{0,2}$/.test(version2));
  if (versions.length === 0) throw new Error("Storage key registry is empty");
  versions.sort((left, right) => Number(left.slice(1)) - Number(right.slice(1)));
  return versions[versions.length - 1];
}
__name(currentStorageKeyVersion, "currentStorageKeyVersion");
function bytes2(value) {
  return relayBase64UrlDecode(value);
}
__name(bytes2, "bytes");
async function importStorageKey(key, usages) {
  const decoded = bytes2(key);
  if (decoded.byteLength !== 32) throw new Error("Invalid AES-256 storage key length");
  return crypto.subtle.importKey("raw", decoded, "AES-GCM", false, usages);
}
__name(importStorageKey, "importStorageKey");
async function encryptAtRest(keyVersion, plaintext, keys, randomBytes = (length) => crypto.getRandomValues(new Uint8Array(length))) {
  const encodedKey = keys[keyVersion];
  if (!encodedKey) throw new Error("Storage key version is unavailable");
  const nonce = randomBytes(12);
  if (nonce.byteLength !== 12) throw new Error("Storage nonce must be 12 bytes");
  const key = await importStorageKey(encodedKey, ["encrypt"]);
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, plaintext);
  return {
    keyVersion,
    nonce: relayBase64UrlEncode(nonce),
    ciphertext: relayBase64UrlEncode(new Uint8Array(encrypted))
  };
}
__name(encryptAtRest, "encryptAtRest");
async function decryptAtRest(value, keys) {
  const encodedKey = keys[value.keyVersion];
  if (!encodedKey) throw new Error("Storage key version is unavailable");
  const nonce = bytes2(value.nonce);
  const ciphertext = bytes2(value.ciphertext);
  if (nonce.byteLength !== 12 || ciphertext.byteLength < 17)
    throw new Error("Stored ciphertext is invalid");
  const key = await importStorageKey(encodedKey, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: nonce }, key, ciphertext);
  return new Uint8Array(plaintext);
}
__name(decryptAtRest, "decryptAtRest");
function parseStorageKeys(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Storage key registry is invalid");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    throw new Error("Storage key registry is invalid");
  const result = {};
  for (const [version2, value] of Object.entries(parsed)) {
    if (!/^v[1-9][0-9]{0,2}$/.test(version2) || typeof value !== "string")
      throw new Error("Storage key registry is invalid");
    try {
      const decoded = bytes2(value);
      if (decoded.byteLength !== 32) throw new Error("length");
    } catch {
      throw new Error("Storage key registry is invalid");
    }
    result[version2] = value;
  }
  if (Object.keys(result).length === 0) throw new Error("Storage key registry is invalid");
  return result;
}
__name(parseStorageKeys, "parseStorageKeys");
function publicKeyJwk(publicKey2) {
  if (publicKey2.byteLength !== 65 || publicKey2[0] !== 4)
    throw new Error("Invalid P-256 public key");
  return {
    kty: "EC",
    crv: "P-256",
    x: relayBase64UrlEncode(publicKey2.slice(1, 33)),
    y: relayBase64UrlEncode(publicKey2.slice(33, 65))
  };
}
__name(publicKeyJwk, "publicKeyJwk");
async function verifyPluginEnvelope(envelope, senderPublicKey, coordinates) {
  const senderBytes = relayBase64UrlDecode(senderPublicKey);
  const senderKeyId = relayKeyId(senderBytes);
  if (envelope.sender_key_id !== senderKeyId)
    throw new Error("Envelope sender key is not configured");
  const eventRef = String(envelope.event_ref);
  const recipientKeyId = String(envelope.recipient_key_id);
  const deliveryId = String(envelope.delivery_id);
  const issued = Number(envelope.issued);
  const expires = Number(envelope.expires);
  const aad = relayAlertAad({
    tenantId: coordinates.tenantId,
    deviceId: coordinates.deviceId,
    deliveryId,
    eventRef,
    recipientKeyId,
    senderKeyId,
    issued,
    expires
  });
  const signatureInput = relayAlertSignatureInput({
    aad,
    ephemeralPublicKey: relayBase64UrlDecode(String(envelope.ephemeral_public_key)),
    salt: relayBase64UrlDecode(String(envelope.salt)),
    nonce: relayBase64UrlDecode(String(envelope.nonce)),
    ciphertext: relayBase64UrlDecode(String(envelope.ciphertext)),
    tag: relayBase64UrlDecode(String(envelope.tag))
  });
  const signature = relayBase64UrlDecode(String(envelope.signature));
  if (signature.byteLength !== 64) throw new Error("Envelope signature is invalid");
  const key = await crypto.subtle.importKey(
    "jwk",
    publicKeyJwk(senderBytes),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"]
  );
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    signatureInput
  );
  if (!valid) throw new Error("Envelope signature is invalid");
  return { senderKeyId };
}
__name(verifyPluginEnvelope, "verifyPluginEnvelope");

