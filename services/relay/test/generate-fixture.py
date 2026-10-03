"""Ephemeral cryptographic fixture consumed privately by the local Worker test."""
import json
import os
import time
import uuid
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from loopdy_plugin.relay_crypto import encrypt_alert, b64url_encode, public_key_bytes, key_id

now = int(time.time())
host = ec.generate_private_key(ec.SECP256R1())
legacy = ec.generate_private_key(ec.SECP256R1())
recipient = ec.generate_private_key(ec.SECP256R1())
apns = ec.generate_private_key(ec.SECP256R1())
host_bytes = public_key_bytes(host.public_key())
legacy_bytes = public_key_bytes(legacy.public_key())
recipient_bytes = public_key_bytes(recipient.public_key())
grant_id = str(uuid.uuid4())
grant = dict(grantId=grant_id,hostKeyId=key_id(host_bytes),hostPublicKey=b64url_encode(host_bytes),
    deviceId="fixture-phone",recipientPublicKey=b64url_encode(recipient_bytes),recipientKeyId=key_id(recipient_bytes),
    recipientRevision=2,authorizationEpoch=1,profile="default",eventTypes=["session.completed","session.failed"],
    createdAt=now-10,expiresAt=now+3600,revision=1,tenantId="fixture-tenant",state="active")
events=[]
for i in range(3):
    event_id=grant_id+":"+str(i)*64
    envelope=encrypt_alert(tenant_id=grant["tenantId"],device_id=grant["deviceId"],
        delivery_id="ng-"+str(uuid.uuid5(uuid.NAMESPACE_URL,event_id)),event_id=event_id,event_type="session.completed",
        title="Your agent finished",body="Open Loopdy for your response.",recipient_public_key=recipient_bytes,
        sender_private_key=host,issued=now,expires=now+900,ephemeral_private_key=ec.generate_private_key(ec.SECP256R1()),
        salt=os.urandom(32),nonce=os.urandom(12))
    events.append(dict(version=1,eventId=event_id,eventType="session.completed",sessionReference=b64url_encode(os.urandom(32)),envelope=envelope,sound=False))
approval_grant = dict(grant, grantId=str(uuid.uuid4()), eventTypes=[*grant["eventTypes"], "approval.required"])
def approval_event(owner):
    event_id = owner["grantId"] + ":" + "a" * 64
    envelope = encrypt_alert(tenant_id=owner["tenantId"], device_id=owner["deviceId"],
        delivery_id="ng-" + str(uuid.uuid5(uuid.NAMESPACE_URL, event_id)), event_id=event_id,
        event_type="approval.required", title="Loopdy", body="Your agent requested approval",
        recipient_public_key=recipient_bytes, sender_private_key=host, issued=now, expires=now+60,
        ephemeral_private_key=ec.generate_private_key(ec.SECP256R1()), salt=os.urandom(32), nonce=os.urandom(12))
    return dict(version=1,eventId=event_id,eventType="approval.required",sessionReference=events[0]["sessionReference"],envelope=envelope,sound=False)
print(json.dumps({"now":now,"grant":grant,"events":events,"approvalGrant":approval_grant,
    "approvalEvent":approval_event(approval_grant),"ungrantedApprovalEvent":approval_event(grant),"legacyKey":dict(key_id=key_id(legacy_bytes),public_key=b64url_encode(legacy_bytes),state="current",not_before=now-30,not_after=now+86400),
    "hmac":b64url_encode(os.urandom(32)),"storage":b64url_encode(os.urandom(32)),
    "apnsPrivateKey":apns.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode(),
    "recipientPrivateKey":b64url_encode(recipient.private_numbers().private_value.to_bytes(32,"big"))}))
