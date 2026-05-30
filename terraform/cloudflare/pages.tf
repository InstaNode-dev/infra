# Cloudflare Pages project for instanode-web (marketing site).
# Phase 2 in FINAL-PLAN.md. Dashboard-on-Pages is KILLED per D-5;
# do NOT add a second `cloudflare_pages_project` for dashboard here.

resource "cloudflare_pages_project" "instanode_web" {
  account_id        = var.account_id
  name              = var.environment == "production" ? "instanode-web" : "instanode-web-staging"
  production_branch = "main"

  build_config = {
    build_command       = "npm run build"
    destination_dir     = "dist"
    root_dir            = ""
    web_analytics_tag   = null
    web_analytics_token = null
  }

  source = {
    type = "github"
    config = {
      owner                         = "instanodedev"
      repo_name                     = "instanode-web"
      production_branch             = "main"
      pr_comments_enabled           = true
      production_deployment_enabled = true
      preview_deployment_setting    = "all"
      preview_branch_includes       = ["*"]
      preview_branch_excludes       = []
    }
  }

  deployment_configs = {
    production = {
      compatibility_date  = "2026-05-30"
      compatibility_flags = []
      env_vars = {
        VITE_API_URL = {
          type  = "plain_text"
          value = var.environment == "production" ? "https://api.instanode.dev" : "https://api.staging.instanode.dev"
        }
        VITE_ENV = {
          type  = "plain_text"
          value = var.environment
        }
      }
    }
    preview = {
      compatibility_date  = "2026-05-30"
      compatibility_flags = []
    }
  }
}

# Custom domain binding — only after Phase 2 acceptance (D-9 equivalent
# for marketing: zero broken-link diff). Until then, traffic stays on
# GH Pages via DNS, and this resource is dormant.
resource "cloudflare_pages_domain" "instanode_web" {
  account_id   = var.account_id
  project_name = cloudflare_pages_project.instanode_web.name
  name         = var.environment == "production" ? var.zone_name : "staging.${var.zone_name}"
}
