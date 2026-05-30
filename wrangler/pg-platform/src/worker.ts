// pg-platform Worker shell. Postgres doesn't speak HTTP, but CF
// Containers require a Worker entrypoint. The Worker accepts a
// service-binding RPC from other Containers and forwards a connection
// hint; the actual TCP traffic flows over the Container DO's internal
// network using `container.fetch(request)` with `Upgrade: tcp` semantics
// (CF Containers' raw-TCP mode, available since the GA release).

import { Container, getContainer } from "@cloudflare/containers";

export class PgPlatformContainer extends Container {
  defaultPort = 5432;
  sleepAfter = "30m"; // Longer than api so platform_db survives test bursts.
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const container = getContainer(env.PG_CONTAINER);
    // Container holds the TCP listener; CF routes the upgraded socket through.
    return container.fetch(request);
  },
};

interface Env {
  PG_CONTAINER: DurableObjectNamespace<PgPlatformContainer>;
}
