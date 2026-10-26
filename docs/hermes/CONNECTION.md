# Hermes connection, authentication and wire transport

This is a platform-neutral description of the direct Hermes transport implemented in bighelp, reviewed at app source revision `09fc79c01aed91734e8006b5355209a31c52feca`. It is intended for Android/Kotlin and React Native/Expo implementations. Route and field names are literal. Credentials, addresses, IDs and dates in examples are synthetic.

The host remains the authority for authentication, sessions and capabilities. **Wire contract** below means a contract the app consumes or a repository probe exercises; **client policy** means a defensive limit or behavior of this app. These limits are useful parity targets, not a statement that every Hermes version enforces the same ceilings. This repository is a client implementation, not a complete upstream server specification.

Start from [Native transport](../NATIVE_TRANSPORT.md). For session identity, streaming and recovery see [Chat](CHAT.md); for plugin context guards see [Extensions](EXTENSIONS.md); for server-request business payloads and device tools see [Groups and device tools](GROUPS_AND_DEVICE_TOOLS.md). [Porting](PORTING.md), [Reference](REFERENCE.md) and [Conformance](CONFORMANCE.md) cover implementation planning, the wider surface and validation.

## 1. Endpoint identity and URL construction

**Client policy.** Save one validated base endpoint, including an optional deployment prefix. Append every application-owned route to its path; a URL resolver that treats `/api/status` as replacing the prefix is incorrect.

```text
input:       HERMES.EXAMPLE:443/hermes/
normalized:  https://hermes.example/hermes
status:      https://hermes.example/hermes/api/status
dashboard:   https://hermes.example/hermes/
gateway:     wss://hermes.example/hermes/api/ws
```

Normalization and validation are applied again when reading saved data:

- Input is nonempty, at most 2,048 UTF-8 bytes, already trimmed, with no whitespace/control characters below U+0021, DEL or backslash.
- Missing scheme means `https://`. An unbracketed IPv6 literal with no path or port is bracketed before adding that scheme. Only `https` and `http` are accepted. The gateway uses `wss` and `ws`, respectively.
- Reject embedded username/password, query, fragment, missing host, percent escapes in the authority, an empty port, and ports outside 1–65,535. Lowercase scheme and host, remove explicit port 443 for HTTPS or 80 for HTTP, and remove the final slash.
- Accept ordinary IPv4/IPv6 literals or ASCII DNS labels of 1–63 bytes, at most 253 bytes total. DNS labels contain letters, digits or `-`, with no initial/final dash. Empty labels, trailing dots, IPv6 zone IDs and numeric IPv4 aliases such as `127.1`, integer/hex forms and invalid numeric addresses are rejected.
- A base path contains only `/`, ASCII letters/digits and `-._~`. Reject percent encoding, repeated `//`, and path segments `.` or `..`.
- An appended route begins with one `/`, contains no `?`, `#`, `%`, backslash or `.`/`..` segment. Add query values separately with a proper query encoder. Do not allow caller-supplied absolute URLs through this function.

The normalized URL string is the endpoint identity. Scheme, effective port and prefix are part of it. Credentials for `/hermes-a` are not credentials for `/hermes-b`, even at the same origin.

### Plain HTTP policy

**Client policy.** HTTPS is the default. HTTP requires an explicit private-network opt-in and a syntactically private host; DNS resolution never authorizes HTTP.

| Accepted with private HTTP opt-in | Exact scope |
| --- | --- |
| IPv4 loopback | `127.0.0.0/8` |
| Private IPv4 | `10/8`, `172.16/12`, `192.168/16` |
| Shared address space / Tailscale | `100.64/10` |
| IPv4 link-local | `169.254/16` |
| IPv6 | `::1`, unique-local `fc00::/7` |
| Single-label DNS | For example `hermes` |
| DNS suffixes, matched on a label boundary | `.local`, `.lan`, `.internal`, `.home.arpa`, `.intranet`, `.corp`, `.localdomain`, `.private`, `.localhost`, `.ts.net`, `.beta.tailscale.net` |

Public HTTP remains rejected after opt-in. This policy does not include arbitrary IPv6 link-local addresses or IPv4-mapped IPv6 aliases. `hermes.lan.example.com`, `127.0.0.1.example.com`, `example-ts.net` and the public name `tailscale.net` do not qualify.

Source: [endpoint, saved connection and wire types](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift). Tests: [endpoint normalization and private HTTP](../../BighelpTests/DirectHermesEndpointTests.swift).

## 2. HTTP security, proxy access and browser boundaries

**Client policy.** Native HTTP uses an isolated memory-only session: no ambient cookie jar, credential store, cache, automatic HTTP login or client certificate. Standard platform certificate validation remains enabled. Do not install an all-trusting TLS verifier to make a host connect.

No native HTTP redirect is followed, including same-origin redirects. Reject 3xx responses except the deliberately inspected `302` from `/auth/native/authorize` in the password flow. The final response URL must equal the requested URL. A proxy redirect to a final HTTPS address requires editing the endpoint; credentials and POST bodies do not follow it.

Ordinary native HTTP requests set:

```http
Accept: application/json
Cache-Control: no-store
Content-Type: application/json
```

`Content-Type` is present when a JSON body is sent; bootstrap HTML uses `Accept: text/html`. Route-specific multipart/binary transports have their own content headers. No Hermes `Origin` header is explicitly synthesized by this client. Custom `Origin` is forbidden. This does not establish what every platform adds automatically or the server's full browser CORS/origin allowlist; verify that behavior for a new runtime.

### A gate in front of Hermes is a separate credential

| Gate | Header contract | Client policy |
| --- | --- | --- |
| Cloudflare Access service token | `CF-Access-Client-Id`, `CF-Access-Client-Secret` | Both values trimmed, nonempty, at most 512 bytes, printable ASCII without spaces; HTTPS only |
| Reverse-proxy Basic auth | `Authorization: Basic BASE64(UTF8(username + ":" + password))` | Trim username; 1–256 UTF-8 bytes, no colon/control; preserve password spaces, 1–512 UTF-8 bytes, no control; HTTPS or approved private HTTP |
| Custom proxy headers | User-supplied header name/value pairs | Exact endpoint only, HTTPS or approved private HTTP; see bounds below |

