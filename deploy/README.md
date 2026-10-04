# SplitSmarter deploy inventory & droplet tooling

Central deploy config for DigitalOcean Droplet + Docker Compose deploys.

## Naming: `{ENV}_{TYPE}_{REST}` (plain names)

Org **Actions Variables** (v1 — sensitive values may live in the Variable body). Keep names **plain and searchable**:

| TYPE | Example | Contents (`KEY=VALUE`) |
|------|---------|-------------------------|
| `INSTANCE` | `DEVELOPMENT_INSTANCE_1` | `SSH_HOST`, `SSH_USER`, `SSH_PORT`, `DEPLOY_PATH`, `SSH_KEY` |
| `APPSECRET` | `DEVELOPMENT_APPSECRET_MAILSERVICE` | App runtime keys (`MAIL_DATABASE_URL`, SMTP keys, …) |

- `ENV` = `development` / `qa` / `testing` / `production` (uppercase)
- Instance `REST` = target id from [`instances.yml`](instances.yml) (e.g. `1`)
- Appsecret `REST` = service name with hyphens removed (`mail-service` → `MAILSERVICE`)

Org **Secrets** (registry only for v1):

- `GHCR_USERNAME`
- `GHCR_TOKEN`

## Host layout

```text
/opt/splitsmarter/
  docker-compose.yml
  env/mail-service.env     # sync-host-secrets output (mode 600)
  scripts/sync-env.sh
  scripts/validate-env.sh  # presence-only check for env/<service>.env
  scripts/check-host.sh
  scripts/deploy-service.sh
```

**Secrets policy:** CI does **not** enumerate keys from [`required-secrets.yml`](required-secrets.yml). Sync writes the full APPSECRET body; deploy only checks that `env/<service>.env` exists and is non-empty.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [`sync-host-secrets.yml`](../.github/workflows/sync-host-secrets.yml) | `workflow_dispatch` / `workflow_call` | APPSECRET → `env/<service>.env` (no Docker required) |
| [`python-docker-deploy.yml`](../.github/workflows/python-docker-deploy.yml) | `workflow_call` | CI → GHCR → file present + Docker preflight → compose recreate |

App repos (e.g. `mail-service`) only need a thin caller:

```yaml
jobs:
  call-central-workflow:
    uses: SplitSmarter/ci-cd-workflows/.github/workflows/python-docker-deploy.yml@main
    with:
      branch_name: ${{ github.ref }}
      service_name: mail-service
    secrets:
      GHCR_USERNAME: ${{ secrets.GHCR_USERNAME }}
      GHCR_TOKEN: ${{ secrets.GHCR_TOKEN }}
```

## Startup order (new droplet)

```text
1) bootstrap.sh (as root)     → Docker, deploy user, dirs, ownership, firewall
2) sync-host-secrets (CI)     → uploads scripts + writes env/<service>.env as deploy
3) app deploy (CI)            → compose pull/up + health
```

`/opt/splitsmarter` is a conventional app root (not mandatory). Override with `DEPLOY_PATH` in the INSTANCE Variable / inventory. Bootstrap always `chown -R deploy:deploy` on that path so sync can write `env/`.

## First-time droplet setup (bootstrap)

1. Create Droplet (Ubuntu LTS) + **VPC** + Cloud Firewall (**22 / 80 / 443** public). Prefer **Managed Postgres** in the same VPC; **never expose 5432** publicly (trusted source = apps Droplet only).
2. Create DB `mail_forex_geo` and schema `mail` on Managed Postgres when ready.
3. Copy **only** `bootstrap.sh` to the host (or the full `deploy/droplet/` folder) and run as **root**:

```bash
export DEPLOY_SSH_PUBLIC_KEY='ssh-ed25519 AAAA... gha-deploy'
# optional: export DEPLOY_PATH=/opt/splitsmarter
sudo -E bash bootstrap.sh
```

Bootstrap installs Docker + Compose, creates `deploy` (docker group), creates `${DEPLOY_PATH}/{scripts,env}` **owned by deploy**, optional SSH password-login disable (`HARDEN_SSH=1`), UFW 22/80/443. It does **not** require sibling scripts next to it — **sync-host-secrets** uploads those.

4. Org Variables:

**`DEVELOPMENT_INSTANCE_1`**

```text
SSH_HOST=YOUR.DROPLET.IP
SSH_USER=deploy
SSH_PORT=22
DEPLOY_PATH=/opt/splitsmarter
SSH_KEY=-----BEGIN OPENSSH PRIVATE KEY-----
...full PEM with real newlines, no passphrase...
-----END OPENSSH PRIVATE KEY-----
```

**`DEVELOPMENT_APPSECRET_MAILSERVICE`** (example — include what the app needs)

```text
APP_NAME=mail-service
SMTP2GO_ADMIN_USERNAME=...
SMTP2GO_ADMIN_PASSWORD=...
GMAIL_APP_USER=...
GMAIL_APP_PASSWORD=...
ELASTIC_EMAIL_API_KEY=...
MAILERSEND_API_KEY=...
MAIL_DATABASE_URL=postgresql+asyncpg://user:pass@PRIVATE_HOST:25060/mail_forex_geo
```

5. Org Secrets `GHCR_USERNAME` + `GHCR_TOKEN`.
6. Run **Sync Host Secrets** (`environment=development`, `service_name=mail-service`) → uploads scripts + writes `env/mail-service.env` as `deploy`.
7. Push `mail-service` → preflight (file present + Docker) → compose up → health on `127.0.0.1:8083`.

## SSH hardening

- Key-only auth for `deploy` (bootstrap sets `PasswordAuthentication no` when `HARDEN_SSH=1`).
- Per-instance deploy key in `{ENV}_INSTANCE_{N}` as plain `SSH_KEY=`.
- CI uses `-o Port=` so the same options work for `ssh` and `scp`.
- Practical v1 firewall: 22 + 80/443; rely on key-only + fail2ban as needed; DB only via VPC.
- Optional later: Cloudflare Tunnel / Tailscale so SSH is not public.

## Edge proxy (after first green deploy)

Mail binds to `127.0.0.1:8083` only. Put Nginx or Caddy on the Droplet for public 80/443.

See [`droplet/Caddyfile.example`](droplet/Caddyfile.example). Example Caddy:

```text
mail.example.com {
  reverse_proxy 127.0.0.1:8083
}
```

Point the gateway `MAIL_SERVICE_HOSTNAME` at that public URL when ready.

## SSH key bootstrap

```bash
ssh-keygen -t ed25519 -C "gha-deploy-development-instance-1" -f ./dev_instance_1_ed25519 -N ""
# Public  -> Droplet /home/deploy/.ssh/authorized_keys (or DEPLOY_SSH_PUBLIC_KEY for bootstrap)
# Private -> DEVELOPMENT_INSTANCE_1 Variable as SSH_KEY=...
```

## Adding another instance or service

1. Add target/service (optional `target_ids`) in `instances.yml`.
2. Create matching Variables (`PRODUCTION_INSTANCE_2`, `QA_APPSECRET_MAILSERVICE`, …).
3. Extend the `env:` injection blocks in `sync-host-secrets.yml` and `python-docker-deploy.yml` with the new Variable names (Actions cannot dynamically index `vars[name]`).
4. Bootstrap the new droplet (if INSTANCE); run sync for APPSECRET; deploy.
