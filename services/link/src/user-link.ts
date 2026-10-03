import { UserLinkAccount } from "./user-link-account.js";
import { ACTIVITY_RECORD_GRACE_SECONDS, UserLinkNotificationStore } from "./user-link-notifications.js";
import { initializeUserLinkStorage } from "./user-link-schema.js";
import { DurableObject } from "cloudflare:workers";
import {
  type PublicAccountProfile,
  LINK_LIMITS,
  LoopdyLinkError,
  type PublicLinkDevice,
  type PublicLinkDeviceList,
  parseRegisterLinkDevice,
  parseRenameLinkDevice,
  parseRevokeLinkDevice,
  type RegisterLinkDevice,
  type RenameLinkDevice,
  type RevokeLinkDevice,
  type SaveAccountProfile,
} from "./contracts.js";
import { lookupDeviceAccountCoordinate, verifyDeviceRequest } from "./device-auth.js";
import { sendBuzzKitLinkWake } from "./buzzkit.js";
import { acceptedFrame, backpressureFrame, type EncryptedLinkFrame, parseEncryptedFrame } from "./frame.js";
import {
  ACTIVE_DEVICE_LIMIT, DELIVERY_BYTE_WINDOW, DELIVERY_WINDOW, PendingDeliveryStore,
} from "./pending-delivery.js";

import { type LinkSocketAttachment, parseSocketAttachment } from "./socket-attachment.js";
import { STATE_BACKED_PRESENTATION_CAPABILITY, StatePresentationStore } from "./state-presentation.js";

export interface LinkEnv extends Env {
  BUZZKIT_API_KEY?: string;
  BUZZKIT_IDENTITY_SECRET?: string;
  BUZZKIT_IDENTITY_SECRET_GENERATION?: string;
  BUZZKIT_TENANT?: string;
  BUZZKIT_API_URL?: string;
  BUZZKIT_ASSET_ORIGIN?: string;
  NOTIFICATION_BOOTSTRAP_RATE_SECRET?: string;
}

interface DeviceRow extends Record<string, SqlStorageValue> {
  device_id: string;
  public_key: string;
  role: string;
  kind: string;
  encrypted_name: string;
  lifecycle: string;
  revision: number;
  authorization_epoch: number;
  connection_state: string;
  push_state: string | null;
  push_revision: number;
  created_at: number;
  revoked_at: number | null;
  last_seen_bucket: number | null;
  last_inbound_sequence: number;
  last_ack_sequence: number;
}

interface LinkReceipt {
  version: 1;
  type: "receipt";
  deviceId: string;
  frameId: string;
  sourceDeviceId: string;
  sequence: number;
}

interface FrameRecipients {
  durable: string[];
  presentation: string[];
}

interface BuzzKitWakeRow extends Record<string, SqlStorageValue> {
  frame_id: string;
  account_coordinate: string;
  host_device_id: string;
  host_epoch: number;
  expires_at: number;
  attempts: number;
  next_attempt: number;
}

const SOCKET_REVOKED = 4003;
const SOCKET_PROTOCOL_ERROR = 4004;
const RECENT_SECONDS = 300;
const DEVICE_COORDINATE = /^[A-Za-z0-9_-]{1,96}$/;
const FRAME_COORDINATE = /^[A-Za-z0-9_-]{16,128}$/;

export class UserLink extends DurableObject<LinkEnv> {
  private readonly account: UserLinkAccount;
  private readonly notificationState: UserLinkNotificationStore;
  private readonly pendingDelivery: PendingDeliveryStore;
  private readonly presentationDelivery: StatePresentationStore;
  private buzzKitWakeDrain: Promise<void> | null = null;

  constructor(ctx: DurableObjectState, env: LinkEnv) {
    super(ctx, env);
    this.account = new UserLinkAccount(ctx);
    this.notificationState = new UserLinkNotificationStore(
      ctx.storage, this.account, (deviceId) => this.requiredActiveDevice(deviceId),
    );
    this.presentationDelivery = new StatePresentationStore(ctx.storage);
    const retention = env as LinkEnv & { LINK_RETAINED_FRAME_LIMIT?: string; LINK_RETAINED_BYTE_LIMIT?: string };
    this.pendingDelivery = new PendingDeliveryStore(ctx.storage, {
      frames: retention.LINK_RETAINED_FRAME_LIMIT,
      bytes: retention.LINK_RETAINED_BYTE_LIMIT,
    });
    ctx.blockConcurrencyWhile(async () => {
      if (this.account.isAccountDeleted()) {
        for (const socket of this.ctx.getWebSockets()) {
          socket.close(SOCKET_REVOKED, "account deleted");
        }
        await this.ctx.storage.deleteAlarm();
        return;
      }
      initializeUserLinkStorage(this.ctx.storage);
      this.pendingDelivery.initialize();
      this.presentationDelivery.initialize();
      // A crash after acceptance but before a live send must request state,
      // not silently forget the last transient update on hibernation recovery.
      for (const socket of this.activeSocketsForRole("mobile", "")) {
        this.recoverPresentationGap(socket);
      }
    });
  }

