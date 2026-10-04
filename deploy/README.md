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

Nginx edge (installed by bootstrap / `ensure-edge.sh`, not under `/opt`):

```text
/etc/nginx/sites-available/splitsmarter
/etc/nginx/splitsmarter.d/mail-service.conf   # location /mail/ → 127.0.0.1:8083
```

**Secrets policy:** CI does **not** enumerate keys from [`required-secrets.yml`](required-secrets.yml). Sync writes the full APPSECRET body; deploy only checks that `env/<service>.env` exists and is non-empty.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [`sync-host-secrets.yml`](../.github/workflows/sync-host-secrets.yml) | `workflow_dispatch` / `workflow_call` | APPSECRET → `env/<service>.env` (no Docker required) |
| [`python-docker-deploy.yml`](../.github/workflows/python-docker-deploy.yml) | `workflow_call` | CI → GHCR → file present + Docker + nginx preflight → compose recreate + edge health |

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
1) bootstrap.sh (as root)     → Docker, deploy user, dirs, nginx edge, UFW
2) sync-host-secrets (CI)     → uploads scripts + writes env/<service>.env as deploy
3) app deploy (CI)            → compose pull/up + localhost health + /mail/ edge check
```

`/opt/splitsmarter` is a conventional app root (not mandatory). Override with `DEPLOY_PATH` in the INSTANCE Variable / inventory. Bootstrap always `chown -R deploy:deploy` on that path so sync can write `env/`.

## First-time droplet setup (bootstrap)

1. Create Droplet (Ubuntu LTS) + **VPC** + Cloud Firewall (**22 / 80 / 443** public). Prefer **Managed Postgres** in the same VPC; **never expose 5432** publicly (trusted source = apps Droplet only).
2. Create DB `mail_forex_geo` and schema `mail` on Managed Postgres when ready.
3. Copy the **full** `deploy/droplet/` folder (so `nginx/` + `ensure-edge.sh` are present) and run as **root**:

```bash
export DEPLOY_SSH_PUBLIC_KEY='ssh-ed25519 AAAA... gha-deploy'
# optional: export DEPLOY_PATH=/opt/splitsmarter
# optional internal-only :80: export UFW_HTTP_ALLOW_FROM='10.116.0.8'
sudo -E bash bootstrap.sh
```

Bootstrap installs Docker + Compose, creates `deploy` (docker group), creates `${DEPLOY_PATH}/{scripts,env}` **owned by deploy**, optional SSH password-login disable (`HARDEN_SSH=1`), **Nginx path edge**, and **UFW** (OpenSSH + 80/443; never opens container ports like 8083).

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
7. Push `mail-service` → preflight (file present + Docker + nginx) → compose up → health on `127.0.0.1:8083` **and** `http://127.0.0.1/mail/health`.

## SSH hardening

- Key-only auth for `deploy` (bootstrap sets `PasswordAuthentication no` when `HARDEN_SSH=1`).
- Per-instance deploy key in `{ENV}_INSTANCE_{N}` as plain `SSH_KEY=`.
- CI uses `-o Port=` so the same options work for `ssh` and `scp`.
- Practical v1 firewall: 22 + 80/443; rely on key-only + fail2ban as needed; DB only via VPC.
- Optional later: Cloudflare Tunnel / Tailscale so SSH is not public.

## Edge proxy (Nginx only — no Caddy)

Mail binds to `127.0.0.1:8083` only. **Nginx** on the Droplet terminates public **80** and path-routes:

| Path | Upstream |
|------|----------|
| `/mail/` | `127.0.0.1:8083` (prefix stripped) |

Configs live in [`droplet/nginx/`](droplet/nginx/). Install / refresh as root:

```bash
# from a copy of deploy/droplet/ on the host
sudo bash ensure-edge.sh
```

**What deploy checks (per service with `edge_path` in inventory):**

1. **Preflight / check-host:** nginx is active; soft-warn if UFW has no `80/tcp` rule visible.
2. **After compose up:** `curl` direct `127.0.0.1:8083/health`, then `curl` via edge `127.0.0.1/mail/health`.

CI cannot reconfigure UFW (needs root). If edge checks fail, re-run `ensure-edge.sh` as root on that host. Prefer also keeping DO Cloud Firewall aligned (22/80/443; **not** 8083).

Add another service later: drop `droplet/nginx/locations/<service>.conf`, set `edge_path` in `instances.yml`, re-run `ensure-edge.sh` as root, redeploy.

Point the gateway `MAIL_SERVICE_HOSTNAME` at `http://<host>/mail` (or your public URL) when ready.

## SSH key bootstrap

```bash
ssh-keygen -t ed25519 -C "gha-deploy-development-instance-1" -f ./dev_instance_1_ed25519 -N ""
# Public  -> Droplet /home/deploy/.ssh/authorized_keys (or DEPLOY_SSH_PUBLIC_KEY for bootstrap)
# Private -> DEVELOPMENT_INSTANCE_1 Variable as SSH_KEY=...
```

## Adding another instance or service

1. Add target/service (optional `target_ids`, `edge_path`) in `instances.yml`.
2. Create matching Variables (`PRODUCTION_INSTANCE_2`, `QA_APPSECRET_MAILSERVICE`, …).
3. Extend the `env:` injection blocks in `sync-host-secrets.yml` and `python-docker-deploy.yml` with the new Variable names (Actions cannot dynamically index `vars[name]`).
4. Bootstrap the new droplet (if INSTANCE); add nginx location + `ensure-edge.sh`; run sync for APPSECRET; deploy.
