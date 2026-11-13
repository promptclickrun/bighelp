# Standalone Direct Hermes

> **Historical name.** "Standalone Direct" was the native Hermes connection while the bighelp Link transport
> (bighelp account, pairing, relay) still existed beside it. Link is retired. The native connection is now the only
> way bighelp talks to Hermes, and it needs no bighelp account. The current contract is
> [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). This page keeps the parts that are still true: setup, credentials and
> recovery limits.

bighelp connects straight to a reachable Hermes dashboard (`hermes dashboard` or `hermes serve`): REST sign-in,
WebSocket JSON-RPC on `/api/ws`, dashboard REST, and the optional plugin's routes under
`/api/plugins/loopdy/native/…` (`loopdy` is the plugin's legacy ID). Host authentication and optional notification
enrollment have separate authority.

## Connect

1. On first run, the Connect step opens host setup. Later, use **Settings › Your computers › Add a computer**.
2. Enter your host URL or IP and port.
3. Sign in the way the host allows: a provider-issued access token, host username and password, or browser sign-in.
   Browser sign-in uses the system authentication session, an IPv4 loopback callback and PKCE. A host with no
   sign-in set up connects with the dashboard's own session token. A host behind Cloudflare Access also takes an
   Access service token (client ID and secret).
4. Connect, then add the plugin and notifications if you want them. Pick an agent and start or reopen a chat.

Your host must already be running a current Hermes backend and be reachable from the phone. For Tailscale, both devices must be connected to the appropriate tailnet. bighelp does not install Tailscale, start the host, expose a listener, or modify tailnet access rules.

Use HTTPS where possible. A private address (home Wi‑Fi, a VPN or Tailscale) is tried over HTTPS first, then plain HTTP if nothing answers securely; the connected screen says when the link isn't encrypted. Plain HTTP never bypasses HTTPS certificate checks and is never used for public addresses. The app relies on your Tailscale/VPN configuration for encryption of an HTTP connection.

See the [official Hermes remote-backend guide](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend) for host setup.

## Credentials

A remote access token is a bearer issued by the host's authentication provider. A model-provider API key is not interchangeable with it. The dashboard's session token is used only when the host reports that no sign-in is required.

Username/password login uses the host's native authorization exchange. bighelp stores the resulting session in device-only Keychain storage, not the password. Login redirects are validated rather than followed blindly. Connections are bound to the exact endpoint and verified host account. Forgetting a connection removes the local login, not server history.

## What works

Chat, files and pictures (`file.attach`, `image.attach_bytes`, `pdf.attach`, and big files through the plugin),
streaming text, reasoning, tool results and subagent activity, Stop, steer and queue, slash commands, model choice,
approvals and clarifying questions (several at once too) all run over this connection. With the plugin installed,
the plugin features also work: live voice, cards and forms, device tools, project changes, notifications and the
rest listed in [hermes/EXTENSIONS.md](hermes/EXTENSIONS.md). Each one shows only when the host's `/native/context`
lists its feature; otherwise the app says to update the plugin.

Drafts are kept, and history and replay recovery are native. A confirmed turn can settle after a same-process reconnect without manual receipt cleanup. An unconfirmed submission is never automatically resent. The app does not take over a chat that is active on a messaging gateway.

## Current limits

Wiki: the app still has a Wiki client (plugin feature `native-wiki-v1`), but the current plugin no longer lists that feature, so Wiki is unavailable on current hosts.

The chat socket does not itself provide closed-app pushes. Optional notifications use a separate signed-device enrollment and the plugin; iOS can suspend the connection. Coming back reattaches the chat. If Hermes ended the chat's runtime meanwhile, the app resumes the saved session by itself (`onRetainedStreamsNeedResume`) and a chat route without its model reopens (`reopenChatRoute`).

The host's replay ring is finite. When complete live replay is unavailable, retained rows stay in place and additional native snapshot information may appear as recovery detail. Saved tool history can contain less detail than the live stream. Uncertain queue/steer consumption remains reviewable.

## Verification

The source was exercised against an isolated, unmodified Hermes backend using generated credentials and an explicitly synthetic local model. Hermes ran an actual temporary-directory terminal command. Apple URLSession and iOS Keychain checks covered password and bearer authentication, refusal, streaming, history and reconnect. Native UI checks covered both login modes, typing/sending, close/reopen and a second send. An active-reconnect check preserved row identities and an unsent draft.

These are native simulator and loopback integration results. They do not claim a physical iPhone/Tailscale trial, real-provider latency measurement, production host activation, or push delivery.
