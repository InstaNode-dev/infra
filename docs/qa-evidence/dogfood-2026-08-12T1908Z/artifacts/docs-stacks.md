# Stacks (multi-service deploy)

`POST /stacks/new` takes an `instant.yaml` manifest plus one tarball per
service. Services can reference each other with `service://<name>` env
values — those resolve to cluster-internal `http://<name>:<port>` URLs at
deploy time.

The multipart form **requires** a `name` field — the human-readable label
for the stack. It must be 1–64 characters and match
`^[A-Za-z0-9][A-Za-z0-9 _-]*$` (start with a letter or digit; letters,
digits, spaces, underscores and hyphens after). Omitting it returns
`400 {"error":"name_required"}`; an invalid value returns
`400 {"error":"invalid_name"}`.

```
curl -X POST https://api.instanode.dev/stacks/new \
  -H "Authorization: Bearer <JWT>" \
  -F "name=shop-stack" \
  -F "manifest=@instant.yaml" \
  -F "api=@api.tar.gz" \
  -F "web=@web.tar.gz"
```

```
services:
  api:
    build: ./api
    port: 3000
  web:
    build: ./web
    port: 8080
    expose: true
    env:
      API_URL: service://api
```

Only services with `expose: true` get a public URL — the rest are
in-cluster only. The whole stack rolls out together; partial failure is
reported per-service in `GET /stacks/{slug}`.