  registerDevice(input: RegisterLinkDevice): PublicLinkDevice {
    this.account.assertAccountActive();
    const device = parseRegisterLinkDevice(input);
    return this.ctx.storage.transactionSync(() => {
      const existing = this.readDevice(device.deviceId);
      if (existing) {
        if (
          existing.lifecycle === "active" &&
          existing.revision === device.revision &&
          existing.public_key === device.publicKey &&
          existing.role === device.role &&
          existing.kind === device.kind &&
          existing.encrypted_name === device.encryptedName
        ) {
          return publicProjection(existing);
        }
        throw new LoopdyLinkError("device_conflict", "Device registration conflicts with state");
      }

      // Existing registrations above the cap remain authorized. Only explicit
      // revocation (which purges pending deliveries) makes room for a new ID.
      const activeDevices = this.ctx.storage.sql.exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM devices WHERE lifecycle = 'active'",
      ).one().count;
      if (activeDevices >= ACTIVE_DEVICE_LIMIT) {
        throw new LoopdyLinkError("device_limit", "Active device registration limit reached");
      }
      // Retain null legacy catalog fields for wire compatibility only. BuzzKit
      // owns every device subscription; Link does not mirror registration state.
      const pushState = null;
      this.ctx.storage.sql
        .exec(
          `INSERT INTO devices (
             device_id, public_key, role, kind, encrypted_name, lifecycle,
             revision, authorization_epoch, connection_state, push_state, push_revision,
             created_at, revoked_at, last_seen_bucket,
             last_inbound_sequence, last_ack_sequence
           ) VALUES (?, ?, ?, ?, ?, 'active', ?, 1, 'offline', ?, 0, ?, NULL, NULL, 0, 0)`,
          device.deviceId,
          device.publicKey,
          device.role,
          device.kind,
          device.encryptedName,
          device.revision,
          pushState,
          device.createdAt,
        )
        .toArray();
      if (device.role === "host") {
        this.ctx.storage.sql
          .exec(
            `INSERT INTO host_grants (host_device_id, state, created_at, revoked_at)
             VALUES (?, 'active', ?, NULL)`,
            device.deviceId,
            device.createdAt,
          )
          .toArray();
      }
      return publicProjection(this.requiredDevice(device.deviceId));
    });
  }

  beginAccountDeletion(): void {
    this.account.beginAccountDeletion();
  }

  deleteAccountData(): Promise<void> {
    return this.account.deleteAccountData();
  }

  listDevices(): PublicLinkDeviceList {
    this.account.assertAccountActive();
    const rows = this.ctx.storage.sql
      .exec<DeviceRow>(
        `SELECT * FROM devices
         WHERE lifecycle = 'active'
         ORDER BY CASE role WHEN 'mobile' THEN 0 ELSE 1 END, created_at, device_id
         LIMIT ?`,
        LINK_LIMITS.listDevices,
      )
      .toArray();
    return { devices: rows.map(publicProjection) };
  }

  deliveryDiagnostics() {
    this.account.assertAccountActive();
    return this.pendingDelivery.diagnostics();
  }

  loadAccountProfile(): PublicAccountProfile | null {
    return this.account.loadAccountProfile();
  }

  saveAccountProfile(input: SaveAccountProfile): PublicAccountProfile {
    return this.account.saveAccountProfile(input);
  }

  // Validation still throws synchronously; only the purge alarm is awaited.
  putNotificationAsset(input: Parameters<UserLinkNotificationStore["putNotificationAsset"]>[0]) {
    const asset = this.notificationState.putNotificationAsset(input);
    return this.scheduleNotificationPurge(asset.expiresAt).then(() => asset);
  }

  notificationAsset(input: Parameters<UserLinkNotificationStore["notificationAsset"]>[0]) {
    return this.notificationState.notificationAsset(input);
  }

  registerNotificationActivity(input: Parameters<UserLinkNotificationStore["registerNotificationActivity"]>[0]) {
    const activity = this.notificationState.registerNotificationActivity(input);
    return this.scheduleNotificationPurge(input.leaseExpires + ACTIVITY_RECORD_GRACE_SECONDS).then(() => activity);
  }

  notificationActivity(input: Parameters<UserLinkNotificationStore["notificationActivity"]>[0]) {
    return this.notificationState.notificationActivity(input);
  }

  revokeNotificationActivity(input: Parameters<UserLinkNotificationStore["revokeNotificationActivity"]>[0]) {
    return this.notificationState.revokeNotificationActivity(input);
  }

  revokeNotificationGrantActivities(input: Parameters<UserLinkNotificationStore["revokeNotificationGrantActivities"]>[0]) {
    return this.notificationState.revokeNotificationGrantActivities(input);
  }

  authorizeNotificationEgress(input: Parameters<UserLinkNotificationStore["authorizeNotificationEgress"]>[0]) {
    return this.notificationState.authorizeNotificationEgress(input);
  }

  revokeNotificationCredential(input: Parameters<UserLinkNotificationStore["revokeNotificationCredential"]>[0]) {
    return this.notificationState.revokeNotificationCredential(input);
  }

  revokeNotificationGrantAuthority(input: Parameters<UserLinkNotificationStore["revokeNotificationGrantAuthority"]>[0]) {
    return this.notificationState.revokeNotificationGrantAuthority(input);
  }

  retireDeletedAccountNotificationGrantAuthority(input: Parameters<UserLinkNotificationStore["retireDeletedAccountNotificationGrantAuthority"]>[0]) {
    return this.notificationState.retireDeletedAccountNotificationGrantAuthority(input);
  }

  retireNotificationScope(): void {
    this.notificationState.retireNotificationScope();
  }

  beginNotificationActivityUpdate(input: Parameters<UserLinkNotificationStore["beginNotificationActivityUpdate"]>[0]) {
    return this.notificationState.beginNotificationActivityUpdate(input);
  }

  completeNotificationActivityUpdate(input: Parameters<UserLinkNotificationStore["completeNotificationActivityUpdate"]>[0]) {
    return this.notificationState.completeNotificationActivityUpdate(input);
  }

  renameDevice(input: RenameLinkDevice): PublicLinkDevice {
    this.account.assertAccountActive();
    const request = parseRenameLinkDevice(input);
    return this.ctx.storage.transactionSync(() => {
      const current = this.requiredActiveDevice(request.deviceId);
      this.assertRevision(current, request.expectedRevision);
      const nextRevision = current.revision + 1;
      this.ctx.storage.sql
        .exec(
          `UPDATE devices SET encrypted_name = ?, revision = ?
           WHERE device_id = ? AND lifecycle = 'active' AND revision = ?`,
          request.encryptedName,
          nextRevision,
          request.deviceId,
          request.expectedRevision,
        )
        .toArray();
      const confirmed = this.requiredActiveDevice(request.deviceId);
      if (
        confirmed.revision !== nextRevision ||
        confirmed.encrypted_name !== request.encryptedName
      ) {
        throw new LoopdyLinkError("stale_revision", "Device revision is stale");
      }
      return publicProjection(confirmed);
    });
  }

  revokeDevice(input: RevokeLinkDevice): PublicLinkDevice {
    this.account.assertAccountActive();
    const request = parseRevokeLinkDevice(input);
    const device = this.ctx.storage.transactionSync(() => {
      const current = this.requiredDevice(request.deviceId);
      if (current.lifecycle === "revoked") {
        if (current.revision === request.expectedRevision + 1
            && current.authorization_epoch > 1) return publicProjection(current);
        throw new LoopdyLinkError("stale_revision", "Device revision is stale");
      }
      this.assertRevision(current, request.expectedRevision);
      this.ctx.storage.sql
        .exec(
          `UPDATE devices SET
             lifecycle = 'revoked', revision = revision + 1,
             authorization_epoch = authorization_epoch + 1,
             connection_state = 'offline', revoked_at = ?
           WHERE device_id = ? AND lifecycle = 'active' AND revision = ?`,
          request.revokedAt,
          request.deviceId,
          request.expectedRevision,
        )
        .toArray();
      if (current.role === "host") {
        this.ctx.storage.sql
          .exec(
            `UPDATE host_grants SET state = 'revoked', revoked_at = ?
             WHERE host_device_id = ? AND state = 'active'`,
            request.revokedAt,
            request.deviceId,
          )
          .toArray();
      }
      this.pendingDelivery.revokeDevice(request.deviceId);
      this.presentationDelivery.revoke(request.deviceId);
      const confirmed = this.requiredDevice(request.deviceId);
      if (
        confirmed.lifecycle !== "revoked" ||
        confirmed.revision !== request.expectedRevision + 1
      ) {
        throw new LoopdyLinkError("stale_revision", "Device revision is stale");
      }
      return publicProjection(confirmed);
    });
    this.closeDeviceSockets(request.deviceId, SOCKET_REVOKED, "device revoked");
    return device;
  }

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (
      request.method !== "GET" ||
      (url.pathname !== "/connect" && url.pathname !== "/v1/socket") ||
      request.headers.get("upgrade")?.toLowerCase() !== "websocket"
    ) {
      return Response.json({ version: 1, error: "socket_upgrade_required" }, { status: 426 });
    }
    if (!request.headers.get("sec-websocket-key")) {
      return Response.json({ version: 1, error: "socket_handshake_invalid" }, { status: 426 });
    }
    try {
      this.account.assertAccountActive();
      // The Worker deliberately forwards the original WebSocket Request so the
      // runtime can bind the DO's 101 response to the client's connection. Do
      // the complete device verification here after routing by device ID.
      const verified = await verifyDeviceRequest(
        request,
        "",
        this.env.ACCOUNTS,
        Math.floor(Date.now() / 1_000),
      );
      const deviceId = verified.deviceId;
      const authorizationEpoch = verified.authorizationEpoch;
      const device = this.requiredActiveDevice(deviceId);
      if (device.authorization_epoch !== authorizationEpoch) {
        throw new LoopdyLinkError("authorization_epoch_stale", "Socket authorization is stale");
      }
      const role = device.role as LinkSocketAttachment["role"];
      const hostGrant = role === "host" ? this.requiredActiveHostGrant(deviceId) : null;
      const socketReadySupported = supportsCapability(request, "socket-ready-v1");
      const stateBackedPresentation = socketReadySupported &&
        supportsCapability(request, STATE_BACKED_PRESENTATION_CAPABILITY);
      const presentationConnectionId = crypto.randomUUID();
      this.closeDeviceSockets(deviceId, 4000, "connection replaced");
      const pair = new WebSocketPair();
      const client = pair[0];
      const server = pair[1];
      const attachment: LinkSocketAttachment = {
        version: 1,
        deviceId,
        role,
        authorizationEpoch,
        hostGrant,
        lastAcknowledgedSequence: device.last_ack_sequence,
        ...(supportsCapability(request, "backpressure-v1") ? { backpressureV1: true } : {}),
        ...(supportsCapability(request, "directed-frames-v1") ? { directedFramesV1: true } : {}),
        ...(stateBackedPresentation ? {
          stateBackedPresentationV1: true, presentationConnectionId,
        } : {}),
      };
      server.serializeAttachment(attachment);
      this.ctx.acceptWebSocket(server, [`device:${deviceId}`, `role:${role}`]);
      // Every successful handshake writes the current choice. An older client
      // reconnecting in the same epoch revokes its previous disposable policy.
      this.presentationDelivery.negotiate(
        deviceId, authorizationEpoch, stateBackedPresentation, presentationConnectionId,
      );
      this.ctx.storage.sql
        .exec(
          `UPDATE devices SET connection_state = 'online', last_seen_bucket = ?
           WHERE device_id = ? AND lifecycle = 'active' AND authorization_epoch = ?`,
          currentSeenBucket(),
          deviceId,
          authorizationEpoch,
        )
        .toArray();
      // `socket.ready` is an explicit protocol upgrade. Legacy Hermes hosts
      // treat every text message as an encrypted frame, so never send this
      // control message unless the client advertises support.
      const socketReadySent = socketReadySupported ? this.sendSocketReady(server, device) : false;
      if (stateBackedPresentation && role === "mobile") {
        this.presentationDelivery.reset(server, attachment, "reconnect");
      }
      this.replayPendingFrames(server, deviceId);
      socketDiagnostic(
        "accepted",
        socketReadySupported
          ? socketReadySent
            ? "socket_accepted_ready_v1_sent"
            : `socket_accepted_ready_v1_deferred_state_${server.readyState}`
          : "socket_accepted_legacy",
      );
      return new Response(null, { status: 101, webSocket: client });
    } catch (error) {
      const code = error instanceof LoopdyLinkError ? error.code : "socket_denied";
      socketDiagnostic("rejected", code);
      return Response.json({ version: 1, error: code }, { status: 403 });
    }
  }

  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      this.account.assertAccountActive();
      // A closing, replaced connection no longer owns this device's delivery.
      if (socket.readyState !== WebSocket.OPEN) return;
      if (typeof message !== "string") {
        throw new LoopdyLinkError("frame_invalid", "Encrypted frame must be JSON text");
      }
      const attachment = parseSocketAttachment(socket.deserializeAttachment());
      const device = this.requiredActiveDevice(attachment.deviceId);
      if (device.authorization_epoch !== attachment.authorizationEpoch) {
        throw new LoopdyLinkError("device_revoked", "Socket authorization is revoked");
      }
      if (attachment.role !== device.role ||
          (attachment.role === "host" && attachment.hostGrant !== this.requiredActiveHostGrant(attachment.deviceId))) {
        throw new LoopdyLinkError("device_revoked", "Socket authorization is revoked");
      }
      const control = parseControlMessage(message);
      if (control?.type === "receipt") {
        if (control.deviceId !== attachment.deviceId) {
          throw new LoopdyLinkError(
            "receipt_sender_invalid",
            "Receipt sender does not match the authenticated socket",
          );
        }
        this.pendingDelivery.acceptReceipt(control);
        this.presentationDelivery.receipt(attachment, control);
        if (socket.readyState === WebSocket.OPEN) {
          socket.send(
            JSON.stringify({
              version: 1,
              type: "receipt.accepted",
              frameId: control.frameId,
            }),
          );
        }
        this.replayPendingFrames(socket, attachment.deviceId);
        return;
      }
      const frame = parseEncryptedFrame(message);
      if (frame.deliveryClass === "presentation" &&
          (attachment.role !== "host" || !this.presentationDelivery.ownsConnection(attachment))) {
        throw new LoopdyLinkError(
          "presentation_unavailable", "State-backed presentation requires a negotiated host socket",
        );
      }
      if (frame.targetDeviceId !== undefined && attachment.directedFramesV1 !== true) {
        throw new LoopdyLinkError("directed_frames_unavailable", "Directed frame support was not negotiated");
      }
      if (frame.senderDeviceId !== attachment.deviceId) {
        throw new LoopdyLinkError(
          "frame_sender_invalid",
          "Encrypted frame sender does not match the authenticated socket",
        );
      }
      if (frame.senderEpoch !== attachment.authorizationEpoch) {
        throw new LoopdyLinkError("frame_epoch_stale", "Encrypted frame epoch is stale");
      }
      // Resolve the signed host's current account before durable acceptance. If
      // D1 cannot confirm it, the host retries the encrypted frame and no wake
      // side effect can be lost after acceptance.
      const wakeAccountCoordinate = attachment.role === "host"
        ? await lookupDeviceAccountCoordinate(this.env.ACCOUNTS, attachment.deviceId)
        : null;
      // Resolve current socket/epoch/grant authority before durable acceptance.
      // A stored 'online' state is not proof that recovery capacity is available.
      const recipientSockets = this.recipientSockets(attachment);
      const connectedRecipientIds = new Set(recipientSockets.map((recipient) =>
        parseSocketAttachment(recipient.deserializeAttachment()).deviceId));
      const legacyConnectedRecipientIds = new Set(frame.deliveryClass === "presentation" ? recipientSockets.flatMap((recipient) => {
        const recipientAttachment = parseSocketAttachment(recipient.deserializeAttachment());
        return this.presentationDelivery.ownsConnection(recipientAttachment) ? [] : [recipientAttachment.deviceId];
      }) : []);
      const encodedFrame = JSON.stringify(frame);
      const acceptedRecipients = this.acceptFrame(
        device, frame, encodedFrame, connectedRecipientIds, legacyConnectedRecipientIds,
      );
      if (acceptedRecipients === "storage_limit") {
        if (attachment.backpressureV1 === true) {
          socket.send(JSON.stringify(backpressureFrame(frame)));
        } else {
          socket.close(1013, "storage limit");
        }
        return;
      }
      socket.serializeAttachment({
        ...attachment,
        lastAcknowledgedSequence: Math.max(attachment.lastAcknowledgedSequence, device.last_ack_sequence, frame.ack),
      } satisfies LinkSocketAttachment);
      if (acceptedRecipients) {
        const acceptedRecipientDeviceIDs = acceptedRecipients.durable;
        const acceptedRecipientDeviceIDSet = new Set(acceptedRecipientDeviceIDs);
        const presentationRecipientIds = new Set(acceptedRecipients.presentation);
        for (const recipient of recipientSockets) {
          const recipientDeviceID = parseSocketAttachment(
            recipient.deserializeAttachment(),
          ).deviceId;
          if (presentationRecipientIds.has(recipientDeviceID)) {
            // No durable queue or await: a full/broken lane affects only this peer.
            this.sendPresentationFrame(recipient, frame, encodedFrame);
            continue;
          }
          if (!acceptedRecipientDeviceIDSet.has(recipientDeviceID)) continue;
          if (recipient.readyState === WebSocket.OPEN) {
            // Live and replay traffic share one ordered, receipt-driven pump.
            this.replayPendingFrames(recipient, recipientDeviceID);
          }
        }
      } else if (frame.deliveryClass === "presentation") {
        // A retry never retransmits disposable bytes. Repair an acceptance/send
        // crash with authoritative state rather than a second transient delivery.
        for (const recipient of recipientSockets) this.recoverPresentationGap(recipient);
      }
      if (wakeAccountCoordinate !== null && this.hasOfflineMobileFrame(frame.id)) {
        this.enqueueBuzzKitWake(
          frame.id,
          wakeAccountCoordinate,
          attachment.deviceId,
          attachment.authorizationEpoch,
        );
        await this.scheduleBuzzKitWakeOutbox();
        this.ctx.waitUntil(this.coalescedBuzzKitWakeDrain());
      }
      if (socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify(acceptedFrame(frame)));
      }
    } catch (error) {
      socketDiagnostic(
        "message_rejected",
        error instanceof LoopdyLinkError ? error.code : "socket_message_rejected",
      );
      const revoked =
        error instanceof LoopdyLinkError &&
        ["device_not_found", "device_revoked", "authorization_epoch_stale", "host_grant_revoked"].includes(error.code);
      socket.close(
        revoked ? SOCKET_REVOKED : SOCKET_PROTOCOL_ERROR,
        revoked ? "authorization revoked" : "frame rejected",
      );
    }
  }

  override webSocketClose(
    socket: WebSocket,
    code: number,
    _reason: string,
    wasClean: boolean,
  ): void {
    socketDiagnostic("closed", `code_${code}_${wasClean ? "clean" : "unclean"}`);
    this.markSocketDisconnected(socket);
  }

  override webSocketError(socket: WebSocket): void {
    socketDiagnostic("error", "socket_error");
    this.markSocketDisconnected(socket);
    if (socket.readyState !== WebSocket.CLOSED) socket.close(1011, "socket error");
  }

  override async alarm(): Promise<void> {
    if (this.account.isAccountDeleted()) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const cutoff = currentSeenBucket() - RECENT_SECONDS;
    this.ctx.storage.sql
      .exec(
        `UPDATE devices SET connection_state = 'offline'
         WHERE lifecycle = 'active' AND connection_state = 'recent'
           AND COALESCE(last_seen_bucket, 0) <= ?`,
        cutoff,
      )
      .toArray();
    await this.coalescedBuzzKitWakeDrain();
    const purge = this.notificationState.purgeExpiredNotificationState(Math.floor(Date.now() / 1_000));
    const recent = this.ctx.storage.sql.exec<{ next: number | null }>(
      "SELECT MIN(last_seen_bucket)+? AS next FROM devices WHERE lifecycle='active' AND connection_state='recent'", RECENT_SECONDS,
    ).one().next;
    const wake = this.ctx.storage.sql.exec<{ next: number | null }>(
      "SELECT MIN(next_attempt) AS next FROM buzzkit_wake_outbox",
    ).one().next;
    const nextSeconds = [recent, wake, purge].filter((value): value is number => value !== null)
      .reduce<number | null>((selected, value) => selected === null ? value : Math.min(selected, value), null);
    if (nextSeconds !== null) {
      await this.ctx.storage.setAlarm(Math.max(Date.now() + 1_000, nextSeconds * 1_000));
    }
  }

  private hasOfflineMobileFrame(frameId: string): boolean {
    const open = new Set<string>();
    for (const socket of this.ctx.getWebSockets("role:mobile")) {
      if (socket.readyState !== WebSocket.OPEN) continue;
      try { open.add(parseSocketAttachment(socket.deserializeAttachment()).deviceId); }
      catch { /* Invalid sockets cannot suppress a required wake. */ }
    }
    return this.ctx.storage.sql.exec<{ recipient_device_id: string }>(
      `SELECT p.recipient_device_id FROM pending_frames p
       JOIN devices d ON d.device_id=p.recipient_device_id
       WHERE p.frame_id=? AND d.lifecycle='active' AND d.role='mobile'
       ORDER BY p.recipient_device_id`,
      frameId,
    ).toArray().some((row) => !open.has(row.recipient_device_id));
  }

  private enqueueBuzzKitWake(
    frameId: string,
    accountCoordinate: string,
    hostDeviceId: string,
    hostEpoch: number,
  ): void {
    if (!FRAME_COORDINATE.test(frameId) || !/^[A-Za-z0-9_-]{22,256}$/.test(accountCoordinate)
        || !DEVICE_COORDINATE.test(hostDeviceId) || !positiveInteger(hostEpoch)) {
      throw new LoopdyLinkError("link_wake_invalid", "Loopdy Link wake identity is invalid");
    }
    const now = Math.floor(Date.now() / 1_000);
    this.ctx.storage.sql.exec(
      `INSERT INTO buzzkit_wake_outbox(
         frame_id,account_coordinate,host_device_id,host_epoch,expires_at,attempts,next_attempt)
       VALUES(?,?,?,?,?,0,?) ON CONFLICT(frame_id) DO UPDATE SET
         account_coordinate=excluded.account_coordinate,
         host_device_id=excluded.host_device_id,
         host_epoch=excluded.host_epoch,
         expires_at=MAX(buzzkit_wake_outbox.expires_at,excluded.expires_at),
         next_attempt=MIN(buzzkit_wake_outbox.next_attempt,excluded.next_attempt)`,
      frameId, accountCoordinate, hostDeviceId, hostEpoch, now + 300, now,
    );
  }

  private async scheduleNotificationPurge(dueSeconds: number): Promise<void> {
    if (this.account.isAccountDeleted()) return;
    const next = Math.max(Date.now() + 1_000, dueSeconds * 1_000);
    const existing = await this.ctx.storage.getAlarm();
    if (existing === null || next < existing) await this.ctx.storage.setAlarm(next);
  }

  private async scheduleBuzzKitWakeOutbox(): Promise<void> {
    if (this.account.isAccountDeleted()) return;
    const due = this.ctx.storage.sql.exec<{ next: number | null }>(
      "SELECT MIN(next_attempt) AS next FROM buzzkit_wake_outbox",
    ).one().next;
    if (due === null) return;
    const existing = await this.ctx.storage.getAlarm();
    if (this.account.isAccountDeleted()) return;
    const next = Math.max(Date.now() + 1_000, due * 1_000);
    if (existing === null || next < existing) await this.ctx.storage.setAlarm(next);
  }

  private coalescedBuzzKitWakeDrain(): Promise<void> {
    if (this.buzzKitWakeDrain) return this.buzzKitWakeDrain;
    const drain = this.drainBuzzKitWakeOutbox().then(
      () => { this.buzzKitWakeDrain = null; },
      (error) => {
        this.buzzKitWakeDrain = null;
        throw error;
      },
    );
    this.buzzKitWakeDrain = drain;
    return drain;
  }

  private async drainBuzzKitWakeOutbox(): Promise<void> {
    if (this.account.isAccountDeleted()) return;
    const now = Math.floor(Date.now() / 1_000);
    this.ctx.storage.sql.exec("DELETE FROM buzzkit_wake_outbox WHERE expires_at<=?", now);
    const rows = this.ctx.storage.sql.exec<BuzzKitWakeRow>(
      "SELECT * FROM buzzkit_wake_outbox WHERE next_attempt<=? ORDER BY next_attempt,frame_id LIMIT 8",
      now,
    ).toArray();
    for (const row of rows) {
      const remove = () => this.ctx.storage.sql.exec(
        "DELETE FROM buzzkit_wake_outbox WHERE frame_id=?", row.frame_id,
      );
      try {
        const host = this.requiredActiveDevice(row.host_device_id);
        this.requiredActiveHostGrant(row.host_device_id);
        const accountCoordinate = await lookupDeviceAccountCoordinate(
          this.env.ACCOUNTS,
          row.host_device_id,
        );
        if (host.authorization_epoch !== row.host_epoch
            || accountCoordinate !== row.account_coordinate
            || !this.hasOfflineMobileFrame(row.frame_id)) {
          remove();
          continue;
        }
        await sendBuzzKitLinkWake(this.env, row.account_coordinate, row.frame_id, {
          hostDeviceId: row.host_device_id,
          authorizationEpoch: row.host_epoch,
          authorizeEgress: () => {
            this.account.assertAccountActive();
            const currentHost = this.requiredActiveDevice(row.host_device_id);
            this.requiredActiveHostGrant(row.host_device_id);
            if (currentHost.authorization_epoch !== row.host_epoch) {
              throw new LoopdyLinkError("authorization_epoch_stale", "Wake host authority is stale");
            }
          },
        });
        if (this.account.isAccountDeleted()) return;
        remove();
      } catch (error) {
        if (this.account.isAccountDeleted()) return;
        const attempts = row.attempts + 1;
        const delay = Math.min(60, 2 ** Math.min(attempts, 6));
        this.ctx.storage.sql.exec(
          `UPDATE buzzkit_wake_outbox SET attempts=?,next_attempt=?
           WHERE frame_id=? AND expires_at>?`,
          attempts, now + delay, row.frame_id, now,
        );
        const code = error && typeof error === "object" && "code" in error
          ? String((error as { code: unknown }).code) : "link_wake_unavailable";
        if (code !== "link_wake_recipient_unavailable") {
          console.warn(`[loopdy-link] buzzkit_wake_retry: ${code.replace(/[^a-z0-9_-]/gi, "_").slice(0, 96)}`);
        }
      }
    }
    await this.scheduleBuzzKitWakeOutbox();
  }

  private acceptFrame(
    device: DeviceRow,
    frame: EncryptedLinkFrame,
    encodedFrame: string,
    connectedRecipientIds: ReadonlySet<string>,
    legacyConnectedRecipientIds: ReadonlySet<string>,
  ): FrameRecipients | null | "storage_limit" {
    return this.ctx.storage.transactionSync(() => {
      this.account.assertAccountActive();
      const current = this.requiredActiveDevice(device.device_id);
      if (frame.sequence === current.last_inbound_sequence) {
        const accepted = this.ctx.storage.sql
          .exec<{ frame_id: string }>(
            `SELECT frame_id FROM frame_ids
             WHERE sender_device_id = ? AND sequence = ? LIMIT 1`,
            device.device_id,
            frame.sequence,
          )
          .toArray()[0];
        if (accepted?.frame_id === frame.id) return null;
        throw new LoopdyLinkError(
          "frame_replayed",
          "Encrypted frame sequence conflicts with accepted state",
        );
      }
      if (frame.sequence !== current.last_inbound_sequence + 1) {
        throw new LoopdyLinkError("frame_sequence_invalid", "Encrypted frame sequence is invalid");
      }
      // A reconnecting client may legitimately send a frame that was queued
      // with an older cumulative acknowledgement. A lower ack cannot roll
      // back relay state, so preserve the monotonic high-water mark while
      // accepting the newer frame.
      const nextAcknowledgedSequence = Math.max(current.last_ack_sequence, frame.ack);
      const duplicate = this.ctx.storage.sql
        .exec<{ frame_id: string }>(
          "SELECT frame_id FROM frame_ids WHERE frame_id = ? LIMIT 1",
          frame.id,
        )
        .toArray()[0];
      if (duplicate) {
        throw new LoopdyLinkError("frame_replayed", "Encrypted frame was already accepted");
      }
      let candidateRecipients = this.recipientDeviceIds(current);
      if (frame.targetDeviceId !== undefined) {
        if (!candidateRecipients.includes(frame.targetDeviceId)) {
          throw new LoopdyLinkError("recipient_unavailable", "The selected recipient is unavailable");
        }
        candidateRecipients = [frame.targetDeviceId];
      }
      if (candidateRecipients.length === 0) {
        throw new LoopdyLinkError(
          "recipient_unavailable",
          "No paired Loopdy Link recipient is available",
        );
      }
      const pendingDuplicate = this.ctx.storage.sql.exec(
        "SELECT frame_id FROM pending_frame_refs WHERE frame_id = ?", frame.id,
      ).toArray()[0];
      if (pendingDuplicate) {
        throw new LoopdyLinkError("frame_replayed", "Encrypted frame was already accepted");
      }
      // A normalized envelope must also fit a single bounded delivery. Refuse it
      // before acceptance rather than retaining an item the pump can never send.
      const encodedBytes = new TextEncoder().encode(encodedFrame).byteLength;
      if (encodedBytes > DELIVERY_BYTE_WINDOW) {
        throw new LoopdyLinkError("frame_too_large", "Encrypted frame is too large");
      }
      const presentationRecipients = frame.deliveryClass === "presentation"
        ? candidateRecipients.filter((deviceId) => {
          // Persisted opt-in applies offline, but a real legacy connection wins
          // over stale metadata from an earlier service version.
          const recipient = this.requiredActiveDevice(deviceId);
          return !legacyConnectedRecipientIds.has(deviceId) &&
            this.presentationDelivery.isEnabled(deviceId, recipient.authorization_epoch);
        }) : [];
      const transientRecipients = new Set(presentationRecipients);
      const durableCandidates = candidateRecipients.filter((deviceId) => !transientRecipients.has(deviceId));
      // Legacy receivers see the old shape. A durable copy must not masquerade
      // as transient if its recipient upgrades before replaying it.
      const { deliveryClass: _deliveryClass, ...durableFrame } = frame;
      const durableEncodedFrame = frame.deliveryClass === "presentation" ? JSON.stringify(durableFrame) : encodedFrame;
      const durableEncodedBytes = frame.deliveryClass === "presentation"
        ? new TextEncoder().encode(durableEncodedFrame).byteLength : encodedBytes;
      const rescue = this.pendingDelivery.hasLegacyRescue(
        current.device_id, current.authorization_epoch, frame.sequence,
      );
      const admissions = this.pendingDelivery.selectRecipients(
        durableEncodedBytes, durableCandidates, connectedRecipientIds, rescue,
      );
      if (admissions.length === 0 && presentationRecipients.length === 0) return "storage_limit";
      const recipients = admissions.map((admission) => admission.deviceId);
      this.ctx.storage.sql
        .exec(
          `INSERT INTO frame_ids (frame_id, sender_device_id, sequence, created_at)
           VALUES (?, ?, ?, ?)`,
          frame.id,
          device.device_id,
          frame.sequence,
          Math.floor(Date.now() / 1_000),
        )
        .toArray();
      for (const { deviceId: recipientDeviceId, retentionClass } of admissions) {
        this.pendingDelivery.persistFrame(
          recipientDeviceId,
          device.device_id,
          frame,
          durableEncodedFrame,
          Math.floor(Date.now() / 1_000),
          retentionClass,
        );
      }
      const retainedRecipients = new Set(recipients);
      this.pendingDelivery.recordSkippedRecipients(
        durableCandidates.filter((recipient) => !retainedRecipients.has(recipient)), durableEncodedBytes,
      );
      this.presentationDelivery.recordAcceptance(presentationRecipients, frame.id);
      if (rescue) {
        this.pendingDelivery.consumeLegacyRescue(current.device_id, current.authorization_epoch, frame.sequence);
      }
      this.ctx.storage.sql
        .exec(
          `UPDATE devices SET last_inbound_sequence = ?, last_ack_sequence = ?
           WHERE device_id = ? AND lifecycle = 'active' AND authorization_epoch = ?`,
          frame.sequence,
          nextAcknowledgedSequence,
          device.device_id,
          device.authorization_epoch,
        )
        .toArray();
      this.ctx.storage.sql
        .exec(
          `DELETE FROM frame_ids WHERE sender_device_id = ?
           AND NOT EXISTS (SELECT 1 FROM pending_frame_refs WHERE pending_frame_refs.frame_id = frame_ids.frame_id)
           AND NOT EXISTS (SELECT 1 FROM link_presentation_receipts WHERE link_presentation_receipts.frame_id = frame_ids.frame_id)
           AND frame_id NOT IN (
             SELECT frame_id FROM frame_ids WHERE sender_device_id = ?
             ORDER BY sequence DESC LIMIT 1024
           )`,
          device.device_id,
          device.device_id,
        )
        .toArray();
      return { durable: recipients, presentation: presentationRecipients };
    });
  }

  private recipientDeviceIds(sender: DeviceRow): string[] {
    if (sender.role === "host") {
      this.requiredActiveHostGrant(sender.device_id);
      return this.ctx.storage.sql
        .exec<{ device_id: string }>(
          `SELECT device_id FROM devices
           WHERE lifecycle = 'active' AND role = 'mobile' AND device_id != ?
           ORDER BY created_at, device_id`,
          sender.device_id,
        )
        .toArray()
        .map((row) => row.device_id);
    }
    return this.ctx.storage.sql
      .exec<{ device_id: string }>(
        `SELECT d.device_id FROM devices d
         JOIN host_grants h ON h.host_device_id = d.device_id
         WHERE d.lifecycle = 'active' AND d.role = 'host'
           AND h.state = 'active' AND d.device_id != ?
         ORDER BY d.created_at, d.device_id`,
        sender.device_id,
      )
      .toArray()
      .map((row) => row.device_id);
  }

  private sendPresentationFrame(socket: WebSocket, frame: EncryptedLinkFrame, encodedFrame: string): void {
    try {
      const attachment = this.presentationRecipientAttachment(socket);
      if (!attachment) return;
      const bytes = new TextEncoder().encode(encodedFrame).byteLength;
      if (!this.presentationDelivery.reserve(socket, attachment, {
        id: frame.id, senderDeviceId: frame.senderDeviceId,
        senderEpoch: frame.senderEpoch, sequence: frame.sequence,
      }, bytes)) return;
      socket.send(encodedFrame);
      this.presentationDelivery.finish(attachment, frame.id);
    } catch {
      // Keep failure local even if close() also throws. Metadata keeps capacity
      // reserved until disconnect/reconnect; durable acceptance is not retried.
      socketDiagnostic("error", "presentation_delivery_failed");
      try { socket.close(1011, "presentation state unavailable"); } catch { /* already closed */ }
    }
  }

  private recoverPresentationGap(socket: WebSocket): void {
    try {
      const attachment = this.presentationRecipientAttachment(socket);
      if (attachment) this.presentationDelivery.recoverGap(socket, attachment);
    } catch {
      socketDiagnostic("error", "presentation_recovery_failed");
      try { socket.close(1011, "presentation state unavailable"); } catch { /* already closed */ }
    }
  }

  private presentationRecipientAttachment(socket: WebSocket): LinkSocketAttachment | undefined {
    if (socket.readyState !== WebSocket.OPEN) return undefined;
    const attachment = parseSocketAttachment(socket.deserializeAttachment());
    const device = this.requiredActiveDevice(attachment.deviceId);
    if (attachment.role !== "mobile" || device.role !== "mobile" ||
        attachment.authorizationEpoch !== device.authorization_epoch) {
      socket.close(SOCKET_REVOKED, "authorization revoked");
      return undefined;
    }
    return this.presentationDelivery.ownsConnection(attachment) ? attachment : undefined;
  }

  private replayPendingFrames(socket: WebSocket, deviceId: string): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    let sentFrames = 0;
    let sentBytes = 0;
    try {
      const attachment = parseSocketAttachment(socket.deserializeAttachment());
      const device = this.requiredActiveDevice(deviceId);
      if (attachment.deviceId !== deviceId || attachment.role !== device.role ||
          attachment.authorizationEpoch !== device.authorization_epoch) {
        socket.close(SOCKET_REVOKED, "authorization revoked");
        return;
      }
      if (attachment.role === "host" &&
          attachment.hostGrant !== this.requiredActiveHostGrant(deviceId)) {
        socket.close(SOCKET_REVOKED, "host grant revoked");
        return;
      }
      // A socket attachment survives hibernation; a replacement intentionally
      // starts at zero and replays unreceipted work. Only still-pending rows at
      // or below the cursor occupy the window, including out-of-order receipts.
      let cursor = attachment.deliveryCursor ?? 0;
      const inFlight = this.pendingDelivery.inFlight(deviceId, cursor);
      if (inFlight.frames >= DELIVERY_WINDOW || inFlight.bytes >= DELIVERY_BYTE_WINDOW) return;
      for (const row of this.pendingDelivery.page(deviceId, cursor, DELIVERY_WINDOW - inFlight.frames)) {
        if (socket.readyState !== WebSocket.OPEN) break;
        // Reject impossible historical storage without dropping it or repeatedly
        // loading an account-sized/corrupt ciphertext into the isolate.
        if (row.encoded_bytes <= 0 || row.encoded_bytes > DELIVERY_BYTE_WINDOW) {
          socketDiagnostic("error", "pending_frame_size_invalid");
          socket.close(1011, "pending delivery unavailable");
          break;
        }
        if (inFlight.frames + sentFrames >= DELIVERY_WINDOW ||
            inFlight.bytes + sentBytes + row.encoded_bytes > DELIVERY_BYTE_WINDOW) break;
        const encoded = this.pendingDelivery.encodedFrame(deviceId, row.frame_id);
        socket.send(encoded);
        cursor = row.delivery_order;
        sentFrames += 1;
        sentBytes += row.encoded_bytes;
        // Persist only after send. On a crash before persistence, replay is safe;
        // advancing first could silently skip a delivery on a hibernated socket.
        socket.serializeAttachment({ ...attachment, deliveryCursor: cursor } satisfies LinkSocketAttachment);
      }
      if (sentFrames > 0) {
        console.info(JSON.stringify({ event: "link_delivery", reason: "pump", sentFrames, sentBytes }));
      }
    } catch {
      // Delivery failure cannot undo durable acceptance or poison the sender's
      // acknowledgement. The failed recipient reconnects to retry its own queue.
      socketDiagnostic("error", "pending_delivery_failed");
      if (socket.readyState === WebSocket.OPEN) socket.close(1011, "pending delivery unavailable");
    }
  }

  private sendSocketReady(socket: WebSocket, device: DeviceRow): boolean {
    if (socket.readyState !== WebSocket.OPEN) return false;
    const attachment = parseSocketAttachment(socket.deserializeAttachment());
    const lastInbound = this.ctx.storage.sql
      .exec<{ frame_id: string; sequence: number }>(
        `SELECT frame_id, sequence FROM frame_ids
         WHERE sender_device_id = ?
         ORDER BY sequence DESC LIMIT 1`,
        device.device_id,
      )
      .toArray()[0];
    socket.send(
      JSON.stringify({
        version: 1,
        type: "socket.ready",
        deviceId: device.device_id,
        authorizationEpoch: device.authorization_epoch,
        lastInboundSequence: device.last_inbound_sequence,
        lastInboundFrameId: lastInbound?.frame_id ?? null,
        lastAcknowledgedSequence: device.last_ack_sequence,
        ...(attachment.backpressureV1 === true || attachment.directedFramesV1 === true || attachment.stateBackedPresentationV1 === true
          ? { capabilities: ["socket-ready-v1", ...(attachment.backpressureV1 ? ["backpressure-v1"] : []), ...(attachment.directedFramesV1 ? ["directed-frames-v1"] : []), ...(attachment.stateBackedPresentationV1 ? [STATE_BACKED_PRESENTATION_CAPABILITY] : [])] }
          : {}),
      }),
    );
    return true;
  }

  private recipientSockets(sender: LinkSocketAttachment): WebSocket[] {
    if (sender.role === "host") {
      this.requiredActiveHostGrant(sender.deviceId);
      return this.activeSocketsForRole("mobile", sender.deviceId);
    }
    return this.activeSocketsForRole("host", sender.deviceId).filter((socket) => {
      try {
        const attachment = parseSocketAttachment(socket.deserializeAttachment());
        return attachment.hostGrant === this.requiredActiveHostGrant(attachment.deviceId);
      } catch {
        socket.close(SOCKET_REVOKED, "host grant revoked");
        return false;
      }
    });
  }

  private activeSocketsForRole(role: "mobile" | "host", senderDeviceId: string): WebSocket[] {
    return this.ctx.getWebSockets(`role:${role}`).filter((socket) => {
      try {
        if (socket.readyState !== WebSocket.OPEN) return false;
        const attachment = parseSocketAttachment(socket.deserializeAttachment());
        const device = this.requiredActiveDevice(attachment.deviceId);
        return (
          attachment.deviceId !== senderDeviceId &&
          attachment.role === role && device.role === role &&
          attachment.authorizationEpoch === device.authorization_epoch
        );
      } catch {
        socket.close(SOCKET_REVOKED, "authorization revoked");
        return false;
      }
    });
  }

  private markSocketDisconnected(socket: WebSocket): void {
    try {
      if (this.account.isAccountDeleted()) return;
      const attachment = parseSocketAttachment(socket.deserializeAttachment());
      this.presentationDelivery.disconnect(attachment);
      const hasOtherOpenSocket = this.ctx
        .getWebSockets(`device:${attachment.deviceId}`)
        .some((candidate) => candidate !== socket && candidate.readyState === WebSocket.OPEN);
      if (!hasOtherOpenSocket) {
        const seen = currentSeenBucket();
        this.ctx.storage.sql
          .exec(
            `UPDATE devices SET connection_state = 'recent', last_seen_bucket = ?
             WHERE device_id = ? AND lifecycle = 'active'`,
            seen,
            attachment.deviceId,
          )
          .toArray();
        void this.ctx.storage.setAlarm((seen + RECENT_SECONDS) * 1_000);
      }
    } catch {
      // An invalid attachment has no safe device coordinate to mutate.
    }
  }

  private closeDeviceSockets(deviceId: string, code: number, reason: string): void {
    for (const socket of this.ctx.getWebSockets(`device:${deviceId}`)) {
      if (socket.readyState !== WebSocket.CLOSED) socket.close(code, reason);
    }
  }

  private requiredActiveHostGrant(deviceId: string): string {
    const grant = this.ctx.storage.sql
      .exec<{ host_device_id: string }>(
        `SELECT host_device_id FROM host_grants
         WHERE host_device_id = ? AND state = 'active' LIMIT 1`,
        deviceId,
      )
      .toArray()[0];
    if (!grant) throw new LoopdyLinkError("host_grant_revoked", "Host grant is revoked");
    return grant.host_device_id;
  }

  private assertRevision(row: DeviceRow, expectedRevision: number): void {
    if (row.revision !== expectedRevision) {
      throw new LoopdyLinkError("stale_revision", "Device revision is stale");
    }
  }

  private requiredActiveDevice(deviceId: string): DeviceRow {
    const row = this.readDevice(deviceId);
    if (row?.lifecycle !== "active") {
      throw new LoopdyLinkError("device_not_found", "Active device was not found");
    }
    return row;
  }

  private requiredDevice(deviceId: string): DeviceRow {
    const row = this.readDevice(deviceId);
    if (!row) throw new LoopdyLinkError("device_not_found", "Device was not found");
    return row;
  }

  private readDevice(deviceId: string): DeviceRow | undefined {
    return this.ctx.storage.sql
      .exec<DeviceRow>("SELECT * FROM devices WHERE device_id = ? LIMIT 1", deviceId)
      .toArray()[0];
  }

}

