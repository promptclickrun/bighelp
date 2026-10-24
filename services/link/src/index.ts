import { handleLoopdyLinkRequest } from "./http.js";
import { handleApnsRetryBatch } from "./push-retry.js";
import type { LinkEnv } from "./user-link.js";

export { UserLink } from "./user-link.js";

export default {
  async fetch(request: Request, env: LinkEnv, ctx?: ExecutionContext): Promise<Response> {
    return handleLoopdyLinkRequest(request, env, ctx);
  },
  async queue(batch: MessageBatch<unknown>, env: LinkEnv, ctx: ExecutionContext): Promise<void> {
    return handleApnsRetryBatch(batch, env, ctx);
  },
} satisfies ExportedHandler<LinkEnv>;
