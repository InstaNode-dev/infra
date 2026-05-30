import { Container, getContainer } from "@cloudflare/containers";

export class PgCustomersContainer extends Container {
  defaultPort = 5432;
  sleepAfter = "20m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // Per-tenant routing: extract tenant from subdomain.
    const url = new URL(request.url);
    const tenant = url.hostname.split(".")[0].replace(/^pg-customer-/, "");
    // ID by tenant → one DO instance per tenant (their isolated PG).
    const id = env.PG_CUSTOMERS_CONTAINER.idFromName(tenant);
    const container = env.PG_CUSTOMERS_CONTAINER.get(id);
    return container.fetch(request);
  },
};

interface Env {
  PG_CUSTOMERS_CONTAINER: DurableObjectNamespace<PgCustomersContainer>;
}
