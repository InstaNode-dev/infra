import { Container, getContainer } from "@cloudflare/containers";

export class WorkerContainer extends Container {
  defaultPort = 8091; // worker exposes /metrics + /readyz on 8091
  sleepAfter = "20m";
}

export default {
  // HTTP path: forward to container (rare; mostly metrics scrapes).
  async fetch(request: Request, env: Env): Promise<Response> {
    return getContainer(env.WORKER_CONTAINER).fetch(request);
  },
  // Cron path: wake the container so River picks up due jobs.
  async scheduled(_event: ScheduledEvent, env: Env): Promise<void> {
    const c = getContainer(env.WORKER_CONTAINER);
    // A no-op POST that the worker binary handles as "tick the job loop".
    await c.fetch("http://internal/tick", { method: "POST" });
  },
};

interface Env {
  WORKER_CONTAINER: DurableObjectNamespace<WorkerContainer>;
}
