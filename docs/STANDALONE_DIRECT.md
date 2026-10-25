# Standalone Direct Hermes

> Current transport contract: [NATIVE_TRANSPORT.md](NATIVE_TRANSPORT.md). Its account setup, Link comparison and missing-feature list describe an older implementation. Where transport details differ, use the versioned native contract and its source links.

Connect your bighelp account to a reachable `hermes serve` backend without bighelp Link chat pairing. Account sign-in, host authentication and optional notification enrollment have separate authority. Existing Link chats remain separate.

## Connect

1. Sign in to or create your bighelp account. With no configured hosts, the shared Connect Host wizard opens. Later, use **Accounts and Devices → Add Host**.
2. Enter your host URL or IP and port.
3. Choose a supported provider-issued access token, host username/password login, or browser sign-in. Browser sign-in uses the system authentication session, IPv4 loopback callback and PKCE.
4. Connect, then enable optional notifications or continue without them. Select a profile and start or reopen an eligible native session.

Your host must already be running a current Hermes backend and be reachable from the phone. For Tailscale, both devices must be connected to the appropriate tailnet. bighelp does not install Tailscale, start the host, expose a listener, or modify tailnet access rules.

Use HTTPS where possible. A private address (home Wi‑Fi, a VPN or Tailscale) is tried over HTTPS first, then plain HTTP if nothing answers securely; the connected screen says when the link isn't encrypted. Plain HTTP never bypasses HTTPS certificate checks and is never used for public addresses. The app relies on your Tailscale/VPN configuration for encryption of an HTTP connection.

See the [official Hermes remote-backend guide](https://hermes-agent.nousresearch.com/docs/user-guide/desktop#connecting-to-a-remote-backend) for host setup.

## Credentials

A remote access token is a bearer issued by the host's authentication provider. A model-provider API key or legacy dashboard bootstrap token is not interchangeable with it. Legacy bootstrap tokens are supported only for an explicitly allowed literal loopback endpoint whose backend advertises that mode.

Username/password login uses the host's native authorization exchange. bighelp stores the resulting session in device-only Keychain storage, not the password. Login redirects are validated rather than followed blindly. Connections are bound to the exact endpoint and verified host account. Forgetting a connection removes the local login, not server history.

## Included

- Profile and saved native-session discovery.
- Streaming assistant text, reasoning, tool results and subagent activity.
- Stop, steer and queued text, supported slash commands, session model selection, approvals and single-question clarification.
- Retained drafts and native history/replay recovery. A confirmed turn can settle after a same-process reconnect without manual receipt cleanup. An unconfirmed submission is never automatically resent.
- Independent Direct and Link ownership. Direct does not take over an active messaging-gateway chat.

## Current limits

This is a standalone native connection, **not full feature parity with bighelp Link**. Attachments, voice, Wiki, bighelp Cards/form RPC, phone integration, project-change browsing, the full provider/model picker, multi-question clarification and subagent detail/control windows are not connected through this mode yet. Unavailable composer actions are hidden; the connection menu explains support boundaries. None silently falls back to Link.

The direct chat socket does not itself provide closed-app APNs. Optional managed notifications use separate signed-device enrollment and a compatible installed plugin; iOS can suspend the connection. Reopening reattaches the native session where possible. If the original runtime has disappeared, explicitly open its saved session; the app does not silently invoke the host's cold-resume/auto-continuation policy.

The host's replay ring is finite. When complete live replay is unavailable, retained rows stay in place and additional native snapshot information may appear as recovery detail. Saved tool history can contain less detail than the live stream. Uncertain queue/steer consumption remains reviewable.

## Verification

The source was exercised against an isolated, unmodified Hermes backend using generated credentials and an explicitly synthetic local model. Hermes ran an actual temporary-directory terminal command. Apple URLSession and iOS Keychain checks covered password and bearer authentication, refusal, streaming, history and reconnect. Native UI checks covered both login modes, typing/sending, close/reopen and a second send. An active-reconnect check preserved row identities and an unsent draft.

These are native simulator and loopback integration results. They do not claim a physical iPhone/Tailscale trial, real-provider latency measurement, production host activation, or APNs delivery. No host, plugin, relay or cloud rollout is included in this source change.
