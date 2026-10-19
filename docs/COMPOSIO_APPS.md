# Composio Apps

Settings › Apps has two parts:

- **Native App Connections:** Hermes' own connectors on the computer in use (`Bighelp/Connectors/`,
  `ConnectorAppsModel`). Unchanged.
- **Composio Apps:** apps from [Composio](https://composio.dev) that the person connects with their own
  Composio account (`Bighelp/Connectors/Composio/`).

## The pieces

| Piece | What it does | Credential |
|---|---|---|
| Composio sign-in (`ComposioAccount`) | OAuth 2.1 with PKCE against Composio Connect. bighelp registers itself as a public client for each sign-in (dynamic client registration), signs in on Composio's page in `ASWebAuthenticationSession`, and returns to `loopdy://composio-auth`. | The person's tokens, in iCloud Keychain (`app.bighelp.composio.v1`, synchronizable, after first unlock). One sign-in for every computer and device. |
| Composio Connect (`ComposioConnectClient`) | MCP over HTTP to `https://connect.composio.dev/mcp`. Uses `tools/list` (the search tool's description names the connected apps) and `COMPOSIO_MANAGE_CONNECTIONS` with `list`, `add` (returns `redirect_url`, the app's sign-in page) and `remove` (`account_id`). Never a tool that acts in an app. | The person's bearer token. |
| App catalog (`ComposioCatalog`) | Apps by category, from `https://catalog.bighelp.app/v1/composio/catalog.json` (`services/catalog`), cached on the device with its ETag. | None in the app. The catalog service reads Composio's developer API with a bighelp key: app names, categories and logos only. |
| The agent (`ComposioAgentHost`) | The bighelp plugin (`native-composio-v1`) reports Composio's MCP servers in the agent's Hermes settings (`composio/status`) and installs or turns on Composio Connect (`composio/install`). Hermes' own MCP sign-in (`POST /api/mcp/servers/<name>/auth`, then `/api/mcp/oauth/flows/<id>`) signs it in to the same Composio account. Hermes' connection test (`POST /api/mcp/servers/<name>/test`) checks that the agent's saved sign-in still reaches Composio's tools. | Hermes keeps its own Composio tokens (`mcp-tokens/`). The plugin never sees them. |

The person's sign-in can't read Composio's developer API (it answers `401 Invalid API key`), so the catalog
comes from the catalog service. Composio Connect keeps connected apps with the account, so an app connected
in bighelp works for the agent once Hermes signs in to the same account. Hermes fixes a chat's tools when it
builds the chat's agent, so a chat that was already open when Composio came on doesn't get them
(`mcp_tool_agent.py`: automatic refreshes keep the toolsets the agent was built with). A new chat does.

## Flows

- **Sign in to Composio:** register → authorize (PKCE, `resource=https://connect.composio.dev/mcp`) →
  code at `loopdy://composio-auth` (state checked) → token → iCloud Keychain. An expired token refreshes;
  a refused refresh signs out. Another device's refresh arrives through iCloud Keychain, so a refresh
  reads the vault first.
- **Connect an app:** `add` → open `redirect_url` → when the page closes (on the Mac, when bighelp is in
  front again) `list` that app until its account is `active` (four tries, two seconds apart).
- **Remove:** `remove` with the account ID.
- **Let the agent use them:** `composio/status` → `notInstalled`, `turnedOff`, `needsSignIn` or `ready`.
  "Turn on for my agent" calls `composio/install`, then starts Hermes' MCP sign-in and polls it.
  A saved sign-in isn't proof that Composio still takes it, so `ready` also needs Hermes' connection test
  for that agent to list Composio's tools. When it can't, the page shows `cannotReach` and "Sign in for my
  agent" again (Hermes' MCP sign-in, no second install). A test that doesn't answer keeps the plugin's
  answer. When ready, the page says to use the apps in a new chat.
  A plugin without `native-composio-v1` shows "Update the bighelp plugin".

## Demo

`DemoComposio` (DEBUG): a made-up catalog and account, Gmail and GitHub connected, a demo computer
without Composio until "Turn on for my agent". Tests: `ComposioAppsTests`.
