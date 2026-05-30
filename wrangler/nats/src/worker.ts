import { Container, getContainer } from "@cloudflare/containers";

export class NatsContainer extends Container {
  defaultPort = 4222;
  sleepAfter = "20m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const tenant = url.hostname.split(".")[0].replace(/^nats-/, "");
    const id = env.NATS_CONTAINER.idFromName(tenant);
    return env.NATS_CONTAINER.get(id).fetch(request);
  },
};

interface Env {
  NATS_CONTAINER: DurableObjectNamespace<NatsContainer>;
}
