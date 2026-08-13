import os
import time
import threading
import http.server
import psycopg2
import redis

DATABASE_URL = os.environ.get("DATABASE_URL", "")
REDIS_URL = os.environ.get("REDIS_URL", "")
QUEUE_URL = os.environ.get("QUEUE_URL", "")
PORT = int(os.environ.get("PORT", 8080))


class _Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true,"role":"worker"}')

    def log_message(self, *a):
        pass


def start_health_server():
    srv = http.server.HTTPServer(("0.0.0.0", PORT), _Health)
    threading.Thread(target=srv.serve_forever, daemon=True).start()


def try_queue_probe():
    if not QUEUE_URL:
        print("[worker] QUEUE_URL not set, skipping NATS probe", flush=True)
        return
    try:
        import socket
        host_port = QUEUE_URL.split("://")[-1]
        host, _, port = host_port.partition(":")
        port = int(port) if port else 4222
        with socket.create_connection((host, port), timeout=5):
            print(f"[worker] TCP connect to NATS {host}:{port} succeeded", flush=True)
    except Exception as e:
        print(f"[worker] NATS TCP probe FAILED (known-broken /queue/new per operator): {e}", flush=True)


def get_pg():
    return psycopg2.connect(DATABASE_URL)


def main():
    start_health_server()

    r = None
    if REDIS_URL:
        try:
            r = redis.from_url(REDIS_URL, socket_connect_timeout=3)
            r.ping()
            print("[worker] redis connected", flush=True)
        except Exception as e:
            print(f"[worker] redis connect failed: {e}", flush=True)

    try_queue_probe()

    for _ in range(30):
        try:
            with get_pg() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT to_regclass('public.jobs')")
                    if cur.fetchone()[0]:
                        break
        except Exception as e:
            print(f"[worker] waiting for schema: {e}", flush=True)
        time.sleep(2)

    print("[worker] entering poll loop (Postgres outbox fallback for broken /queue/new)", flush=True)
    while True:
        try:
            with get_pg() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT id FROM jobs WHERE status='pending' ORDER BY created_at LIMIT 10 FOR UPDATE SKIP LOCKED"
                    )
                    rows = cur.fetchall()
                    for (job_id,) in rows:
                        cur.execute(
                            "UPDATE jobs SET status='processed', processed_at=now() WHERE id=%s",
                            (job_id,),
                        )
                        if r is not None:
                            try:
                                r.incr("jobs_processed_total")
                            except Exception as e:
                                print(f"[worker] redis incr failed: {e}", flush=True)
                    conn.commit()
                    if rows:
                        print(f"[worker] processed {len(rows)} jobs", flush=True)
        except Exception as e:
            print(f"[worker] poll loop error: {e}", flush=True)
        time.sleep(3)


if __name__ == "__main__":
    main()
