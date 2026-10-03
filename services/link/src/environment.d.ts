interface Env {
  ACCOUNTS: D1Database;
  MARKETPLACE_RETIREMENT: D1Database;
  APPLE_APP_ID: string;
  PASSKEY_ORIGIN: string;
  PASSKEY_RP_ID: string;
}

declare namespace Cloudflare {
  interface Env {
    ACCOUNTS: D1Database;
    MARKETPLACE_RETIREMENT: D1Database;
    APPLE_APP_ID: string;
    PASSKEY_ORIGIN: string;
    PASSKEY_RP_ID: string;
  }
}

declare module "*.sql?raw" {
  const source: string;
  export default source;
}

declare module "*.json?raw" { const source: string; export default source; }
