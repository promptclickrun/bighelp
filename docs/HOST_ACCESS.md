# Reaching Hermes behind a proxy or Cloudflare Access

Many people put Hermes behind something that checks requests before Hermes
sees them: Cloudflare Access, a reverse proxy with a password, or a proxy such
as Pangolin that checks its own headers. bighelp can get past each of these,
then signs in to Hermes as usual.

When you add a host, bighelp tries the address first and asks only for what it
finds: a Cloudflare Access login sends you to a **Cloudflare Access** step, and
a proxy asking for a password sends you to a **Password needed** step. Custom
headers, and a way to pick either step yourself, are under **More options**.
Later, change them in **Settings › Hosts › (host) › Advanced connection details ›
Edit access**.

## How bighelp handles these values

- They're stored in the iPhone Keychain for that one host address, on this
  device only (not synced to iCloud).
- They're sent with every request and every live connection (WebSocket) to that
  exact address, and nowhere else.
- bighelp refuses redirects from the host, so a value can never follow a
  redirect to another site.
- Secrets are masked on screen and never written to logs or diagnostics.
- They go only to `https://` addresses, or to a private network address (home
  Wi‑Fi, VPN, Tailscale) that answers over plain HTTP. They never go over plain
  HTTP on the open internet.

## Cloudflare Access (service token)

Use this when Hermes is published through a Cloudflare Tunnel and protected by
Cloudflare Access. The app has no browser session with Cloudflare Access, so
it proves itself with a service token instead.

1. In Cloudflare Zero Trust, open **Access › Service credentials › Service
   Tokens** and choose **Create Service Token**. Copy the
   **Client ID** and **Client Secret**; the secret is shown only once.
2. Open the Access application that protects your Hermes hostname and add a
   policy:
   - **Action:** Service Auth
   - **Include:** Service Token, then pick the token you created

   Keep your other policies (for example your email login) for browsers. A
   Service Auth policy lets the token through without a login page.
3. In bighelp, add the host with its address and tap Continue. bighelp sees
   the Cloudflare Access login and asks for the Client ID and Client Secret.
   (If your Access app refuses instead of showing a login, choose **It's behind
   Cloudflare Access** under **More options**.)

bighelp sends them as `CF-Access-Client-Id` and `CF-Access-Client-Secret`.
Cloudflare Access needs an `https://` address.

**If Cloudflare Access refuses the token**, bighelp says "Cloudflare Access didn't accept
that service token." Check the Client ID and Secret, that the token hasn't
expired or been revoked, and that the application has the Service Auth policy
above.

**If bighelp says Hermes turned it away** ("it answers only to its local
address"), Cloudflare Access let the token through, but Hermes refused the
request. A Cloudflare Tunnel sends the public host name to Hermes, and a
Hermes that listens only on `127.0.0.1` accepts only its local name. Tell
Hermes its public address in `config.yaml`, then restart Hermes:

```yaml
dashboard:
  public_url: "https://hermes.example.com"
```

Hermes then asks for a sign-in on that address, so set up a Hermes username
and password or another sign-in provider first. bighelp shows the sign-in
step after the Cloudflare Access step.

**If bighelp says Cloudflare answered with a web page**, the answer did not
come from Hermes. Check the Service Auth policy above, and check that the
tunnel sends the host name to the Hermes dashboard port (9119 by default).

**Browser sign-in:** Hermes's browser sign-in option opens Safari, which
doesn't carry the service token, so Cloudflare Access shows its own login
there. Sign in to Cloudflare Access in that browser too, or use a Hermes
access token or username and password sign-in instead.

## Username and password on a proxy (basic auth)

For nginx, Caddy, Traefik and similar proxies set up with a username and
password (HTTP basic auth). bighelp notices the proxy asking and shows a
**Password needed** step. To enter them up front, choose **It asks for a
username and password** under **More options**.

A host uses either a Cloudflare Access service token or a proxy username
and password, not both.

## Custom headers

For a reverse proxy that checks its own headers, such as Pangolin or an nginx
rule like `if ($http_x_access_secret != "…") { return 403; }`. Under More
options, choose **Add header** and enter each name and value, for example
`X-Access-Id` and `X-Access-Secret`. They can be combined with a
Cloudflare Access service token or a proxy password.

- Up to 16 headers. Names are letters, numbers and dashes; values can't contain
  line breaks.
- Some names are set by bighelp itself and can't be used: `Authorization`,
  `Cookie`, `Host`, `Content-Type` and other standard request headers,
  `Sec-*` (WebSocket), `X-Hermes-*`, `X-Loopdy-*` and `CF-Access-*` (use the
  Cloudflare Access option for those).
