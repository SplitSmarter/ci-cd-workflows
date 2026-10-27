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
  env/forex-services.env
  scripts/sync-env.sh
  scripts/validate-env.sh  # presence-only check for env/<service>.env
  scripts/check-host.sh
  scripts/deploy-service.sh
```

Nginx edge (installed by bootstrap / `ensure-edge.sh`, not under `/opt`):

```text
/etc/nginx/sites-available/splitsmarter
/etc/nginx/splitsmarter.d/gateway.conf        # location / → 127.0.0.1:8080
/etc/nginx/splitsmarter.d/mail-service.conf   # location /mail/ → 127.0.0.1:8083
/etc/nginx/splitsmarter.d/forex-services.conf # location /forex/ → 127.0.0.1:8093
```

**Secrets policy:** CI does **not** enumerate keys from [`required-secrets.yml`](required-secrets.yml). Sync writes the full APPSECRET body; deploy only checks that `env/<service>.env` exists and is non-empty.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [`sync-host-secrets.yml`](../.github/workflows/sync-host-secrets.yml) | `workflow_dispatch` / `workflow_call` | APPSECRET → `env/<service>.env`. `service_name` is a dropdown of completed pipelines (`mail-service`, `forex-services`, `gateway`, `main-website`) |
| [`python-docker-deploy.yml`](../.github/workflows/python-docker-deploy.yml) | `workflow_call` | Python → GHCR → compose + edge health |
| [`java-docker-deploy.yml`](../.github/workflows/java-docker-deploy.yml) | `workflow_call` | Java/Maven → GHCR → compose + edge health |

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

Prerequisite: Droplet has the **`deploy` user** and your SSH public key in `/home/deploy/.ssh/authorized_keys`. A fresh image only has `root`. Create `deploy` first (below); `prepare-staging.sh` does not create the user and exits with `user deploy does not exist yet` if you skip this.

```text
1) prepare-staging.sh (root, manual)  → creates /tmp/deploy owned by deploy
2) scp edge kit (Windows → deploy)    → bootstrap.sh + ensure-edge.sh + nginx/
3) bootstrap.sh (root)                → Docker, /opt/splitsmarter, nginx edge, UFW
4) sync-host-secrets (CI)             → scripts + env/<service>.env
5) app deploy (CI)                    → compose up + localhost + /mail/ and /forex/ health
```

`/opt/splitsmarter` is the default app root. Override with `DEPLOY_PATH` in the INSTANCE Variable / inventory.

## First-time droplet setup (Windows)

Replace `YOUR.DROPLET.IP` and the key path if needed. Local kit path assumes this repo checkout.

### 0) Ensure the deploy user exists

`prepare-staging.sh` only creates `/tmp/deploy` and `chown`s it to `deploy`. Log in as **root** and create the user if `id deploy` fails.

Use the public half of the same key you will pass to `ssh -i` (for this droplet, `C:\Users\Niles\.ssh\dev_instance_2.pub` — one line, no quotes). Quote the Windows path; an unquoted `$env:USERPROFILE\.ssh\...` is not expanded and OpenSSH reports `Identity file ... not accessible`.

```powershell
ssh -i "C:\Users\Niles\.ssh\dev_instance_2" root@YOUR.DROPLET.IP
```

On the droplet, as root:

```bash
id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# paste the single line from the matching .pub file
echo 'ssh-ed25519 AAAA…comment' > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys
chmod 600 /home/deploy/.ssh/authorized_keys
```

Confirm from Windows (this must succeed before `prepare-staging.sh`):

```powershell
ssh -i "C:\Users\Niles\.ssh\dev_instance_2" deploy@YOUR.DROPLET.IP
```

Also ensure Org Variables / Secrets exist before CI steps (`DEVELOPMENT_INSTANCE_1`, `DEVELOPMENT_APPSECRET_MAILSERVICE`, `GHCR_USERNAME`, `GHCR_TOKEN`). Prefer Managed Postgres in the same VPC; never expose 5432 or 8083 publicly. Cloud Firewall: **22 / 80 / 443**.

### 1) prepare-staging (manual, as root)

`deploy` cannot create a world-writable staging dir reliably; run this once as **root** on the droplet.

Option A — from Windows, if you have root SSH:

```powershell
$key = "$env:USERPROFILE\.ssh\dev_instance_1"
# copy prepare-staging only, then run as root
scp -i $key "D:\Projects\split smarter\ci-cd-workflows\deploy\droplet\prepare-staging.sh" root@YOUR.DROPLET.IP:/tmp/prepare-staging.sh
ssh -i $key root@YOUR.DROPLET.IP "bash /tmp/prepare-staging.sh"
```

Option B — already on the droplet as root:

```bash
# paste or upload prepare-staging.sh, then:
bash prepare-staging.sh
# equivalent: mkdir -p /tmp/deploy && chown deploy:deploy /tmp/deploy && chmod 755 /tmp/deploy
```

### 2) scp bootstrap + edge kit (as deploy, from Windows)

```powershell
$key = "$env:USERPROFILE\.ssh\dev_instance_1"
$droplet = "deploy@YOUR.DROPLET.IP"
$src = "D:\Projects\split smarter\ci-cd-workflows\deploy\droplet"

