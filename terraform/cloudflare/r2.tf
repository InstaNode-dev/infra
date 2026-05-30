# R2 buckets. Per CEO D-1 + DevOps D-4, staging gets a parallel bucket
# (`instant-shared-staging`); production keeps the existing name and
# moves traffic into it via the storageprovider env-flip (D-8 names).
#
# Lifecycle rule: anon/ prefix expires after 24h (matches the platform's
# anon-resource TTL contract — pay-from-day-one, no trial creep).

locals {
  bucket_name = var.environment == "production" ? "instant-shared" : "instant-shared-staging"
}

resource "cloudflare_r2_bucket" "shared" {
  account_id    = var.account_id
  name          = local.bucket_name
  location      = "WNAM" # North America West — closest to our DO NYC3 cluster latency-wise
  storage_class = "Standard"
}

# 24h TTL on anon/ — matches platform contract that anonymous resources
# expire after 24h (CLAUDE.md "anonymous (24h TTL) is the only free tier").
resource "cloudflare_r2_bucket_lifecycle" "shared_anon_24h" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.shared.name

  rules = [{
    id      = "anon-24h"
    enabled = true
    conditions = {
      prefix = "anon/"
    }
    delete_objects_transition = {
      condition = {
        type    = "Age"
        max_age = 86400 # 24h in seconds
      }
    }
  }]
}