function supportsCapability(request: Request, capability: "socket-ready-v1" | "backpressure-v1" | "directed-frames-v1" | typeof STATE_BACKED_PRESENTATION_CAPABILITY): boolean {
  return (request.headers.get("x-loopdy-capabilities") ?? "")
    .split(",")
    .map((value) => value.trim())
    .includes(capability);
}

function publicProjection(row: DeviceRow): PublicLinkDevice {
  return {
    deviceId: row.device_id,
    encryptedName: row.encrypted_name,
    role: row.role as PublicLinkDevice["role"],
    kind: row.kind as PublicLinkDevice["kind"],
    lifecycle: row.lifecycle as PublicLinkDevice["lifecycle"],
    revision: row.revision,
    authorizationEpoch: row.authorization_epoch,
    connection: row.connection_state as PublicLinkDevice["connection"],
    pushState: null,
    pushRevision: 0,
    createdAt: row.created_at,
    revokedAt: row.revoked_at,
    lastSeenBucket: row.last_seen_bucket,
  };
}

function parseControlMessage(message: string): LinkReceipt | null {
  let value: unknown;
  try {
    value = JSON.parse(message);
  } catch {
    return null;
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const receipt = value as Record<string, unknown>;
  if (receipt.type !== "receipt") return null;
  if (
    receipt.version !== 1 ||
    typeof receipt.deviceId !== "string" ||
    !DEVICE_COORDINATE.test(receipt.deviceId) ||
    typeof receipt.frameId !== "string" ||
    !FRAME_COORDINATE.test(receipt.frameId) ||
    typeof receipt.sourceDeviceId !== "string" ||
    !DEVICE_COORDINATE.test(receipt.sourceDeviceId) ||
    !Number.isSafeInteger(receipt.sequence) ||
    Number(receipt.sequence) < 1
  ) {
    throw new LoopdyLinkError("receipt_invalid", "Loopdy Link receipt is invalid");
  }
  return {
    version: 1,
    type: "receipt",
    deviceId: receipt.deviceId,
    frameId: receipt.frameId,
    sourceDeviceId: receipt.sourceDeviceId,
    sequence: Number(receipt.sequence),
  };
}

function positiveInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) > 0;
}

function socketDiagnostic(
  event: "accepted" | "rejected" | "message_rejected" | "closed" | "error",
  code: string,
): void {
  // Never include device identifiers, request headers, or frame payloads in
  // production diagnostics. Error codes are stable protocol coordinates that
  // let operators distinguish handshake and frame failures in Worker Tail.
  console.info(`[loopdy-link] socket_${event}: ${code}`);
}

function currentSeenBucket(): number {
  const now = Math.floor(Date.now() / 1_000);
  return Math.floor(now / 300) * 300;
}
