# NATS Operator-Mode Auth Runbook

**Purpose:** one-time operator key generation + ongoing key rotation for the
NATS per-tenant isolation cutover (MR-P0-5, 2026-05-20).

Pairs with: `NATS-ISOLATION-MIGRATION-2026-05-20.md` (design doc, repo root)
and `infra/k8s/data/nats.yaml` (the updated manifest).

---

## TL;DR

```bash
# 1. Install nsc / nk locally
brew install nats-io/nats-tools/nsc

# 2. Create operator + sys account ONCE
nsc add operator -n InstanodeOperator --sys
nsc edit operator --sk generate

# 3. Extract claims + seeds
OPERATOR_JWT=$(nsc describe operator --raw)
OPERATOR_SEED=$(nsc list keys --all --show-seeds | awk '/Operator.*InstanodeOperator/{f=1} f && /Seed:/{print $2; exit}')
# ... see "Extracting Material" below for the full set ...

# 4. Apply Secret (instant-data namespace)
kubectl create secret generic nats-operator -n instant-data \
  --from-literal=OPERATOR_JWT="$OPERATOR_JWT" \
  --from-literal=OPERATOR_SEED="$OPERATOR_SEED" \
  --from-literal=SYS_ACCOUNT_PUBLIC_KEY="$SYS_ACCOUNT_PUBLIC_KEY" \
  --from-literal=SYS_ACCOUNT_JWT="$SYS_ACCOUNT_JWT" \
  --from-literal=SYS_ACCOUNT_SEED="$SYS_ACCOUNT_SEED" \
  --from-literal=SYS_USER_JWT="$SYS_USER_JWT" \
  --from-literal=SYS_USER_SEED="$SYS_USER_SEED"

# 5. Apply nats.yaml + restart
kubectl apply -f infra/k8s/data/nats.yaml
kubectl rollout restart deployment/nats -n instant-data

# 6. Patch instant-secrets (instant namespace) for the api + worker
kubectl patch secret instant-secrets -n instant --type=merge -p '{
  "data": {
    "NATS_OPERATOR_SEED": "'$(printf '%s' "$OPERATOR_SEED" | base64)'",
    "NATS_SYSTEM_ACCOUNT_PUBLIC_KEY": "'$(printf '%s' "$SYS_ACCOUNT_PUBLIC_KEY" | base64)'"
  }
}'
kubectl rollout restart deployment/instant-api -n instant
kubectl rollout restart deployment/instant-worker -n instant-infra
```

---

## Why this is operator-only

Two reasons it can't be auto-applied:

1. **Operator + system NKey seeds never leave the operator's machine
   unencrypted.** The seeds are the root of the trust chain — they can sign
   any account, revoke any account, mint a system user that owns the
   cluster. Generating them in a CI job means whoever has CI access has the
   keys. Generate them locally, paste them into a Secret you create
   yourself, then delete the local copy or store it in 1Password.

2. **Order matters.** The pod crashes if the Secret doesn't exist. The api
   degrades to legacy_open if the Secret isn't patched. Either step done
   alone is fine; both done in the wrong order leaves the cluster either
   crash-looping or shipping unauthenticated traffic. Walk through it
   manually.

---

## Extracting Material

`nsc` writes everything to `~/.nsc/`. The relevant files after
`nsc add operator -n InstanodeOperator --sys`:

```
~/.nsc/
├── nats/
│   └── InstanodeOperator/
│       ├── InstanodeOperator.jwt           ← OPERATOR_JWT
│       ├── SYS/
│       │   ├── SYS.jwt                     ← SYS_ACCOUNT_JWT
│       │   └── users/
│       │       └── sys.jwt                 ← SYS_USER_JWT
└── keys/
    ├── keys/
    │   ├── O/                              ← operator key dir
    │   │   └── ABCDEF.../                  ← operator NKey id
    │   │       └── OAAAA....nk             ← OPERATOR_SEED
    │   ├── A/                              ← account key dir
    │   │   └── DEADBE.../                  ← SYS_ACCOUNT_PUBLIC_KEY
    │   │       └── SAAAA....nk             ← SYS_ACCOUNT_SEED
    │   └── U/                              ← user key dir
    │       └── 012345.../
    │           └── SUAA....nk              ← SYS_USER_SEED
```

The cleanest extraction script:

