terraform {
  required_version = ">= 1.4"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # State lives in R2 (S3-compatible). The bucket "instanode-tf-state" must
  # be created out-of-band before `terraform init` — see README §Bootstrap.
  # Operator passes -backend-config="..." at init time; we DON'T hardcode
  # the account-specific endpoint or HMAC creds here.
  backend "s3" {
    bucket                      = "instanode-tf-state"
    key                         = "cloudflare/terraform.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    encrypt                     = true
  }
}
