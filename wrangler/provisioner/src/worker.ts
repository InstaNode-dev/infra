import { Container, getContainer } from "@cloudflare/containers";

export class ProvisionerContainer extends Container {
  defaultPort = 50051; // gRPC
  sleepAfter = "20m";
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return getContainer(env.PROVISIONER_CONTAINER).fetch(request);
  },
};

interface Env {
  PROVISIONER_CONTAINER: DurableObjectNamespace<ProvisionerContainer>;
}
