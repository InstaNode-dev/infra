// Tiny Worker shell for the api Container.
//
// CF Containers require a Worker entrypoint that forwards requests to
// the Container's Durable Object. The container itself runs the actual
// Go binary (instanodedev/api), listening on :8080.
//
// Every incoming HTTP request is routed to a Container instance; CF
// handles spin-up/spin-down. Disk is ephemeral — see ../README.md.

import { Container, getContainer } from "@cloudflare/containers";

export class ApiContainer extends Container {
  // The Go binary listens on :8080.
  defaultPort = 8080;
  // Sleep after 10 minutes of no traffic. CF will spin back up on the
  // next request, with a fresh disk. The api is stateless (state lives
  // in pg-platform Container), so cold-start is correctness-safe.
  sleepAfter = "10m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Route every request to a single Container instance (single-shard
    // for staging; production would shard by tenant or geo).
    const container = getContainer(env.API_CONTAINER);
    return container.fetch(request);
  },
};

interface Env {
  API_CONTAINER: DurableObjectNamespace<ApiContainer>;
}