scp -i $key "$src\bootstrap.sh" "${droplet}:/tmp/deploy/bootstrap.sh"
scp -i $key "$src\ensure-edge.sh" "${droplet}:/tmp/deploy/ensure-edge.sh"
scp -i $key -r "$src\nginx" "${droplet}:/tmp/deploy/nginx"
```

On the host you should have:

```text
/tmp/deploy/bootstrap.sh
/tmp/deploy/ensure-edge.sh
/tmp/deploy/nginx/splitsmarter.conf
/tmp/deploy/nginx/locations/mail-service.conf
```

### 3) bootstrap (as root on the droplet)

```bash
cd /tmp/deploy
# optional: export DEPLOY_PATH=/opt/splitsmarter
# optional: export UFW_HTTP_ALLOW_FROM='10.116.0.8'
bash bootstrap.sh
```

From Windows with root SSH:

```powershell
ssh -i $env:USERPROFILE\.ssh\dev_instance_1 root@YOUR.DROPLET.IP "cd /tmp/deploy && bash bootstrap.sh"
```

Bootstrap **requires** `ensure-edge.sh` + `nginx/` next to `bootstrap.sh` (fails if missing). Installs Docker + Compose, `/opt/splitsmarter/{scripts,env}` owned by `deploy`, nginx `/mail/` → `127.0.0.1:8083` and `/forex/` → `127.0.0.1:8093`, UFW 22/80/443 (not 8083 or 8093). Keeps `/tmp/deploy` owned by `deploy` for later uploads.

### 4) sync-host-secrets (CI)

In **ci-cd-workflows**, run workflow **Sync Host Secrets**:

- `environment` = `development` (or qa / testing / production)
- `service_name` = one of the dropdown values (`mail-service`, `forex-services`, `gateway`, `main-website`)

This uploads host scripts and writes `/opt/splitsmarter/env/<service>.env` as `deploy` (for example `env/mail-service.env` or `env/forex-services.env`). Do this before the first app deploy (and again when APPSECRET changes). Forex uses `{ENV}_APPSECRET_FOREXSERVICES`.

### 5) app deployment (CI)

Push / run the app repo pipeline (e.g. `mail-service` or `forex-services` → `python-docker-deploy.yml`). It preflights secrets file + Docker + nginx, then compose up. Health: `http://127.0.0.1:8083/health` and `http://127.0.0.1/mail/health` for mail; `http://127.0.0.1:8093/health` and `http://127.0.0.1/forex/health` for forex. On an API droplet that was bootstrapped before `/forex/` existed, re-run `ensure-edge.sh` as root before the first forex deploy so the nginx check can pass.

### Org Variable examples

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

**`DEVELOPMENT_APPSECRET_MAILSERVICE`** (example)

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

**`DEVELOPMENT_APPSECRET_FOREXSERVICES`** (example)

```text
APP_NAME=forex-service
ENV=prod
FOREX_DATABASE_URL=postgresql+asyncpg://user:pass@PRIVATE_HOST:25060/mail_forex_geo
CURRENCYLAYER_ACCESS_KEY=...
EXCHANGERATE_ACCESS_KEY=...
RATE_REFRESH_INTERVAL_HOURS=1
ENABLE_DB_SCHEMA_INIT=true
```

## SSH hardening

- Key-only auth for `deploy` (bootstrap sets `PasswordAuthentication no` when `HARDEN_SSH=1`).
- Per-instance deploy key in `{ENV}_INSTANCE_{N}` as plain `SSH_KEY=`.
- CI uses `-o Port=` so the same options work for `ssh` and `scp`.
- Practical v1 firewall: 22 + 80/443; rely on key-only + fail2ban as needed; DB only via VPC.
- Optional later: Cloudflare Tunnel / Tailscale so SSH is not public.

## Edge proxy (Nginx only — no Caddy)

Containers bind localhost only. **Nginx** on the Droplet terminates public **80**:

| Path | Upstream |
|------|----------|
| `/` | `127.0.0.1:8080` (gateway catch-all) |
| `/mail/` | `127.0.0.1:8083` (prefix stripped) |
| `/forex/` | `127.0.0.1:8093` (prefix stripped) |

Configs live in [`droplet/nginx/`](droplet/nginx/). After adding/changing locations, refresh as root:

```bash
# from a copy of deploy/droplet/ on the host
sudo bash ensure-edge.sh
```

**What deploy checks (per service with `edge_path` in inventory):**

1. **Preflight / check-host:** nginx is active; soft-warn if UFW has no `80/tcp` rule visible.
2. **After compose up:** direct localhost health, then edge (`http://127.0.0.1/health` for gateway, `http://127.0.0.1/mail/health` for mail, `http://127.0.0.1/forex/health` for forex).

CI cannot reconfigure UFW (needs root). If edge checks fail, re-run `ensure-edge.sh` as root. Keep DO Cloud Firewall on 22/80/443 (**not** 8080/8083).

### Gateway APPSECRET (`{ENV}_APPSECRET_GATEWAY`)

Sync with `service_name=gateway` before first deploy. Example keys (PEM as quoted one-liners with `\n`, same as local `.env`):

```text
DB_USER=...
DB_PASSWORD=...
SPRING_R2DBC_URL=r2dbc:postgresql://PRIVATE_HOST:25060/gateway
USER_BACKEND_URL=http://...
MAIL_BACKEND_URL=http://127.0.0.1/mail
SHARED_SECRET=...
MICROSERVICES_SECRET=...
INTERNAL_SECRET=...
PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
PUBLIC_KEY="-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----"
GOOGLE_WEB_CLIENT_ID=...
REFRESH_TOKEN_VALIDITY_SECONDS=108000
ACCESS_TOKEN_VALIDITY_SECONDS=300
```

Same-host mail via nginx: set `MAIL_BACKEND_URL=http://127.0.0.1/mail` (not `:8083`).

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
