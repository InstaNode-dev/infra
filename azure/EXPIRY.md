# ⏰ CREDIT EXPIRY — 2026-09-12

> **On 2026-09-12 this subscription starts charging a personal credit card, silently.**
> Read this before doing anything else in `infra/azure/`.

---

## The facts

Read live from the subscription on 2026-08-09:

| | |
|---|---|
| Credit lot | "Azure startup sponsorship credit" |
| Amount | **$1,000** |
| Started | 2026-06-14 |
| **Expires** | **2026-09-12** |
| Spent at discovery | $0 |
| Follow-on grant | **None.** Operator confirmed 2026-08-09 |
| Subscription | `73ae3d2a-5847-48f2-bcea-10bd3e1914f6` |
| Offer | `Sponsored_2016-01-01` (Azure Sponsorship, under an MCA billing account) |

**Run rate ≈ $184/mo.** From the 2026-08-09 apply to expiry is ~34 days, so roughly
**$210 will be consumed and ~$790 forfeited.** That is not a failure of planning — the credit
was issued 2026-06-14 and two of its three months elapsed before the migration began.

---

## Why this is dangerous rather than merely disappointing

Three properties compound, and each was verified rather than assumed:

1. **There is no spending limit.** Not "it is switched off" — *the setting does not exist on this
   offer type.* Nothing stops spend at $0 credit.
2. **Expiry converts to Pay-As-You-Go automatically**, on the card on file, "to ensure continuity
   of your environment." The infrastructure keeps running. The bill just moves to you.
3. **Azure Cost Management does not support this offer type.** `Sponsored_2016-01-01` appears in
   Microsoft's unsupported-offers table, which is why `budget.tf` ships default-off. **The budget
   alerts in this repo may never fire.** Do not rely on them.

So the failure mode is: nothing breaks, no alert fires, and a card statement arrives ~60 days
later.

**This has already happened once on this project.** The 2026-06-11 decision to pause DigitalOcean
production was written down, and then silently did not hold for two months — roughly $130–400 of
real cash. A recorded intention is not a control. This file exists because a condition without a
date and an owner is exactly how that recurs.

---

## The only real guardrail

A budget cannot control spend here, so the control is **a dated calendar entry plus a rehearsed
destroy path.** Both parts are required: a reminder with no rehearsed procedure produces panic,
and a rehearsed procedure with no reminder never runs.

### Do this now, not on 2026-09-12

- [ ] **Calendar entry, 2026-09-05** (one week before): "InstaNode Azure — decide: extend, migrate, or destroy"
- [ ] **Calendar entry, 2026-09-11**: "InstaNode Azure — DESTROY unless a funded decision exists"
- [ ] **Rehearse the destroy** (below) at least once while it does not matter
- [ ] Confirm the card on file is one you would notice being charged

---

## Rehearsed destroy

Run the rehearsal **before** it is needed. An unrehearsed `terraform destroy` at the moment of
crisis is how state gets orphaned and resources keep billing after you believe they are gone.

```bash
cd infra/azure

# 1. What would go, without doing it. Expect the full estate.
terraform plan -destroy -out=destroy.tfplan

# 2. The actual teardown.
terraform destroy -auto-approve

# 3. VERIFY — do not trust the exit code. This is the whole point.
az resource list --subscription 73ae3d2a-5847-48f2-bcea-10bd3e1914f6 \
  -o table | grep -i instanode          # expect: nothing

az group list --subscription 73ae3d2a-5847-48f2-bcea-10bd3e1914f6 \
  --query "[?starts_with(name,'rg-instanode')].name" -o tsv
```

**Resources Terraform does NOT own and will NOT destroy** — check these by hand, because they bill
independently:

| Resource | Where | Why Terraform misses it |
|---|---|---|
| **Standard Load Balancer** (~$25/mo) | AKS node resource group | Created by AKS when the ingress Service is applied, not by this config |
| **AKS-managed outbound public IP** ($3.65/mo) | AKS node resource group | Created by AKS for egress SNAT |
| **PVC-backed managed disks** (~$6/mo) | AKS node resource group | Created by the CSI driver from PersistentVolumeClaims |
| **tfstate storage account** ($0.01/mo) | `rg-instanode-tfstate` | Separate `bootstrap/` config, deliberately not in the main state |

Deleting the AKS cluster normally removes its node resource group and everything in it — but
**verify it, do not assume it.** A retained disk or orphaned public IP bills quietly forever.

---

## Decision, due 2026-09-05

Pick one. Doing nothing selects option 3 by default, and pays for it.

| | Option | Consequence |
|---|---|---|
| 1 | **Fund it** — move to PAYG deliberately, on a card you have chosen to expose | ~$184/mo of real money, on a product with no revenue |
| 2 | **Destroy it** — capture the demo first | $0/mo. Terraform + manifests remain in git, so it is reproducible in ~30 minutes |
| 3 | **Do nothing** | Option 1, without having chosen it. The worst outcome |

**Option 2 is the default recommendation given no follow-on grant and no revenue**, and it is
cheap precisely because this estate is fully described in Terraform. That reproducibility is also
the thing worth showing a buyer: infrastructure that can be stood up from source in half an hour
is an asset in a sale. Running it 24×7 with no users is not.

If the goal is a sale, **capture the demo evidence before destroying** — a recorded
`curl → psql` round trip and a live deployed app URL keep their value long after the cluster is
gone.

---

## If you are reading this after 2026-09-12

1. Check whether the subscription converted: `az consumption budget list` will not help — look at
   the billing blade in the portal.
2. If it is billing, decide immediately: fund or destroy. Every day of drift is real money.
3. `terraform destroy` still works. State is in `rg-instanode-tfstate`, which survives everything
   else.