Gate credentials and custom headers are applied to native HTTP and explicitly to WebSocket upgrades. They are stored separately from Hermes account credentials and are captured when the HTTP transport is created; recreate the connection after changing them. New setup stages them in memory and commits them only after a successful gateway connection.

There is only one HTTP `Authorization` header. A Hermes Bearer request sets that header itself, so a Basic proxy and gated Hermes Bearer auth cannot be assumed to compose. This code has no second-header scheme or credential forwarding negotiation to solve that collision. Cloudflare/custom nonreserved headers can coexist with Hermes Bearer auth.

Custom headers are limited to 16, with case-insensitive unique RFC token names at most 128 UTF-8 bytes. Values are trimmed, nonempty, at most 4,096 UTF-8 bytes; tab, visible ASCII and Unicode U+0080 upward are accepted, while CR/LF and ASCII controls are rejected. Reserved names are `Host`, `Authorization`, `Proxy-Authorization`, `Cookie`, `Content-Type`, `Content-Length`, `Content-Encoding`, `Transfer-Encoding`, `Connection`, `Upgrade`, `Keep-Alive`, `TE`, `Expect`, `Accept`, `Accept-Encoding`, `Cache-Control`, `Range`, `If-Match`, `If-None-Match`, `Origin`, and names beginning `Sec-`, `X-Loopdy-`, `X-Hermes-` or `CF-Access-` (case-insensitive).

Cloudflare denial detection recognizes a redirect to `cloudflareaccess.com` or a subdomain. If a service token was supplied, HTTP 401/403 plus `text/html` and `CF-RAY` is also treated as Access denial. A JSON HTTP 400 whose `detail` starts `Invalid Host header` is a Hermes hostname rejection. HTML returned for a successful `/api/status` or HTTP 400 indicates a web page answered instead of Hermes. Do not display the returned HTML/body as a diagnostic.

The system browser is a distinct security context. Native proxy headers are not injected into browser navigation; browser cookies are not read, copied or persisted by the native client. Browser sign-in through a gate must work in that browser on its own. The browser is expected to follow its normal provider/login redirects; the native no-redirect rule applies to the native HTTP transport.

