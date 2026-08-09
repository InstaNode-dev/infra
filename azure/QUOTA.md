# Azure quota — measured limits

**Subscription:** `73ae3d2a-5847-48f2-bcea-10bd3e1914f6`
**Tenant:** `693cbcea-51e7-4817-92ad-dbb041908d29`
**Region:** East US
**Measured:** 2026-08-09

These are **measured**, not assumed. Re-measure before changing any node pool sizing.

```bash
az vm list-usage --location eastus --output table
```

## Compute quota

| Quota | Used / Limit | Consequence for this platform |
|---|---|---|
| Total Regional vCPUs | 0 / 65 | Ample. System pool at max (3 × 2 vCPU) + spot (1 × 2 vCPU) = 8 vCPU. |
| Standard Basv2 Family vCPUs | 0 / 65 | Ample. `Standard_B2as_v2` system pool can autoscale 1→3 (6 vCPU). |
| Standard Bsv2 Family vCPUs | 0 / 65 | Ample **for on-demand**. Not the binding constraint — see below. |
| **Total Regional Low-priority vCPUs** | **0 / 3** | **BINDING.** Caps the Spot build pool at **one** `Standard_B2ls_v2` node. |

## The binding constraint: Spot is capped at 3 vCPU

Spot and low-priority VMs consume the **Total Regional Low-priority vCPUs** quota, which is **3**.

`Standard_B2ls_v2` is 2 vCPU. Three vCPU therefore allows **exactly one** Spot node.

`var.spot_node_max_count` is set to **1** for this reason (`aks.tf`).

### Why `max_count = 2` would be worse than an error

It would not fail loudly at apply time. The node pool would be created successfully with a ceiling
of 2. The failure appears later, under load: when one build node is already running and a second
Kaniko job is queued, the cluster autoscaler requests a second node, Azure rejects the scale-up on
quota, and the autoscaler retries on a backoff. The pod stays `Pending`.

Symptom: *"builds are slow / builds hang."* Cause: a quota rejection buried in
`kubectl -n kube-system logs -l app=cluster-autoscaler`. That is an expensive thing to debug at
3am, which is why the constraint is recorded here rather than left as folklore in a commit message.

### Raising it

1. Request a **Low-priority vCPU** quota increase for East US
   (Portal → Subscription → Usage + quotas, or `az quota` / a support request).
2. Confirm it landed:
   ```bash
   az vm list-usage --location eastus --output table | grep -i low
   ```
3. Only then raise `spot_node_max_count` in `terraform.tfvars`.

Each additional Spot node costs ~$27.33/mo **while it exists** — prorated to the seconds a build
actually runs, so the practical cost of raising this is close to zero. The quota is the only
blocker.

## Subscription type — read before planning any cost lever

**`quotaId = Sponsored_2016-01-01`** — this is an Azure **Sponsorship** subscription, not
pay-as-you-go with a credit applied.

| Implication | Detail |
|---|---|
| **Reserved Instances are assumed unavailable** | Sponsorship subscriptions generally cannot purchase Reserved Instances or Marketplace items. `AZURE-MIGRATION-PLAN.md` §4 recommends "try the RI first" (~−$22/mo) as the primary lever to stretch the credit to 12 months. **Do not design around it.** See `costs.tf` section D for the levers that are actually available. |
| **Spending limit is OFF** | There is no hard cutoff when the $1,000 credit is exhausted — spend continues against the payment instrument on file. This is why `budget.tf` exists. |
| **Cost Management support is inconsistent** | Which is why `enable_cost_budget` defaults to `false`: a budget on Sponsorship may fail to create, or create and silently never evaluate. Verify Cost Analysis shows real data before enabling. |

## Registered resource providers

Confirmed registered on this subscription as of 2026-08-09:

`Microsoft.Compute` · `Microsoft.ContainerService` · `Microsoft.Network` ·
`Microsoft.DBforPostgreSQL` · `Microsoft.Storage` · `Microsoft.ManagedIdentity`

That covers every resource type in this configuration. Verify with:

```bash
az provider list --query "[?registrationState=='Registered'].namespace" -o tsv | sort
```

## Not yet measured

These were not checked and could still block an apply. Check before or during the first apply:

- **Public IP address quota** (Standard, regional) — this configuration needs 1 static IP, plus
  AKS creates 1 more for LB outbound SNAT. Default limits are far above 2, so this is very unlikely
  to bind, but it is unverified.
- **PostgreSQL Flexible Server** subscription/region limits for the Burstable tier.
- **Storage account count** per region (default 250) — bootstrap needs 1.
