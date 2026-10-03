import { createHash } from "node:crypto";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Explicit derivative build. assemble.mjs continues to reproduce the exact live
// baseline; this command does not change its manifest, fragments or hash pin.
const root = fileURLToPath(new URL("../", import.meta.url));
const manifest = JSON.parse(await readFile(path.join(root, "recovery-manifest.json"), "utf8"));
const chunks = [];
for (const entry of manifest.fragments) {
  const bytes = await readFile(path.join(root, entry.path));
  if (createHash("sha256").update(bytes).digest("hex") !== entry.sha256 || bytes.length !== entry.bytes) throw new Error(`Changed immutable fragment: ${entry.path}`);
  chunks.push(bytes);
}
const baseline = Buffer.concat(chunks);
if (baseline.length !== 775005 || createHash("sha256").update(baseline).digest("hex") !== "3f07a9f97e5948feec13b683735cec1f997cb0f265eceefab9e52247012befa2") throw new Error("Baseline mismatch");
let source = baseline.toString("utf8");
function replaceExactlyOnce(before, after) {
  if (source.split(before).length !== 2) throw new Error(`Derivative splice anchor changed: ${before}`);
  source = source.replace(before, () => after);
}
replaceExactlyOnce('    if (row.expires <= now) return fail("failed", "expired");',
  '    if (row.expires <= now) return fail("failed", "expired");\n    if (!await managedNotificationDeliveryAllowed(env, row, now)) return fail("cancelled", "notification_grant_inactive");');
replaceExactlyOnce('    const result = await sendApns({',
  '    if (!await managedNotificationDeliveryAllowed(env, row, nowSeconds())) return fail("cancelled", "notification_grant_inactive");\n    const result = await sendApns({');
replaceExactlyOnce('  await cleanupExpiredMaterial(env.DB, now);',
  '  await cleanupExpiredMaterial(env.DB, now);\n  await cleanupManagedNotificationMaterial(env.DB, now);');
// Preserve actual observation timestamps while budgeting managed coalesced
// admissions by dispatch time; the feature's owner row adds an atomic rate fence.
replaceExactlyOnce('const routineValues = input.routine ? [input.stateTimestamp, RELAY_LIMITS.routineLiveActivityIntervalSeconds] : [];',
  'const routineValues = input.routine ? [input.routineTimestamp ?? input.stateTimestamp, RELAY_LIMITS.routineLiveActivityIntervalSeconds] : [];');
// Legacy terminal replay must reconcile its existing delivery even after APNs
// ended the registration. This is a narrow derivative fix, not a baseline edit.
replaceExactlyOnce('  const activity = await getActivity(env.DB, tenant.tenant_id, input.activityId);\n  if (activity?.status !== "active"',
  `  const replayId = \`link-live-\${digestBase64Url(\`\${tenant.tenant_id}\\0\${input.deviceId}\\0\${input.activityId}\\0\${input.updateId}\`)}\`;
  const replay = await getDelivery(env.DB, tenant.tenant_id, replayId);
  if (replay) {
    if (replay.device_id !== input.deviceId || replay.activity_id !== input.activityId || replay.kind !== "live_activity" || replay.payload_hash !== digestHex(relayCanonicalJson(state))) throw new LoopdyLinkEnrollmentError("link_live_activity_conflict", "Live Activity replay conflicts");
    if (replay.state === "pending_enqueue") await enqueueWake(env, tenant.tenant_id, replayId, now);
    return { status: "duplicate", activityId: input.activityId, deliveryId: replayId };
  }
  const activity = await getActivity(env.DB, tenant.tenant_id, input.activityId);
  if (activity?.status !== "active"`);
const feature = await readFile(path.join(root, "src/managed-notifications.js"), "utf8");
replaceExactlyOnce('export {\n  LoopdyLinkEnrollment,',
  `${feature}\nexport {\n  ManagedLoopdyLinkEnrollment as LoopdyLinkEnrollment,`);
await mkdir(path.join(root, "dist"), { recursive: true });
await writeFile(path.join(root, "dist/worker-notifications.js"), source);
console.log(`Explicit notification derivative: ${Buffer.byteLength(source)} bytes; SHA256 ${createHash("sha256").update(source).digest("hex")}`);