Sources: [HTTP/authentication](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [access credentials and custom headers](../../Bighelp/DirectHermes/DirectHermesAccessCredentials.swift), [access tests](../../BighelpTests/DirectHermesAccessCredentialsTests.swift).

## 3. Discover the host's authentication mode

Before submitting Hermes credentials or opening a browser:

```http
GET /api/status
```

```json
{"auth_required":true,"auth_flows":["cookie","native_pkce"]}
```

`auth_required` must be Boolean. Missing/null `auth_flows` means an empty list; when present it must be at most 32 unique, nonempty strings, each at most 128 UTF-8 bytes. Preserve unknown flow names. The native PKCE flow is offered only when `auth_required == true` and the list contains exactly the string `native_pkce`.

When native PKCE is available, optional picker enrichment uses:

```http
GET /api/auth/providers
```

```json
{"providers":[{"name":"basic","display_name":"Password","supports_password":true}]}
```

**Client policy.** Accept at most 64 providers with unique, nonempty printable nonspace ASCII names at most 256 bytes; `supports_password` is required Boolean. `display_name` defaults to `name`, must be nonempty, at most 512 UTF-8 bytes and contain no control characters. An unavailable/malformed provider list does not invalidate a status-advertised browser flow. It does prevent guessing which password provider to use. Explicit browser provider names have a tighter 128-byte printable ASCII limit.

Discovery sends no Hermes token, password or browser cookie. Configured proxy gate headers still apply. Neither release version nor a build string grants a feature: query actual capability APIs after connecting.

The workspace's authenticated readiness check uses `GET /api/health` (16,384-byte response budget) and requires `{"ok":true,"auth_required":BOOLEAN}`. This is distinct from public `/api/status` discovery and from the socket's `gateway.ready`. It then requests `gateway.capabilities` with `{}`. The consumed result contains a required Boolean `per_session_exclusive_submit`:

```json
{"jsonrpc":"2.0","id":"client-capabilities-query","method":"gateway.capabilities","params":{}}
```

```json
{"jsonrpc":"2.0","id":"client-capabilities-query","result":{"per_session_exclusive_submit":true}}
```

This current client enables ordinary prompt submission, queuing and slash-command admission only when that Boolean is true. False still permits its independently supported reads, prompt responses and session controls. Missing/non-Boolean is invalid. Do not infer submission safety from a host version, from HTTP success, or from the separate `client.capabilities` server-request handshake.

| Host mode | Chosen input | Credential interpretation and result |
| --- | --- | --- |
| `auth_required: false` | Automatic dashboard connection | Fetch the dashboard's own session token; save as automatic dashboard session |
| `auth_required: false` | Entered token | Dashboard session token; save as manual dashboard session; no provider identity is invented |
| `auth_required: true` | Entered token | Provider-issued access token; verify with `/api/auth/me`; no refresh token is inferred |
| `auth_required: true` and `native_pkce` | Username/password | Native PKCE password flow through a password-capable provider |
| `auth_required: true` and `native_pkce` | Browser | Native PKCE browser flow; omit `provider` to let the stock host choose |

Password/browser inputs on an ungated host are unsupported. Automatic dashboard input on a gated host fails as mode changed. On restore/reconnect, rediscover the mode and reject a transition between dashboard and provider auth rather than submitting the old credential under another auth mechanism.

Source: [discovery and sign-in](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift). Capability source: [gateway manifest](../../Bighelp/DirectHermes/DirectHermesCapabilityManifest.swift). Tests: [capability/parity](../../BighelpTests/DirectHermesProtocolParityTests.swift).

## 4. Ungated dashboard bootstrap and manual tokens

For automatic ungated connection, fetch `GET /` at the approved base prefix with `Accept: text/html`. Require successful HTTP and HTML content type. Parse only inert assignments inside script elements:

```html
<script>
window.__HERMES_SESSION_TOKEN__ = "synthetic-dashboard-token";
window.__HERMES_AUTH_REQUIRED__ = false;
</script>
```

Require exactly one matching token assignment and exactly one matching auth-mode assignment with value `false`. Decode the double-quoted token as a JSON string. Never execute JavaScript, load page resources, evaluate arbitrary HTML, accept a token from a gated page or scrape an unrelated variable. Bootstrap HTML is bounded to 1 MiB and valid UTF-8.

**Client policy.** Session/access/refresh tokens are nonempty, at most 16,384 UTF-8 bytes and printable ASCII U+0021–U+007E. Do not trim a token into a different credential. Automatic dashboard tokens are read again at restore/reconnect and may change after host restart. Manual dashboard tokens are not silently replaced by bootstrap.

Ungated REST authentication uses `X-Hermes-Session-Token: TOKEN`. No dashboard cookie is created. Gateway authentication is completed by receipt of `gateway.ready`, not merely by finding the token in HTML or receiving HTTP 101.

The saved `legacyLoopbackToken` variant is a restricted compatibility path: literal loopback only, explicit private HTTP opt-in, no provider/user fields. It uses the same session header/query mechanics. New ungated sign-ins create dashboard sessions; legacy loopback is not a fallback for gated hosts or arbitrary private hosts.

Source: [dashboard bootstrap and session validation](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [saved credential variants](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift). Refresh behavior: [sign-in renewal tests](../../BighelpTests/DirectHermesSignInRenewalTests.swift).

## 5. Gated access tokens and native PKCE

### Verify a provider access token

```http
GET /api/auth/me
Authorization: Bearer ACCESS_TOKEN
```

```json
{"provider":"basic","user_id":"synthetic-user","expires_at":1900000000}
```

Require nonempty `provider` and `user_id`. `expires_at`, when numeric, is Unix seconds, not milliseconds. A manually entered access token may have no returned expiry and never acquires a refresh token by inference. Subsequent restore/reconnect identity verification must match both provider and user ID exactly as UTF-8, with no Unicode normalization or case folding.

### Common PKCE material and token response

Generate independent cryptographically random verifier and state values. The current client uses 32 random bytes each, encoded as unpadded base64url. Compute:

```text
challenge = BASE64URL_NO_PADDING(SHA256(UTF8(verifier)))
code_challenge_method = "S256"
```

Both password and browser flows redeem a code at the same exact host/prefix:

```http
POST /auth/native/token
Content-Type: application/json
```

```json
{"code":"one-use-code","code_verifier":"saved-transient-verifier"}
```

The successful response, also used by refresh, is:

```json
{
  "token_type":"Bearer",
  "access_token":"synthetic-access",
  "refresh_token":"synthetic-refresh",
  "provider":"basic",
  "user_id":"synthetic-user",
  "expires_at":1900000000
}
```

`token_type` must be exactly `Bearer`; `expires_at` must be numeric and in the future when accepting a minted session. Empty/missing `refresh_token` means no refresh capability. Validate tokens and save the verified provider/user coordinate with them. Provider IDs are at most 128 bytes, user IDs at most 512, neither empty, padded by whitespace or containing ASCII control/DEL. After token exchange, call `/api/auth/me` and require its identity to match the minted session and any explicitly selected provider.

The code is a one-use mutation. Do not retry it after a lost/uncertain response. The browser path explicitly reports token-exchange uncertainty after connection loss, timeout, cancellation, disconnect, malformed response or response overflow; start a new sign-in attempt. The password path also has no exchange retry loop.

### Password-capable provider flow

Select an explicit advertised provider with `supports_password: true`, or require exactly one such provider. Zero is unsupported; multiple without a selection is ambiguous. The current username limit is 1–1,024 UTF-8 bytes and password limit 1–16,384 bytes.

1. `GET /auth/native/authorize` with separately encoded query values:

   ```text
   provider=basic
   code_challenge=CHALLENGE
   code_challenge_method=S256
   redirect_uri=http://127.0.0.1:49152/loopdy-native-callback
   state=STATE
   ```

2. Inspect, without following, an HTTP `302`. Resolve `Location` relative to this authorize URL and require it to equal the exact endpoint's `/login` URL, including prefix and no added query/fragment. Capture only the expected short-lived PKCE cookie.
3. `POST /auth/password-login` with that cookie and this JSON:

   ```json
   {"provider":"basic","username":"synthetic-user","password":"synthetic-password","next":""}
   ```

4. Require successful JSON `{"ok":true,"next":"http://127.0.0.1:49152/loopdy-native-callback?state=STATE&code=CODE"}`. The query must contain exactly one `state` and one nonempty `code`, no other parameters. Check exact state; remove the query and require the remaining callback URL to equal the chosen callback exactly. No listener is needed for this flow: inspect the JSON locally.
5. Redeem the code once, verify `/api/auth/me`, then accept the saved session. Never save the password or the PKCE cookie.

The fixed callback port/path above is this client's password-flow choice, not a requirement to bind port 49152 or a requirement for browser sign-in to use it.

PKCE cookie selection depends on scheme and deployment prefix:

| Base endpoint | Required cookie name | Required cookie path |
| --- | --- | --- |
| HTTPS, no prefix | `__Host-hermes_session_pkce` | `/` |
| HTTPS, `/hermes` prefix | `__Secure-hermes_session_pkce` | `/hermes` |
| Approved HTTP, no prefix | `hermes_session_pkce` | `/` |
| Approved HTTP, `/hermes` prefix | `hermes_session_pkce` | `/hermes` |

Require exactly one cookie of the expected name, exact endpoint host/domain after lowercasing/bracket removal, exact path, `Secure` for HTTPS, and an explicit unexpired expiry. Value is nonempty, at most 8,192 bytes, limited to ASCII letters, digits, `-`, `_`, `=`. Send only `Cookie: EXPECTED_NAME=VALUE` on the password POST. Do not accept similarly named cookies, import the rest of `Set-Cookie`, or keep a persistent native cookie jar.

### Browser provider flow

Bind a local TCP listener to `127.0.0.1` on an OS-selected ephemeral port before opening the browser. Use a per-attempt random path such as `/loopdy-native-callback/RANDOM`. Then open the approved endpoint's `/auth/native/authorize` with `code_challenge`, `code_challenge_method=S256`, the exact loopback `redirect_uri`, `state`, and optional `provider`. Omitting provider deliberately invokes the host chooser. A host advertisement of `native_pkce` alone does not prove a particular system browser can reach the app's loopback listener.

Only a validated HTTP request received by the listener supplies the code. Ignore arbitrary browser completion URLs. The present implementation does not replace HTTP with an invented custom-scheme callback or extract browser cookies.

**Current callback validation policy:**

- One ASCII `GET PATH?state=STATE&code=CODE HTTP/1.1` request with strict CRLF framing; header block at most 16,384 bytes. No request body, extra bytes after the header, pipeline, folded headers or malformed line endings.
- Exact `Host: 127.0.0.1:PORT` and exact randomized path. Case-insensitive unique header names; 4–68 total CRLF-split lines including the final two empty lines.
- No `Transfer-Encoding`, `Expect`, `Upgrade` or `Trailer`; `Content-Length` must be absent or exactly `0`.
- Exactly two unique query fields, `state` and `code`, in either order. Percent-decode strictly; decoded keys/values must be nonempty base64url-token characters `[A-Za-z0-9_-]`, at most 4,096 bytes each. `+` is not treated as space. Require exact state.
- Malformed/favicons/slow requests close their connection without consuming the sign-in. At most four simultaneous connections, five seconds to provide a request, ten seconds to start the listener and 600 seconds for browser sign-in.
- Once code is captured, other readers stop. Flush a static no-store success page, with a two-second flush deadline, then deliver the code exactly once. Do not reflect the code, state or provider text into HTML. A late browser cancellation must not erase a code already captured. Explicit retirement of the owning sign-in/host may invalidate the attempt.

Cancel listener/browser/transient state when the host, account, view or owning task is retired. The browser listener is device-local, unrelated to the remote Hermes listener. Kotlin can implement this with native networking and a system browser. Expo implementations must demonstrate the necessary loopback/native/browser composition in the intended build; a generic web auth-session API is not evidence that this exact callback contract works.

Sources: [all auth flows](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [browser callback/listener state](../../Bighelp/DirectHermes/DirectHermesBrowserAuthentication.swift). Evidence: [browser tests with a synthetic broker and real loopback listener](../../BighelpTests/DirectHermesBrowserAuthenticationTests.swift), [disposable stock-host password/ticket probe](../../Scripts/DirectHermesAuthenticationProbe.py). The synthetic broker test does not prove real external-provider sign-in on Android or Expo.

## 6. Secure persistence and rotating renewal

Persist one credential record bound to the normalized endpoint and authentication principal. The current record schema is version 1 and includes an immutable credential-endpoint identity. Reject an unknown schema, changed endpoint binding, unexpected provider/user on a dashboard credential, or incomplete provider identity on a Bearer credential. A dashboard authority is scoped to endpoint; a provider authority is scoped to endpoint + exact provider + exact user ID.

**Client policy.** Credentials are device-local secure storage, with no preference/log copies, cloud sync, extension sharing or backup migration. The current iOS vault is readable after first unlock and caps a record at 65,536 bytes. Android/Expo need an equivalent protected store and deliberate background-access policy; the iOS Keychain class is not a network requirement. Save/read back a replacement before considering persistence complete. Superseded account/host owners must not overwrite or recreate retired credentials.

Every token rotation uses a durable compare-and-replace: the saved record must still equal the old record. A stale UI snapshot or concurrent owner must fail rather than saving its old refresh token again. Initial sign-in persistence happens only after gateway readiness and the host-selection generation check; a cancelled/replaced Connect must not replace another selected host.

Refresh is single-flight per authenticator. Expiry within 30 seconds triggers proactive renewal; restore also verifies identity and renews if `/api/auth/me` returns invalid credentials. A manually entered token with no refresh capability eventually needs a new sign-in.

```http
POST /auth/native/refresh
Content-Type: application/json
```

```json
{"refresh_token":"synthetic-refresh","provider":"basic"}
```

Rotation algorithm:

```text
join an existing refresh flight if one exists
read current credential and exact principal
POST /auth/native/refresh        (the saved credential keeps its refresh token)
on 2xx: validate minted session and unchanged principal
        compare-and-replace the old record with the new credential
on 401: compare-and-replace the record with one that has no refresh token; require a new sign-in
on anything else (503, 429, a proxy 5xx, a network error, a timeout, cancellation):
        change nothing; the next attempt sends the same refresh token again
```

The refresh token is dropped only when Hermes answers 401. Hermes coalesces repeat refreshes for 30 seconds (the same token gets the same answer), and after a lost answer a resend cannot do worse than the sign-out that dropping the token would force; Hermes Desktop keeps its token the same way. A resend may come from the same authenticator, a new one after a reconnect, or the next launch. A stale authenticator never overwrites a newer record: the compare-and-replace fails first, whatever the host answered.

Authenticated JSON HTTP performs one narrowly defined retry: on HTTP 401 **without** `WWW-Authenticate`, renew the Bearer token, or rebootstrap an automatic dashboard token that changed, and resend once. If another concurrent request already installed a new credential, use that one. This relies on the Hermes contract that auth refusal happens before route execution. A 401 with `WWW-Authenticate` is a proxy challenge, not this retry path. Other HTTP failures are not retried here. Dedicated multipart/binary transfers do not inherit this generic JSON retry loop.

Disconnect gives an already dispatched refresh up to eight seconds to settle before invalidating the network session, and the renewal may still save its new sign-in during that wait. Optional plugin-driven background renewal described in [Native transport](../NATIVE_TRANSPORT.md), and the iPhone app's own Background App Refresh renewal (`BighelpSignInBackgroundRenewal`, every few hours at iOS's pace), are separate from the transport contract and are not guaranteed by mobile background execution.

Sources: [refresh, identity and authenticated HTTP](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [credential vault](../../Bighelp/DirectHermes/DirectHermesCredentialVault.swift), [rotation compare-and-save](../../Bighelp/DirectHermes/DirectHermesNetworking.swift). Tests: [renewal, outage, lost reply and background cases](../../BighelpTests/DirectHermesSignInRenewalTests.swift).

## 7. WebSocket authentication

### Main gateway

For an ungated dashboard session:

```http
GET /api/ws?token=URL_ENCODED_DASHBOARD_TOKEN
X-Hermes-Session-Token: DASHBOARD_TOKEN
Upgrade: websocket
```

The query and header both carry the same token in this implementation. The restricted legacy loopback variant uses the same shape. No Hermes browser cookie is added.

For a gated Bearer session, mint a fresh ticket for **every socket attempt and reconnect**:

```http
POST /api/auth/ws-ticket
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json

{}
```

```json
{"ticket":"synthetic_urlsafe_ticket","ttl_seconds":30}
```

**Client validation:** nonempty ticket, at most 4,096 ASCII bytes `[A-Za-z0-9_-]`; numeric TTL greater than zero and at most 300 seconds. The example TTL is illustrative; use the returned value. Mint-on-401 may refresh once and mint again. Do not reuse, persist or cache a ticket for a later socket.

```http
GET /api/ws
Sec-WebSocket-Protocol: hermes-gateway-v1, hermes-gateway-ticket.TICKET
Upgrade: websocket
```

The disposable stock-host probe verifies negotiation of `hermes-gateway-v1`, rejection of ticket reuse and rejection of an ungated legacy session token on a gated host. Do not place a provider Bearer token in the gateway query, substitute an old ticket or interpret a raw dashboard token as a gated access token. Proxy gate headers still apply to the upgrade.

### Separate sockets have separate credentials

| Socket | Route/query authentication |
| --- | --- |
| Gateway JSON-RPC | `/api/ws`; dashboard `token` plus header, or fresh ticket in subprotocols as above |
| Buffered-to-stream speech | `/api/audio/speak-stream?profile=PROFILE&ticket=FRESH_TICKET` for Bearer, or `profile=PROFILE&token=DASHBOARD_TOKEN` |
| Kanban read-only events | `/api/plugins/kanban/events` with validated board/cursor query and its own fresh `ticket`, or dashboard `token` |
| Bot Screen RFB | `/api/display/ws?display_ticket=DISPLAY_TICKET`; only the separate single-use ticket from `display.observe`, not the gateway token/ticket |

Speech/Kanban upgrades disable native cookies, set `Cache-Control: no-store` and carry proxy access headers. Their payloads are not the gateway JSON-RPC stream. Bot Screen's source describes a 30-second display ticket; see [device tools](GROUPS_AND_DEVICE_TOOLS.md) for observation/control semantics. Preserve the endpoint prefix on every socket route.

Sources: [gateway/speech/Kanban ticket requests](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [display socket](../../Bighelp/DirectHermes/DirectHermesBotScreenStream.swift), [single-use ticket probe](../../Scripts/DirectHermesAuthenticationProbe.py).

## 8. Gateway JSON-RPC envelopes and framing

Send UTF-8 JSON text messages. Each outbound request is one JSON object with `jsonrpc: "2.0"`, a client-generated string ID, method and object params:

```json
{"jsonrpc":"2.0","id":"client-request-1","method":"gateway.ping","params":{}}
```

The present client uses UUID strings for its own IDs. Do not require server-authored IDs to be UUIDs. An RPC reply uses the exact string ID and exactly one result or error branch:

```json
{"jsonrpc":"2.0","id":"client-request-1","result":{"ok":true}}
```

```json
{"jsonrpc":"2.0","id":"client-request-1","error":{"code":4090,"message":"Active session limit reached","data":{"reason":"MAX_CONCURRENT_SESSIONS"}}}
```

`result` can be any JSON value including null. `error` must be an object with an integer `code`; `message` is optional for incoming errors, and optional object `data.reason` is retained for semantic handling. Replies cannot contain `params`, `method`, both `result` and `error`, or a non-string ID. A late/unknown but valid reply ID is ignored because it has no pending owner.

### Newline batches, not JSON-RPC array batches

One received WebSocket message may contain multiple newline-delimited JSON objects. Process objects in order. Both WebSocket text and binary messages are accepted by this client as JSON bytes; binary messages are not a separate binary gateway protocol. WebSocket fragmentation should be reassembled by the socket library before this decoder runs.

```text
{"jsonrpc":"2.0","id":"client-request-1","result":{}}
{"jsonrpc":"2.0","method":"event","params":{"type":"session.info","session_id":"runtime-1","payload":{"running":false},"seq":7}}
```

Split on LF, ignore empty/space/tab/CR-only lines, and require at least one object. Each nonblank line is a complete JSON object; literal newlines cannot occur inside JSON strings. A pretty-printed multiline object and a JSON array batch do not satisfy this decoder. Validate the **whole received message** before delivering any entry, then dispatch each entry in wire order. Do not run independent frame decoders concurrently and reorder callbacks.

The current generic JSON value decoder preserves integers separately from floating-point numbers, accepts only finite numeric values, and does not coerce strings/booleans into numbers. Preserve integer cursors/IDs without JavaScript precision loss when porting; this transport does not establish that all host integers fit JavaScript's safe-integer range.

### Events

Backend notifications use only `method: "event"`, no `id`, and object `params`:

```json
{
  "jsonrpc":"2.0",
  "method":"event",
  "params":{
    "type":"gateway.ready",
    "payload":{"heartbeat":true,"replay_epoch":"synthetic-epoch"}
  }
}
```

`params.type` is a required nonempty string, at most 256 UTF-8 bytes. `payload` is optional and defaults to `{}`, but when present must be an object, not null. `session_id` may be absent/null or a string. `seq` may be absent or an integer; null/fractional is invalid. Preserve the complete original `params`, including future metadata, alongside decoded fields. Unknown well-formed event types can be passed onward; a non-`event` method without a string ID is malformed, not an ignorable notification.

`gateway.ready` is the application handshake. The transport consumes its heartbeat hint, and the workspace consumes `payload.replay_epoch` for session recovery. Fields in the example are not all mandatory at the frame decoder; business capability/recovery layers validate their required fields separately.

Sources: [wire decoder/encoder and server-request state](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [ordered reader and request writer](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [JSON value model](../../Bighelp/Workspace/BighelpJSONValue.swift). Tests: [protocol parity](../../BighelpTests/DirectHermesProtocolParityTests.swift); probe: [stock protocol readiness](../../Scripts/DirectHermesProtocolProbe.py).

## 9. Server-to-client requests and cancellation

A non-`event` method with a string ID is a live server request, even when this client has no handler for its method:

```json
{"jsonrpc":"2.0","id":"server:opaque-id","method":"approval","params":{"session_id":"runtime-1"}}
```

`params` may be an object, absent or null; absent/null become `{}`. Preserve server IDs as opaque UTF-8 strings, including empty strings, whitespace and canonically equivalent but byte-distinct Unicode. The current limit is 1,024 UTF-8 bytes. Never trim, normalize, case-fold, parse as a UUID or allocate a replacement ID. Keep server request ownership separate from client request IDs so an ID collision cannot turn a prompt into a client RPC reply.

Register handlers before advertising capability. On every ready socket, including reconnect:

```json
{"jsonrpc":"2.0","id":"client-capabilities-1","method":"client.capabilities","params":{"server_requests":true}}
```

The current host behavior described in the repository requires this handshake to deliver clarify/approval/secret/sudo requests to the client; otherwise the host may answer them itself with blank values. Only advertise when real handlers exist. An RPC rejection from an older host is tolerated. Registration alone does not imply successful handshake, and a transport failure permits a later attempt.

Respond with the original ID using a **response envelope**, never a new request:

```json
{"jsonrpc":"2.0","id":"server:opaque-id","result":{"accepted":false}}
```

```json
{"jsonrpc":"2.0","id":"server:opaque-id","error":{"code":-32601,"message":"Method not supported by this client"}}
```

The result example illustrates framing only; each method has its own business response schema. Unsupported methods receive `-32601`. The transport must not make approval choices, supply secrets or invent device/window content. If a handler result cannot be encoded within limits, a constant `-32603` error is used. Error responses have a required nonempty message, at most 4,096 UTF-8 bytes, and optional arbitrary JSON `data`.

**Client policy.** At most 64 live server requests; duplicate byte-identical IDs do not create a second UI decision/response, and requests arriving at capacity are ignored rather than unboundedly queued. Handlers run independently, so one user decision cannot block the socket reader or another prompt. A queued response stays cancellable until it is selected for its socket send; once sending begins, the request is retired. A later repeated ID after retirement is not covered by the live deduplication table.

Cancellation is an event with an exact payload shape:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"request.cancel","payload":{"id":"server:opaque-id","method":"approval","reason":"expired"}}}
```

Require exactly `id`, `method`, `reason`; valid ID/method and string reason at most 4,096 bytes. Match both the opaque ID and method before cancelling the handler/removing its queued response. A cancellation for another method cannot retire this request. Late completion after cancellation, host/account retirement or socket-generation change must not send a stale answer. Do not interpret a local cancelled RPC as a host `request.cancel` or as an instruction to interrupt an agent.

Recovery can return `session.events.since.open_requests`. Each row must contain exactly `id`, `method`, `params`, and `params.session_id` must match the recovered runtime. Validate the entire snapshot before adopting rows into the same request-dispatch state. It is not a second independent prompt store. Old socket in-flight responses are cleared on reconnect; authoritative open requests can be offered again through recovery.

Frame coverage exists for `approval`, `clarify`, `mcp.setup`, `preview.act`, `preview.read`, `secret`, `sudo`, `terminal.read`, `tour`, `vault.code`, `vault.save_login`, `vault.unlock_prompt`, and `window.read`. Frame acceptance does not mean this app implements every such tool; see [Groups and device tools](GROUPS_AND_DEVICE_TOOLS.md).

Sources: [server-request framing/state](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [handlers, handshake and adopted snapshots](../../Bighelp/DirectHermes/DirectHermesNetworking.swift). Tests: [opaque IDs, cancellation, capacity and method frames](../../BighelpTests/DirectHermesProtocolParityTests.swift).

## 10. Connection lifecycle, keepalive and reconnect

```text
validate endpoint
  -> discover mode -> authenticate/verify exact principal
  -> mint a new WS ticket when gated
  -> start socket + ordered reader
  -> wait for event gateway.ready
  -> mark connected, start writer/heartbeat
  -> advertise server-request handlers
  -> discover gateway capabilities + recover owned sessions
```

**Client policy.** Gateway readiness has a 20-second deadline. HTTP 101 alone does not make the connection usable. A second `gateway.ready` on an already connected socket is treated as invalid. Server requests can arrive before ready in the same received batch: process them, but defer their response sends until ready. A new event consumer receives the retained initial ready event so it cannot miss epoch/capability metadata.

Outgoing requests are serialized through one writer and have separate pending continuations/deadlines. Replies/events/server requests can interleave. Mark an RPC as potentially sent **before** awaiting the socket library's send call: a failed send does not prove the server received no bytes. A generic request deadline is 45 seconds from enqueue, not from the server starting execution.

### Keepalive budgets

| Action | Current client budget |
| --- | --- |
| Periodic `gateway.ping {}` when ready advertises `payload.heartbeat: true` | Every 15 seconds |
| Periodic ping without that hint | Every 20 seconds |
| Periodic ping reply deadline | 15 seconds |
| Foreground/network-change liveness check | 4 seconds |
| Pre-admission connection proof | 5 seconds; can await recovery and check once again |
| `client.capabilities` reply deadline | 15 seconds |

These are application RPC pings, not a claim about mandatory WebSocket control-frame ping/pong. Any RPC rejection proves the socket answered: the current keepalive layer treats it as unsupported and stops the periodic ping loop. A transport failure or unanswered ping retires the socket and can trigger recovery. Do not treat a method-not-found ping response as loss of connectivity.

### Disconnect and recovery rules

On a socket failure, rotate the socket generation, clear readiness/reader/writer/heartbeat/outbox, cancel server handlers and discard queued server responses. Complete pending client RPCs with an error; do not copy their frames into the replacement socket. Responses from obsolete generations cannot publish into the new owner.

The current transport attempts automatic recovery with delays **0, 1 and 3 seconds** when a socket existed and no remaining pending mutation is already potentially sent. Reconnect is single-flight, rechecks auth mode/session, and obtains a new ticket. Retain registered server-request handlers across this same-owner recovery and advertise again after ready. After exhausted attempts, clear handlers and report the final disconnect.

If pending work includes a potentially sent mutation, the transport refuses to hide its uncertain outcome behind automatic replay. A session owner may explicitly reconnect and reconcile authoritative state; the mutation itself is not resent. Explicit `disconnect()` is terminal for this client object; a new restore/connect is needed afterward.

Read-only classification is a conservative current-client allowlist. Unknown methods are treated as mutations:

```text
gateway.ping, session.list, session.active_list, session.history,
session.status, session.usage, session.events.since, commands.catalog,
config.get, delegation.status, spawn_tree.list,
profiles.list, profiles.describe, profiles.get_asset, model.options,
projects.list, projects.get, subagent.list, subagent.tail, client.capabilities,
groups.capabilities, groups.list, groups.state, groups.log, pet.gallery, pet.thumb
```

This list controls uncertainty reporting; it is not a universal catalog of all read-only host APIs. Cancellation before send means the request is removed locally. Cancellation after send may leave a mutation running remotely. Timeout after send also closes the socket to unpark a stalled writer. Neither is an implicit `session.interrupt` or permission to replay.

Socket readiness does not reattach a session. Workspace recovery owns durable stored-session resume, runtime-ID replacement, event epoch/cursor catch-up, snapshots, prompt restoration and admission reopening; see [Chat](CHAT.md). A transport must not issue a new `prompt.submit`, create another session, take over another process's runtime or switch to an alternate cloud queue just because reconnect succeeded.

Source: [networking lifecycle and keepalive](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [session recovery](../../Bighelp/DirectHermes/DirectHermesConversationClient+Recovery.swift), [durable resume contract](../../Bighelp/DirectHermes/DirectHermesReleaseContract.swift). Tests: [reconnect parity](../../BighelpTests/DirectHermesReconnectParityTests.swift), [live host reconnect scenarios](../../BighelpTests/DirectHermesLiveTests.swift).

## 11. Bounds and failure semantics

The following are **current client budgets** unless a route-specific host contract is stated elsewhere. Check limits before allocating an encoded body and incrementally while receiving data; `Content-Length` alone is insufficient. All byte counts mean UTF-8/wire bytes unless explicitly a decoded media size. MiB means 1,048,576 bytes.

| Boundary | Client limit |
| --- | --- |
| Incoming gateway WebSocket message, including all newline entries | 4 MiB |
| Nonblank JSON objects per gateway message | 4,096 |
| JSON object/array nesting | 64 levels |
| Method name | 1–256 bytes, printable ASCII U+0021–U+007E |
| Server/client reply ID accepted by decoder | String, 0–1,024 bytes |
| Ordinary outgoing RPC | 2 MiB |
| `profiles.set_asset` outgoing RPC | 2,800,000 bytes |
| Validated `file.attach` / `image.attach_bytes` frame | 12 MiB, route/payload-scoped allowance |
| Pending client RPCs | 64 |
| Concurrent attachment RPC admission | One `file.attach` or `image.attach_bytes` |
| Ordinary queued outbound bytes | 8 MiB |
| Attachment request admission queue allowance | 12 MiB |
| One server response | 2 MiB |
| Queued server response bytes | 4 MiB; use a small constant error when full if it still fits |
| Ordinary JSON HTTP body | 1 MiB |
| Generic authenticated JSON HTTP response | Up to 4 MiB; authentication helper calls default to 1 MiB |
| Ordinary HTTP request timeout / whole resource ceiling | 20 seconds / 75 seconds; route timeout clamped to 1–75 seconds |
| HTTP connections per host | Four in the current transport |

Response budgets are route-scoped. Important exceptions from the shared HTTP boundary:

| Route | Allowance |
| --- | --- |
| `POST /api/sessions/import`, `GET /api/sessions/{single-id}/export` | 25 MiB JSON transfer |
| `GET /api/files` | 4 MiB listing |
| `POST /api/audio/transcribe` | `ceil(25 MiB / 3) * 4 + 8,192` request bytes; host accepts 25 MiB decoded audio |
| `POST /api/audio/speak` | `ceil(8 MiB / 3) * 4 + 8,192` response bytes |
| Validated `GET /api/media?path=…` images, delivered files via `GET /api/files/read?path=…` | `ceil(25 MiB / 3) * 4 + 8,192` response bytes |
| `POST /api/plugins/loopdy/native/attachments/fetch`, `…/image-drafts/source`, no query | 4 MiB + 65,536 response bytes |
| `POST /api/plugins/loopdy/native/board/media`, no query | 12 MiB response bytes |
| `POST /api/plugins/loopdy/native/workspace-files/read`, no query | Same encoded 25 MiB media allowance |
| `POST /api/mcp/servers/{…}/test`, `GET /api/mcp/oauth/flows/{…}` | 16 MiB tool-list response bytes |

The route maximum is a ceiling; each call can request a smaller budget. Multipart/file-backed upload, media, attachment and display protocols have additional type/path/decoded-size/ownership checks. Do not raise the generic JSON limit to accommodate one file route. An outgoing attachment exception does not raise the 4 MiB incoming gateway limit.

### HTTP errors

| HTTP result | Generic interpretation |
| --- | --- |
| 2xx | Success; the route still validates the payload |
| 401, 403 | Invalid credentials, subject to the narrow 401 renewal rule and proxy classification |
| 404, 405 | Unsupported auth/route at this generic boundary |
| 429 | Rate limited |
| 5xx | Server unavailable |
| Other | Invalid response, except route-specific errors |

Cloudflare denial, refused redirects, bad certificates, hostname rejection and HTML-instead-of-Hermes have separate fixed diagnostic categories. A malformed/oversized gateway message retires the connection; do not partially apply preceding entries from that message.

For session PATCH/DELETE, a Hermes `detail` on HTTP 409, or machine-reason detail on 403/404, is retained as a route refusal (for example `revision_conflict`, `stale_generation`, `client_upgrade_required`, `permission_denied`, `not_found`). The same status from a proxy is not proof of such a refusal. A generic non-GET JSON request that fails without a definitive rejection status among `400,401,403,404,405,409,422,429` is reported as **outcome unknown**. Dedicated upload transports have their own definitive-rejection lists and readback procedures.

### RPC errors and unknown outcome

Preserve RPC `error.code`, safe `error.message` and `error.data.reason` separately. In particular, code `4090` plus `reason: "MAX_CONCURRENT_SESSIONS"` is the active-session limit; `4090` alone or `SESSION_NOT_OWNED` is not that limit. Route/session layers may apply further semantics.

Displayable host refusal text is flattened to one line and capped at 280 characters in the current app, labelled as Hermes' words. It is never a substitute for the numeric/machine reason. General transport errors do not expose arbitrary bodies, URLs, tokens or provider text in logs/UI.

Track at least `notSent`, `mayHaveBeenSent`, `confirmedResult`, `confirmedRefusal`. A disconnected/timed-out/cancelled read can be retried by its owner as appropriate. A mutation whose send began and whose response was lost is uncertain even when the socket send call failed. Retain its intent and reconcile host state; a retry requires an operation-specific idempotency/recovery contract, not a transport-wide resend switch.

Sources: [HTTP limits/status mapping](../../Bighelp/DirectHermes/DirectHermesAuthentication.swift), [RPC queues/uncertainty](../../Bighelp/DirectHermes/DirectHermesNetworking.swift), [wire bounds/refusal text](../../Bighelp/DirectHermes/DirectHermesInterfaces.swift), [attachment exception](../../Bighelp/DirectHermes/DirectHermesAttachmentClient.swift), [file frames](../../Bighelp/DirectHermes/DirectHermesFileAttachments.swift). Tests: [transfer budgets](../../BighelpTests/DirectHermesTransferBudgetTests.swift), [media route budgets](../../BighelpTests/DirectHermesGeneratedMediaTests.swift).

## 12. Messaging-platform pairing administration

This is Hermes' administration of approved users on messaging platforms. It is distinct from dashboard sign-in, notification registration and the retired bighelp Link pairing/account system. Do not ask for, display or save a DM pairing code as a Hermes access credential.

All routes use the current authenticated Hermes HTTP connection and explicit profile scope. A profile is nonempty, already trimmed, at most 128 UTF-8 bytes, has no control characters or slash/backslash, and cannot be `all`, `.` or `..`. The current client additionally requires a provider/direct authority for these operations and fences the captured owner before/after every await; dashboard auth support in transport alone does not grant pairing-admin UI capability.

```http
GET /api/pairing?profile=PROFILE
```

```json
{
  "pending":[{"platform":"telegram","request_id":"0123456789abcdef","user_id":"synthetic-user","user_name":"Example","age_minutes":2}],
  "approved":[{"platform":"telegram","user_id":"another-user","user_name":"Other","approved_at":1900000000}]
}
```

Current validation: at most 500 pending and 2,000 approved rows. `platform` is 1–128 ASCII bytes `[a-z0-9_-]`; user IDs are nonempty at most 512 UTF-8 bytes, names may be empty at most 512, and neither may contain NUL. `age_minutes` is a nonnegative integer. `approved_at` may be absent/null or finite nonnegative Unix seconds. Pending `request_id` may be empty for display, but approval requires an exact 16-character ASCII hexadecimal ID. Duplicate nonempty `(platform, request_id)` and duplicate approved `(platform, user_id)` are invalid. Compare IDs byte-exactly.

| Action | Request | Required response/readback |
| --- | --- | --- |
| Approve | `POST /api/pairing/approve`, `{"platform":"telegram","request_id":"0123456789abcdef","profile":"PROFILE"}` | `{"ok":true,"user":{"user_id":"synthetic-user","user_name":"Example"}}`; returned user ID equals selected pending user; reread proves pending exact request disappeared and approved user exists |
| Revoke | `POST /api/pairing/revoke`, `{"platform":"telegram","user_id":"synthetic-user","profile":"PROFILE"}` | `{"ok":true}`; reread proves the exact approved platform/user disappeared |
| Clear pending | `POST /api/pairing/clear-pending?profile=PROFILE`, `{}` | `{"ok":true,"cleared":N}`; `N` equals the pre-read pending count and reread is empty |

Approve/revoke first reread and require the exact selected request/user still exists; otherwise report conflict. Failed/mismatched mutation replies or readbacks are outcome unknown, not success or permission to repeat blindly. Revoke validates its outgoing user ID against control characters as well as length. An empty pending request ID cannot be approved by substituting its user ID.

Source: [pairing client and validators](../../Bighelp/DirectHermes/DirectHermesPairingClient.swift).

## 13. Evidence boundaries and remaining gaps

This document was produced by static source/test/probe inspection. No real host, external identity provider, physical device, Android build or Expo runtime was exercised for this documentation change. Existing live tests/probes describe executable evidence paths, not a fresh passing result.

- The repository's auth probe checks password PKCE, Bearer identity, renewal, authenticated gateway, ticket reuse rejection and gated legacy-token rejection against a disposable stock host. It does not prove every provider/browser/proxy combination or deployment prefix.
- Browser tests prove strict parsing and real device-local TCP callback plumbing with a synthetic opener. Native PKCE advertisement and these tests do not qualify an Android/Expo system-browser composition. Expo Go capability, app process lifecycle and native secure storage must be verified in the intended build.
- This client does not specify the server's complete CORS/origin policy, accepted cookie attributes beyond those it checks, refresh/token/ticket lifetimes for every provider, authentication logout/revocation endpoints, or provider-specific MFA/error pages. Do not invent those fields or APIs from these examples.
- Basic-proxy `Authorization` collides with Hermes Bearer `Authorization`; native custom headers also do not travel into system-browser navigation. Both are integration constraints requiring a concrete tested deployment.
- JSON-RPC array batches, numeric IDs, arbitrary non-`event` notifications, multiline pretty-printed messages and response reuse across sockets are not supported by this client decoder. Server-request frame coverage does not imply business-handler support.
- The client source/probes are the evidence for the 30-second host refresh coalescing statement. Confirm it against the exact upstream host revision before relying on that retry window in an independent client.

Use [Conformance](CONFORMANCE.md) to turn these boundaries into tests, and retain protocol unknowns as explicit unknowns until source or a controlled host verifies them.
