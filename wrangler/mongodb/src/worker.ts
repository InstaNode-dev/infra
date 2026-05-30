import { Container, getContainer } from "@cloudflare/containers";

export class MongoContainer extends Container {
  defaultPort = 27017;
  sleepAfter = "20m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const tenant = url.hostname.split(".")[0].replace(/^mongo-/, "");
    const id = env.MONGO_CONTAINER.idFromName(tenant);
    return env.MONGO_CONTAINER.get(id).fetch(request);
  },
};

interface Env {
  MONGO_CONTAINER: DurableObjectNamespace<MongoContainer>;
}
