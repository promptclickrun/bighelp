# bighelp telemetry: Azure setup

This folder holds the Azure resources behind `telemetry.bighelp.app`. Only the maintainer deploys them, by hand.
Nothing in CI creates or changes an Azure resource.

| File | What it makes |
|---|---|
| `main.bicep` | Log Analytics `law-bighelp`, Application Insights `appi-bighelp`, action group `ag-bighelp`, six alert rules, and the `bighelp-health` workbook |
| `budget.bicep` | A monthly budget for the subscription, with alerts at 50% and 90% |

The seventh alert from the plan, the budget, is `budget.bicep`.

Use your own values wherever you see `<...>`. Never commit an email address, subscription ID or connection string.

## 1. Check the templates (no Azure login needed)

```bash
cd services/telemetry/azure
for file in main.bicep budget.bicep; do
  az bicep build --file "$file" --stdout > /dev/null
  az bicep lint --file "$file"
done
```

## 2. Deploy the resources

```bash
az login
az account set --subscription "<Visual Studio Enterprise subscription name or ID>"

az group create --name rg-bighelp-telemetry --location centralus

# Preview first. Read the list of changes before you go on.
az deployment group what-if \
  --resource-group rg-bighelp-telemetry \
  --template-file main.bicep \
  --parameters alertEmail="<your alert email>"

az deployment group create \
  --resource-group rg-bighelp-telemetry \
  --template-file main.bicep \
  --parameters alertEmail="<your alert email>"
```

Optional parameters:
- `alertWebhookUrl="<https URL>"`: also post alerts to a webhook (for example the bighelp Feed).
- `dailyQuotaGb=1` and `retentionInDays=90`: the defaults, from the plan. Retention must be one of Azure's values for
  Application Insights: 30, 60, 90, 120, 180, 270, 365, 550 or 730.
- `alertsEnabled=false`: deploy the rules switched off, then turn them on once data flows.

The deployment prints the Application Insights resource ID. It never prints the connection string.

Before you run it, check the price of the six alert rules and the workspace in the Azure pricing calculator. The plan
expects about $2 to $10 a month for the alert rules.

## 3. Deploy the budget

```bash
az deployment sub create \
  --location centralus \
  --template-file budget.bicep \
  --parameters amount=<monthly credit amount> alertEmail="<your alert email>" startDate=<first day of this month, yyyy-MM-dd>
```

The budget covers the whole subscription. This subscription runs on monthly credit with a spending limit. When the
credit runs out, Azure disables the resources until the next cycle, so telemetry would stop. The relay would not,
because it runs on Cloudflare.

## 4. Give the Worker its two secrets

Deploy the Worker first (`cd services/telemetry && npx wrangler deploy`). Without secrets it still answers, but it
drops every batch it would have forwarded and skips the per-network rate limit.

The connection string goes from Azure to Cloudflare through a pipe, so it never shows on screen or lands in your
shell history:

```bash
cd services/telemetry

az monitor app-insights component show \
  --app appi-bighelp --resource-group rg-bighelp-telemetry \
  --query connectionString --output tsv \
  | npx wrangler secret put APPINSIGHTS_CONNECTION_STRING

openssl rand -base64 32 | npx wrangler secret put IP_HASH_KEY
```

`az monitor app-insights` may ask to install the `application-insights` extension the first time. Say yes.

`IP_HASH_KEY` makes the per-network rate limit key. If you rotate it, networks get new keys. Nothing else depends on
it.

## 5. Check that it works

```bash
curl -sS -X POST https://telemetry.bighelp.app/v1/batch \
  -H 'content-type: application/json' \
  -d "{\"version\":1,\"source\":\"app\",\"id\":\"$(uuidgen | tr 'A-Z' 'a-z')\",\"context\":{\"appVersion\":\"0.0.1\",\"channel\":\"debug\"},\"events\":[{\"name\":\"app.opened\",\"t\":$(($(date +%s) * 1000)),\"p\":{\"coldStart\":true}}]}"
```

It answers `{"accepted":1,"dropped":0}`. `uuidgen` makes a version 4 UUID on macOS and Linux. After a few minutes, run
this in Application Insights > Logs:

```kusto
customEvents | where timestamp > ago(30m) | where name == "app.opened" | project timestamp, name, customDimensions
```

That test event stays in the data for 90 days. Use the `debug` channel so it is easy to filter out.

## Abuse limits

The Worker's rate limits (60 batches a minute per ID, 600 per network, with `Retry-After: 60` on every 429) slow a
casual sender. They do not stop a determined one, because anyone can make new IDs and the limits are per Cloudflare
location.

The hard backstop is the workspace's 1 GB daily ingestion cap (`dailyQuotaGb`). When the cap is reached, Azure
stops storing data until the next day. That protects the budget, but it also means forged traffic can crowd out real
events for the rest of the day.

Optionally, add a Cloudflare WAF rate-limiting rule on the route to stop floods before they reach the Worker, for
example: requests to `telemetry.bighelp.app` with path `/v1/batch`, over 300 requests per 10 seconds from one IP,
action Block for 10 minutes. This needs no code change.

## What the alerts do

All rules read `customEvents` from `appi-bighelp`. The event name is `name`, numbers are in `customMeasurements`,
strings are in `customDimensions`, and the install or host ID is `user_Id`. In the Log Analytics workspace the same
rows are in the `AppEvents` table, with `Name`, `Measurements` and `Properties`.

| Alert | Severity | Fires when | Notes |
|---|---|---|---|
| `push-latency` | 3 | p95 `notification.received` `delayMs` is over 6 s in 15 min | Direct sends only, at least 5 samples. Forgeable (see below). BuzzKit sends stay about 10 s late until cutover |
| `push-failures` | 1 | More than 5% of the relay's `push.sent` have a status other than 200 in 15 min | Relay events only, direct sends only, at least 10 sends. Events with no `status` are ignored |
| `push-dlq` | 1 | Any relay `push.dlq` in 15 min | Relay events only |
| `crash-spike` | 1 | Crashes in 1 h are more than 3 times the hourly average of the 47 hours before, and at least 4 | Forgeable (see below) |
| `host-turn-latency` | 2 | p95 `firstTokenMs` of `turn.completed` in 1 h is over 2 times the p95 of the 47 hours before | At least 10 turns. Fed by host events, so also forgeable |
| `ingestion-stalled` | 2 | No `app.opened` in 2 h | Quiet nights can trigger it. Raise the window once you know your traffic. Forgeable (see below) |

Azure limits a log alert window to 2 days, so the baseline rules compare the last hour with the 47 hours before it,
not 7 days. The workbook shows the full range.

**Forged events.** The app, notification extension and host sources are public: anyone can post a valid batch for
them. The relay's events arrive over a service binding, which the public internet cannot call. So `push-failures` and
`push-dlq` can be trusted, and these can be triggered, or silenced, by forged public events:
- `push-latency` (a flood of slow `notification.received` events raises it)
- `crash-spike` (a flood of `crash` events raises it)
- `ingestion-stalled` (a steady trickle of `app.opened` events keeps it quiet)
- `host-turn-latency` (same, with `turn.completed`)

Treat those alerts as hints to look at the workbook, not as proof. The `push-failures` alert is the one to act on.

To alert on BuzzKit sends too, remove the `path == "direct"` line from the first two rules.

## Cleaning up

Deleting the resource group removes everything in `main.bicep`. Delete the budget with
`az consumption budget delete --budget-name bighelp-monthly`.
