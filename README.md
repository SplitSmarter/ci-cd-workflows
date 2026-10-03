# ci-cd-workflows

Central reusable GitHub Actions for SplitSmarter.

## Workflows

| Workflow | Purpose |
|----------|---------|
| [`.github/workflows/expo-deploy.yml`](.github/workflows/expo-deploy.yml) | Expo / EAS mobile builds |
| [`.github/workflows/python-docker-deploy.yml`](.github/workflows/python-docker-deploy.yml) | Python service → GHCR → Droplet Compose deploy |
| [`.github/workflows/sync-host-secrets.yml`](.github/workflows/sync-host-secrets.yml) | Sync `{ENV}_APPSECRET_*` Variables to Droplet `.env` |

## Backend deploy docs

See [`deploy/README.md`](deploy/README.md) for:

- `{ENV}_{TYPE}_{REST}` Variable naming (`DEVELOPMENT_INSTANCE_1`, `DEVELOPMENT_APPSECRET_MAILSERVICE`)
- Droplet bootstrap (`deploy/droplet/bootstrap.sh`)
- Inventory (`deploy/instances.yml`)
- First-time setup and smoke-deploy sequence