```bash
NSC_ROOT="$HOME/.nsc"
OPERATOR_JWT=$(cat "$NSC_ROOT/nats/InstanodeOperator/InstanodeOperator.jwt")
SYS_ACCOUNT_JWT=$(cat "$NSC_ROOT/nats/InstanodeOperator/SYS/SYS.jwt")
SYS_USER_JWT=$(cat "$NSC_ROOT/nats/InstanodeOperator/SYS/users/sys.jwt")

# Decode account public key from JWT (the `sub` claim).
SYS_ACCOUNT_PUBLIC_KEY=$(echo "$SYS_ACCOUNT_JWT" | cut -d. -f2 | base64 -d 2>/dev/null | jq -r .sub)

# Seeds live in ~/.nsc/keys/keys/{O,A,U}/<prefix>/<full>.nk — find them by prefix.
# Operator seeds start with "SO", account seeds with "SA", user seeds with "SU".
find_seed() {
  local prefix="$1"
  find "$NSC_ROOT/keys/keys" -type f -name "${prefix}*.nk" | head -1 | xargs cat
}
OPERATOR_SEED=$(find_seed SO)
SYS_ACCOUNT_SEED=$(find_seed SA)
SYS_USER_SEED=$(find_seed SU)
```

## Verification (after the cluster restarts)

```bash
# 1. Write a sys.creds file from SYS_USER_JWT + SYS_USER_SEED locally:
cat > /tmp/sys.creds <<EOF
-----BEGIN NATS USER JWT-----
$SYS_USER_JWT
------END NATS USER JWT------
-----BEGIN USER NKEY SEED-----
$SYS_USER_SEED
------END USER NKEY SEED------
EOF

# 2. Connect AS the sys user (port-forward first).
kubectl port-forward -n instant-data svc/nats 4222:4222 &
nats --creds /tmp/sys.creds --server nats://localhost:4222 server info
# Expected: server info reply. If you get "Authorization Violation", the
# operator JWT in the cluster doesn't match the operator seed that signed
# this sys account — either the Secret didn't get applied, or you
# regenerated the operator key and forgot to re-apply.

# 3. Connect UNAUTHENTICATED. This MUST fail post-cutover.
nats --server nats://localhost:4222 server info
# Expected: "Authorization Violation" or "Authentication Required".

# Clean up local creds:
shred -u /tmp/sys.creds
```

## Rotation

Rotating the operator seed is a cluster-restarting event (the new operator
JWT has to be loaded by every nats-server process at startup). Plan:

1. Generate a NEW operator + sys with `nsc add operator -n InstanodeOperator-v2 --sys`.
2. Re-sign every tenant account against the new operator (`nsc push -A` after `nsc env -o InstanodeOperator-v2`).
3. Update the `nats-operator` Secret in one transaction:
   ```bash
   kubectl create secret generic nats-operator -n instant-data \
     --from-literal=OPERATOR_JWT="$NEW_OPERATOR_JWT" \
     --from-literal=OPERATOR_SEED="$NEW_OPERATOR_SEED" \
     ... \
     --dry-run=client -o yaml | kubectl apply -f -
   ```
4. `kubectl rollout restart deployment/nats -n instant-data`.
5. Update `instant-secrets` in `instant` namespace with the new seed.
6. Restart api + worker so they pick up the new seed.

Old account JWTs (signed by the old operator) become invalid the moment the
nats-server picks up the new operator key. Plan for a 5-minute brownout
while every client reconnects.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `nats-server: open /etc/nats/operator.conf: no such file` | initContainer didn't render the file | check `nats-operator` Secret exists in `instant-data` namespace, contents non-empty |
| api logs `queueprovider.nats: parse operator seed: invalid encoded key` | `NATS_OPERATOR_SEED` not base64-encoded properly | re-do step 6 of the TL;DR |
| Provisioned queue returns `connection_url` but `nats publish` fails with `Authorization Violation` | account claim never reached the resolver | check api logs for `queue.cred_issue_failed`; if the ResolverPusher fires no-op, that means the account JWT was minted but the resolver doesn't know about it yet — this is expected in MEMORY-resolver mode until we implement the SYS-connection push |
| Existing pre-cutover queue resources stop working after rollout | nats-server in operator mode rejects all unauthenticated clients | this is the intended behavior; the legacy_open auth_mode flag in the DB is informational only — clients need to recycle into isolated mode after the cutover |

---

**Authoring:** generated 2026-05-20 by the NATS isolation cutover work. Keep
this file in sync with `NATS-ISOLATION-MIGRATION-2026-05-20.md` (repo root)
and `api/internal/handlers/queue_provider.go`.
