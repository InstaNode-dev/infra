# Terraform helpers for the CF migration. Run from this dir.
#
# Required env vars (export before any target):
#   CLOUDFLARE_API_TOKEN     — Token A (deploy) for plan/apply
#   AWS_ACCESS_KEY_ID        — R2 HMAC for TF state bucket
#   AWS_SECRET_ACCESS_KEY    — R2 HMAC secret for TF state bucket
#   CF_ACCOUNT_ID            — for backend endpoint URL
#
# ENV defaults to staging; pass ENV=production for prod.

ENV ?= staging
TF  ?= terraform

ifneq ($(filter $(ENV),staging production),$(ENV))
$(error ENV must be 'staging' or 'production' (got '$(ENV)'))
endif

.PHONY: help init fmt validate plan apply destroy install-secrets rotate-tokens clean

help:
	@echo "Targets:"
	@echo "  init             — terraform init with R2 backend (one-time per workspace)"
	@echo "  fmt              — terraform fmt -check (CI also enforces)"
	@echo "  validate         — terraform validate (offline)"
	@echo "  plan             — terraform plan (writes tfplan.bin)"
	@echo "  apply            — terraform apply (reads tfplan.bin from plan target)"
	@echo "  install-secrets  — pull token outputs and push to k8s + GH org secrets"
	@echo "  rotate-tokens    — bump expiry, plan, apply, install"
	@echo "  destroy          — DANGEROUS, only for tearing down ephemeral staging"
	@echo
	@echo "Env: ENV=$(ENV) (override with ENV=production)"

init:
	@: $${CF_ACCOUNT_ID?CF_ACCOUNT_ID must be set}
	$(TF) init \
		-backend-config="endpoints={s3=\"https://$$CF_ACCOUNT_ID.r2.cloudflarestorage.com\"}" \
		-backend-config="workspace_key_prefix=$(ENV)"
	$(TF) workspace select $(ENV) 2>/dev/null || $(TF) workspace new $(ENV)

fmt:
	$(TF) fmt -check -recursive

validate:
	$(TF) validate -no-color

plan:
	$(TF) plan -var-file=$(ENV).auto.tfvars -out=tfplan.bin

apply:
	$(TF) apply tfplan.bin
	@echo
	@echo "==> Apply complete. If tokens were created/rotated, run:"
	@echo "    make install-secrets ENV=$(ENV)"

# Pull sensitive token outputs (one-shot, never written to disk) and
# install them as k8s + GH secrets across all consuming repos. Token
# VALUES are scrubbed from the env on exit.
install-secrets:
	@: $${GH_TOKEN?GH_TOKEN must be set for 'gh secret set' calls}
	@DEPLOY_TOKEN="$$($(TF) output -raw deploy_token)"; \
	if [ -z "$$DEPLOY_TOKEN" ]; then echo "no deploy_token in state — apply first"; exit 1; fi; \
	echo "==> k8s: writing CLOUDFLARE_API_TOKEN to instant-secrets-cf in instant-$(ENV)"; \
	kubectl create secret generic instant-secrets-cf \
		-n instant-$(ENV) \
		--from-literal=CLOUDFLARE_API_TOKEN="$$DEPLOY_TOKEN" \
		--dry-run=client -o yaml | kubectl apply -f -; \
	echo "==> GH org secrets: CLOUDFLARE_API_TOKEN across instanodedev/{api,worker,provisioner,instanode-web,dashboard,infra,cli,mcp}"; \
	for repo in instanodedev/api instanodedev/worker instanodedev/provisioner \
	            instanodedev/instanode-web instanodedev/dashboard \
	            instanodedev/infra instanodedev/cli instanodedev/mcp; do \
		gh secret set CLOUDFLARE_API_TOKEN -b"$$DEPLOY_TOKEN" -R "$$repo" >/dev/null \
			&& echo "  ✓ $$repo" \
			|| echo "  ✗ $$repo (skipped — repo missing or not authorized)"; \
	done; \
	unset DEPLOY_TOKEN
	@echo
	@echo "==> Admin/tunnel token (Token B) is operator-only — NOT pushed to CI."
	@echo "    To install into your local 1Password vault:"
	@echo "      $(TF) output -raw admin_tunnel_token | op item create --category=ApiCredential --title='cf-admin-tunnel-$(ENV)' credential=-"

# Bump expiry by 180d (deploy) / 90d (admin) — operator edits the .auto.tfvars
# to set new dates, then this target runs the plan/apply/install loop.
rotate-tokens:
	@echo "==> Edit $(ENV).auto.tfvars to set new *_expires_on dates, then:"
	@echo "      make plan ENV=$(ENV)"
	@echo "      make apply ENV=$(ENV)"
	@echo "      make install-secrets ENV=$(ENV)"
	@echo "    Confirm the rotation in the CF dashboard audit log before"
	@echo "    revoking the previous token version."

# Tearing down staging is OK (Phase 1 acceptance allows it). NEVER
# run against production — D-3 cutover keeps state on DO throughout.
destroy:
	@if [ "$(ENV)" = "production" ]; then \
		echo "ABORTING — destroy against production is forbidden (D-1/D-3)."; \
		exit 1; \
	fi
	$(TF) destroy -var-file=$(ENV).auto.tfvars

clean:
	rm -f tfplan.bin
