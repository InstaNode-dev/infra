import os
import time
import uuid
from flask import Flask, request, jsonify
import psycopg2
import psycopg2.extras
import redis

app = Flask(__name__)

DATABASE_URL = os.environ.get("DATABASE_URL", "")
REDIS_URL = os.environ.get("REDIS_URL", "")
QUEUE_URL = os.environ.get("QUEUE_URL", "")

_r = None
if REDIS_URL:
    try:
        _r = redis.from_url(REDIS_URL, socket_connect_timeout=3)
        _r.ping()
    except Exception as e:
        print(f"[api] redis connect failed at boot: {e}", flush=True)
        _r = None


def get_pg():
    return psycopg2.connect(DATABASE_URL)


def ensure_schema():
    with get_pg() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS tasks (
                    id UUID PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at TIMESTAMPTZ DEFAULT now()
                );
                """
            )
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS jobs (
                    id UUID PRIMARY KEY,
                    task_id UUID NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    created_at TIMESTAMPTZ DEFAULT now(),
                    processed_at TIMESTAMPTZ
                );
                """
            )
            conn.commit()


@app.route("/")
def root():
    return jsonify({"ok": True, "service": "instanode-dogfood-api"})


@app.route("/api/tasks", methods=["GET"])
def list_tasks():
    with get_pg() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT id, title, created_at FROM tasks ORDER BY created_at DESC LIMIT 50")
            rows = cur.fetchall()
    return jsonify({"ok": True, "tasks": [dict(r, id=str(r["id"]), created_at=str(r["created_at"])) for r in rows]})


@app.route("/api/tasks", methods=["POST"])
def create_task():
    body = request.get_json(force=True, silent=True) or {}
    title = body.get("title", "").strip()
    if not title:
        return jsonify({"ok": False, "error": "title_required"}), 400
    task_id = str(uuid.uuid4())
    job_id = str(uuid.uuid4())
    with get_pg() as conn:
        with conn.cursor() as cur:
            cur.execute("INSERT INTO tasks (id, title) VALUES (%s, %s)", (task_id, title))
            cur.execute("INSERT INTO jobs (id, task_id, status) VALUES (%s, %s, 'pending')", (job_id, task_id))
            conn.commit()
    if _r is not None:
        try:
            _r.incr("tasks_created_total")
        except Exception as e:
            print(f"[api] redis incr failed: {e}", flush=True)
    return jsonify({"ok": True, "id": task_id, "job_id": job_id}), 201


@app.route("/api/stats", methods=["GET"])
def stats():
    created_total = None
    processed_total = None
    redis_ok = False
    if _r is not None:
        try:
            created_total = _r.get("tasks_created_total")
            created_total = int(created_total) if created_total else 0
            processed_total = _r.get("jobs_processed_total")
            processed_total = int(processed_total) if processed_total else 0
            redis_ok = True
        except Exception as e:
            print(f"[api] redis read failed: {e}", flush=True)
    return jsonify({
        "ok": True,
        "redis_ok": redis_ok,
        "tasks_created_total": created_total,
        "jobs_processed_total": processed_total,
        "queue_url_present": bool(QUEUE_URL),
    })


@app.route("/healthz")
def healthz():
    return jsonify({"ok": True})


if __name__ == "__main__":
    for attempt in range(10):
        try:
            ensure_schema()
            break
        except Exception as e:
            print(f"[api] schema init retry {attempt}: {e}", flush=True)
            time.sleep(2)
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
