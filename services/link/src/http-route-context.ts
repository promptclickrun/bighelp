import type { LinkEnv } from "./user-link.js";

export interface HTTPRouteContext {
  request: Request;
  env: LinkEnv;
  now: number;
}
