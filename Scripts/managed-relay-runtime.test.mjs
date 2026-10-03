import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const require = createRequire(path.join(root,"services/link/package.json"));
const wr = createRequire(require.resolve("wrangler"));
const { Miniflare, convertV4MiniflareOptions } = wr("miniflare");
const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));

test("real relay binding queues encrypted alerts, rich updates and revocation fences", {timeout:60000}, async () => {
  const generated=spawnSync(process.env.HERMES_PYTHON || path.join(process.env.HOME,".hermes/hermes-agent/.venv/bin/python"),
    ["-B","services/relay/test/generate-fixture.py"],{cwd:root,encoding:"utf8",env:{...process.env,PYTHONPATH:path.join(root,"plugins/loopdy")}});
  assert.equal(generated.status,0,generated.stderr);
  const f=JSON.parse(generated.stdout);
  const delivered=[];
  const outbound=async request=>{
    assert.match(request.url,/^https:\/\/api\.sandbox\.push\.apple\.com\/3\/device\//);
    delivered.push({body:await request.json(),type:request.headers.get("apns-push-type"),id:request.headers.get("apns-id")});
    return new Response("",{status:200});
  };
  const proxy=`export default { async fetch(request,env) {
    const {method,input}=await request.json();
    const allowed=["enrollDevice","acknowledgeSenderKeys","notificationRecipient","putNotificationGrant","revokeNotificationGrant","sendNotificationEvent","registerNotificationActivity","updateNotificationActivity","notificationActivity","revokeNotificationActivity"];
    if(!allowed.includes(method)) return new Response("denied",{status:403});
    try { return Response.json(await env.RELAY[method](input)); }
    catch(error) { return Response.json({error:error.message},{status:409}); }
  }};`;
  const mf=new Miniflare(convertV4MiniflareOptions({host:"127.0.0.1",port:0,logRequests:false,workers:[
    {name:"entry",modules:true,script:proxy,compatibilityDate:"2026-08-28",serviceBindings:{RELAY:{name:"relay",entrypoint:"BighelpLinkEnrollment"}}},
    {name:"relay",modules:true,script:await readFile(path.join(root,"services/relay/dist/worker-notifications.js"),"utf8"),
      compatibilityDate:"2026-08-28",compatibilityFlags:["nodejs_compat"],
      d1Databases:{DB:"fixture-relay-database"},queueProducers:{DELIVERY_QUEUE:"fixture-relay-deliveries"},
      queueConsumers:{"fixture-relay-deliveries":{maxBatchSize:10,maxBatchTimeout:1,maxRetries:1,retryDelay:1}},outboundService:outbound,
      bindings:{LINK_RELAY_TENANT_ID:f.grant.tenantId,RELAY_TENANTS:JSON.stringify([{tenant_id:f.grant.tenantId,credential_key_id:"fixture-credential",hmac_key_b64url:f.hmac,sender_key_revision:1,current:f.legacyKey,previous:null,allowed_topics:["app.loopdy.fixture"]}]),
        STORAGE_ENCRYPTION_KEYS:JSON.stringify({v1:f.storage}),APNS_KEY_ID:"FIXTUREKEY",APNS_TEAM_ID:"FIXTURETEAM",APNS_PRIVATE_KEY:f.apnsPrivateKey}}
  ]}));
  try {
    await mf.ready;
    const db=await mf.getD1Database("DB","relay");
    const sql=await readFile(path.join(root,"services/relay/test/fixtures/deployed-schema.sql"),"utf8");
    // Defer FK enforcement while constructing an empty copy of the captured schema.
    for(const statement of sql.split(";").map(s=>s.trim()).filter(Boolean)) await db.prepare(statement).run();
    const entry=await mf.getWorker("entry");
    async function call(method,input,expected=200){
      const response=await entry.fetch("http://fixture.test/",{method:"POST",body:JSON.stringify({method,input})});
      const value=await response.json();
      assert.equal(response.status,expected,JSON.stringify(value));
      return value;
    }
    await call("enrollDevice",{deviceId:f.grant.deviceId,revision:1,pushToken:"ab".repeat(32),recipientPublicKey:f.grant.recipientPublicKey,
      recipientKeyId:f.grant.recipientKeyId,environment:"sandbox",topic:"app.loopdy.fixture"});
    await call("acknowledgeSenderKeys",{deviceId:f.grant.deviceId,revision:2,senderKeyRevision:1,acknowledgedSenderKeyIds:[f.legacyKey.key_id]});
    const recipient=await call("notificationRecipient",{deviceId:f.grant.deviceId});
    assert.equal(recipient.revision,2);
    await call("putNotificationGrant",f.grant);
    await call("sendNotificationEvent",{grant:f.grant,event:f.ungrantedApprovalEvent},409);
    await call("putNotificationGrant",{...f.grant,eventTypes:[...f.grant.eventTypes,"approval.required"]},409);
    const persistedGrant = await db.prepare("SELECT public_json FROM notification_grants WHERE grant_id=?").bind(f.grant.grantId).first();
    assert.deepEqual(JSON.parse(persistedGrant.public_json).eventTypes,f.grant.eventTypes);
    const accepted=await call("sendNotificationEvent",{grant:f.grant,event:f.events[0]});
    assert.equal(accepted.status,"accepted");
    assert.equal((await call("sendNotificationEvent",{grant:f.grant,event:f.events[0]})).status,"duplicate");
    async function waitFor(predicate,label){
      const deadline=Date.now()+10000;
      while(Date.now()<deadline){ if(await predicate())return; await sleep(50); }
      const states=await db.prepare("SELECT kind,state,last_error FROM deliveries").all();
      assert.fail(label+" "+JSON.stringify(states.results));
    }
    await waitFor(()=>delivered.length===1,"alert not delivered to test APNs");
    assert.deepEqual(delivered[0].body.loopdy.envelope,f.events[0].envelope);
    assert.equal(delivered[0].type,"alert");
    assert.equal(delivered[0].body.aps.sound,undefined);
    const activityId="activity-fixture";
    const sessionReference=f.events[0].sessionReference;
    const current=Math.floor(Date.now()/1000);
    await call("registerNotificationActivity",{grant:f.grant,activity:{deviceId:f.grant.deviceId,activityId,sessionReference,pushToken:"cd".repeat(32),environment:"sandbox",topic:"app.loopdy.fixture",revision:1,timestamp:current,leaseExpires:current+1000}});
    const update={updateId:"update_fixture_terminal",sessionReference,phase:"completed",currentAction:"Your agent finished",progress:100,completedSteps:0,activeSubagentCount:0,latestTool:null,timestamp:current,expires:current+120};
    await call("updateNotificationActivity",{grant:f.grant,activityId,update});
    await waitFor(()=>delivered.length===2,"rich terminal not delivered to test APNs");
    assert.equal(delivered[1].type,"liveactivity");
    assert.equal(delivered[1].body.aps.event,"end");
    assert.deepEqual(Object.keys(delivered[1].body.aps["content-state"]).sort(),["phase","currentAction","progress","completedSteps","activeSubagentCount","latestTool","timestamp"].sort());
    await waitFor(async()=> {
      const retired=await db.prepare("SELECT status,token_ciphertext FROM live_activities WHERE activity_id=?").bind(activityId).first();
      return retired.status==="revoked" && retired.token_ciphertext==="";
    },"terminal registration/token not retired");
    const cancelledActivityId="activity-cancelled";
    await call("registerNotificationActivity",{grant:f.grant,activity:{deviceId:f.grant.deviceId,activityId:cancelledActivityId,sessionReference,pushToken:"ef".repeat(32),environment:"sandbox",topic:"app.loopdy.fixture",revision:1,timestamp:current,leaseExpires:current+1000}});
    await call("updateNotificationActivity",{grant:f.grant,activityId:cancelledActivityId,update:{...update,updateId:"update_fixture_cancelled",currentAction:"Stopped"}});
    await waitFor(()=>delivered.length===3,"cancelled activity not ended");
    assert.equal(delivered[2].body.aps.event,"end");
    assert.equal(delivered[2].body.aps["content-state"].currentAction,"Stopped");
    assert.equal(delivered[2].body.aps.alert,undefined,"cancellation must not emit an alert");
    await call("sendNotificationEvent",{grant:f.grant,event:f.events[1]});
    await call("revokeNotificationGrant",{...f.grant,state:"revoked",revision:2});
    await sleep(1500);
    const last=await db.prepare("SELECT state FROM deliveries WHERE delivery_id=?").bind(f.events[1].envelope.delivery_id).first();
    assert.equal(last.state,"cancelled");
    assert.equal(delivered.length,3,"revoked queued alert escaped");
    await call("sendNotificationEvent",{grant:f.grant,event:f.events[2]},409);
    await call("putNotificationGrant",f.approvalGrant);
    await call("sendNotificationEvent",{grant:f.approvalGrant,event:{...f.approvalEvent,eventId:f.approvalGrant.grantId+":invalid"}},409);
    assert.equal((await call("sendNotificationEvent",{grant:f.approvalGrant,event:f.approvalEvent})).status,"accepted");
    assert.equal((await call("sendNotificationEvent",{grant:f.approvalGrant,event:f.approvalEvent})).status,"duplicate");
    await waitFor(()=>delivered.length===4,"approval not delivered to test APNs");
    assert.deepEqual(delivered[3].body.loopdy.envelope,f.approvalEvent.envelope);
    assert.equal(delivered[3].type,"alert");
    if(process.env.BIGHELP_RELAY_EVIDENCE){
      await writeFile(process.env.BIGHELP_RELAY_EVIDENCE,JSON.stringify({source:"real workerd binding/queue; APNs network stub; ephemeral test keys",delivered},null,2));
    }
  } finally { await mf.dispose(); }
});
