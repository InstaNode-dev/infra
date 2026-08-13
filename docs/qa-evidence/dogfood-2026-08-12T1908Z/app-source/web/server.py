import os
import json
import urllib.request
from flask import Flask, request, redirect

app = Flask(__name__)
API_URL = os.environ.get("API_URL", "http://api:8080")


def fetch_json(path, method="GET", body=None):
    url = f"{API_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                  headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        return json.loads(resp.read().decode())


@app.route("/", methods=["GET"])
def index():
    try:
        tasks = fetch_json("/api/tasks").get("tasks", [])
        stats = fetch_json("/api/stats")
    except Exception as e:
        return f"<h1>instanode.dev dogfood app</h1><p>backend unreachable at {API_URL}: {e}</p>", 502

    rows = "".join(f"<li>{t['title']} <small>({t['created_at']})</small></li>" for t in tasks)
    return f"""
    <html><head><title>instanode.dev dogfood - task board</title></head>
    <body style="font-family: sans-serif; max-width: 640px; margin: 40px auto;">
      <h1>InstaNode dogfood: tiny task board</h1>
      <p>backend api reached server-side via <code>API_URL={API_URL}</code> (cluster-internal, never sent to the browser)</p>
      <form method="POST" action="/create">
        <input name="title" placeholder="new task title" required>
        <button type="submit">add</button>
      </form>
      <h3>tasks ({len(tasks)})</h3>
      <ul>{rows or '<li><em>none yet</em></li>'}</ul>
      <h3>stats (via backend's private Redis)</h3>
      <pre>{json.dumps(stats, indent=2)}</pre>
    </body></html>
    """


@app.route("/create", methods=["POST"])
def create():
    title = request.form.get("title", "")
    try:
        fetch_json("/api/tasks", method="POST", body={"title": title})
    except Exception as e:
        return f"create failed: {e}", 502
    return redirect("/")


@app.route("/healthz")
def healthz():
    return {"ok": True}


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
