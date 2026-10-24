interface Env {
  ACCOUNTS: D1Database;
  MARKETPLACE_RETIREMENT: D1Database;
  APPLE_APP_ID: string;
  PASSKEY_ORIGIN: string;
  PASSKEY_RP_ID: string;
  // Direct APNs delivery. Worker secrets, set by the maintainer. See docs/DIRECT_APNS_RELAY.md.
  APNS_KEY_P8?: string;
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  PUSH_TOKEN_KEY?: string;
}

declare namespace Cloudflare {
  interface Env {
    ACCOUNTS: D1Database;
    MARKETPLACE_RETIREMENT: D1Database;
    APPLE_APP_ID: string;
    PASSKEY_ORIGIN: string;
    PASSKEY_RP_ID: string;
    APNS_KEY_P8?: string;
    APNS_KEY_ID?: string;
    APNS_TEAM_ID?: string;
    PUSH_TOKEN_KEY?: string;
  }
}

declare module "*.sql?raw" {
  const source: string;
  export default source;
}

declare module "*.json?raw" { const source: string; export default source; }
