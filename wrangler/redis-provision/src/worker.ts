import { Container, getContainer } from "@cloudflare/containers";

export class RedisContainer extends Container {
  defaultPort = 6379;
  sleepAfter = "20m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const tenant = url.hostname.split(".")[0].replace(/^redis-/, "");
    const id = env.REDIS_CONTAINER.idFromName(tenant);
    return env.REDIS_CONTAINER.get(id).fetch(request);
  },
};

interface Env {
  REDIS_CONTAINER: DurableObjectNamespace<RedisContainer>;
}
