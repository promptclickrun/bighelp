import { handleLoopdyLinkRequest } from "./http.js";
import type { LinkEnv } from "./user-link.js";

export { UserLink } from "./user-link.js";

export default {
  async fetch(request: Request, env: LinkEnv): Promise<Response> {
    return handleLoopdyLinkRequest(request, env);
  },
} satisfies ExportedHandler<LinkEnv>;
