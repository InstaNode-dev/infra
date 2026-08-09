# Terraform state backend bootstrap

Run this **once**, before the root configuration in `../`.

It creates the Azure Storage account that holds Terraform state for the platform.

## Why this exists

The root configuration's state contains the **PostgreSQL admin password in plaintext**.
`sensitive = true` redacts CLI output; it does not encrypt state. Local state would put a
production database credential in an unencrypted, unversioned, unlocked file on one laptop.

This directory is the standard resolution of the resulting chicken-and-egg: the backend has to
exist before it can be used as a backend. It runs on **local state**, and that is safe for a
specific reason rather than by convention — **this configuration creates no secrets**. Its state
holds a resource group, a storage account and a container. Nothing in it is sensitive.

## Cost

**$0.01/mo.** Hot LRS block blob is `$0.0208/GB/month` (East US, verified via
`prices.azure.com`, 2026-08-09). State is well under 1 MB even with every version retained.

## Apply

```bash
cd infra/azure/bootstrap

export ARM_SUBSCRIPTION_ID=73ae3d2a-5847-48f2-bcea-10bd3e1914f6

terraform init
terraform apply

# Emit the backend config for the root configuration
terraform output -raw backend_hcl > ../backend.hcl
```

Then, in `../`:

```bash
cd ..
terraform init -backend-config=backend.hcl
```

## Access

The backend authenticates with **Entra RBAC**, not shared storage keys (`use_azuread_auth = true`),
so no storage key is ever written to a config file or a CI secret. Each principal that runs
`terraform apply` needs `Storage Blob Data Contributor` on the account:

```bash
terraform output -raw grant_state_access_command
```

Being a subscription Owner is **not** sufficient — data-plane access to blobs is a separate role
assignment from control-plane ownership. This is the most common first-run failure here: `terraform
init` succeeds, then `plan` fails with a 403 on the blob.

## What you get for one cent a month

| Property | Why it matters |
|---|---|
| Blob versioning | A corrupted or truncated state file is otherwise unrecoverable and means re-importing every resource by hand |
| 30-day soft delete (blob + container) | Survives an accidental delete |
| Blob leases | State locking — two concurrent applies cannot race |
| Encryption at rest | Default, Microsoft-managed keys |
| Entra RBAC | No long-lived shared key to leak |
| TLS 1.2 minimum, no public access | Baseline hygiene |

## Local state file

`terraform.tfstate` in this directory is gitignored (see `../.gitignore`). It contains no secrets,
but keep it — it is how you would later change the container's retention policy or rename the
account. If it is lost, the storage account can simply be re-imported or left unmanaged; nothing
downstream breaks.
