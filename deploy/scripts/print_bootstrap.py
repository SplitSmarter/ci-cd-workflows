#!/usr/bin/env python3
"""Print first-time droplet commands in order. Does not SSH or change the server.

Assumes the droplet already accepts ROOT login with the same private key as the
GitHub Variable {ENV}_INSTANCE_{id} (local file ~/.ssh/dev_instance_{id} unless
--key is set).

Example (PowerShell):
  python deploy/scripts/print_bootstrap.py --env development --instance 2 --ip 143.244.132.219
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ENVS = ("development", "qa", "testing", "production")


def bash_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def ps_quote(value: str) -> str:
    return '"' + value.replace('"', '`"') + '"'


def load_services(inventory: Path, env: str, instance_id: str) -> list[str]:
    """Services in instances.yml whose target_ids include this instance. Empty if YAML is unavailable."""
    try:
        import yaml
    except ImportError:
        return []
    if not inventory.is_file():
        return []
    data = yaml.safe_load(inventory.read_text(encoding="utf-8")) or {}
    block = (data.get("instances") or {}).get(env) or {}
    targets = block.get("targets") or []
    known = {str(t.get("id")) for t in targets}
    if known and instance_id not in known:
        print(
            f"ERROR: instance id {instance_id} is not listed under instances.{env}.targets in {inventory}",
            file=sys.stderr,
        )
        sys.exit(1)
    names: list[str] = []
    for name, spec in (block.get("services") or {}).items():
        ids = {str(i) for i in (spec.get("target_ids") or [])}
        if instance_id in ids:
            names.append(name)
    return names


def step(n: int, where: str, why: str, body: str) -> str:
    return f"\n{'=' * 72}\n{n}) WHERE: {where}\n   {why}\n{'-' * 72}\n{body.rstrip()}\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--env", required=True, choices=ENVS)
    parser.add_argument("--instance", required=True, type=int, help="Instance id, e.g. 2 -> DEVELOPMENT_INSTANCE_2")
    parser.add_argument("--ip", required=True, help="Droplet public IPv4")
    parser.add_argument("--key", type=Path, help="Private key path (default: ~/.ssh/dev_instance_<id>)")
    parser.add_argument("--deploy-user", default="deploy")
    parser.add_argument("--inventory", type=Path, help="defaults to deploy/instances.yml next to this script")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    deploy_dir = script_dir.parent
    droplet_dir = deploy_dir / "droplet"
    inventory = args.inventory or (deploy_dir / "instances.yml")

    instance_id = str(args.instance)
    variable = f"{args.env.upper()}_INSTANCE_{instance_id}"
    key = (args.key or (Path.home() / ".ssh" / f"dev_instance_{instance_id}")).expanduser().resolve()
    pub = Path(str(key) + ".pub")

    ip = args.ip.strip()
    user = args.deploy_user
    key_ps = ps_quote(str(key))
    root = f"root@{ip}"
    deploy_at = f"{user}@{ip}"

    if pub.is_file():
        pub_line = pub.read_text(encoding="utf-8").strip().splitlines()[0].strip()
        pub_note = f"using {pub}"
    else:
        pub_line = "ssh-ed25519 AAAA...comment"
        pub_note = f"MISSING {pub} - replace the echo line with that .pub file (one line)"

    services = load_services(inventory, args.env, instance_id)
    service_lines = "\n".join(f"  - {name}" for name in services) if services else "  - (install PyYAML to list services from instances.yml)"

    prepare = droplet_dir / "prepare-staging.sh"
    bootstrap = droplet_dir / "bootstrap.sh"
    edge = droplet_dir / "ensure-edge.sh"
    nginx = droplet_dir / "nginx"

    out = [
        f"Bootstrap checklist for {variable}",
        f"Droplet: {ip}",
        f"Private key (same key as {variable}): {key}",
        f"Public key: {pub_note}",
        "This script only prints commands. Run them yourself, in order.",
        "deploy cannot run prepare-staging.sh or bootstrap.sh (those need root).",
        step(
            1,
            "Windows PowerShell - log in as root",
            "Confirm this machine accepts the instance key for root.",
            f'ssh -i {key_ps} {root}',
        ),
        step(
            2,
            "Droplet shell - you are root (after step 1)",
            f"Create Linux user {user} and install the matching public key. Skip useradd if `id {user}` already succeeds.",
            "\n".join(
                [
                    f"id {user} >/dev/null 2>&1 || useradd -m -s /bin/bash {user}",
                    f"install -d -m 700 -o {user} -g {user} /home/{user}/.ssh",
                    f"echo {bash_single_quote(pub_line)} > /home/{user}/.ssh/authorized_keys",
                    f"chown {user}:{user} /home/{user}/.ssh/authorized_keys",
                    f"chmod 600 /home/{user}/.ssh/authorized_keys",
                ]
            ),
        ),
        step(
            3,
            "Windows PowerShell - log in as deploy",
            "Stop if this fails. Later scp steps use this user.",
            f'ssh -i {key_ps} {deploy_at}',
        ),
        step(
            4,
            "Windows PowerShell - copy and run prepare-staging as root",
            "Creates /tmp/deploy owned by deploy. Does not install Docker.",
            "\n".join(
                [
                    f'scp -i {key_ps} {ps_quote(str(prepare))} {root}:/tmp/prepare-staging.sh',
                    f'ssh -i {key_ps} {root} "bash /tmp/prepare-staging.sh"',
                ]
            ),
        ),
        step(
            5,
            "Windows PowerShell - copy the edge kit as deploy",
            "Writes bootstrap.sh, ensure-edge.sh, and nginx/ into /tmp/deploy.",
            "\n".join(
                [
                    f'scp -i {key_ps} {ps_quote(str(bootstrap))} {deploy_at}:/tmp/deploy/bootstrap.sh',
                    f'scp -i {key_ps} {ps_quote(str(edge))} {deploy_at}:/tmp/deploy/ensure-edge.sh',
                    f'scp -i {key_ps} -r {ps_quote(str(nginx))} {deploy_at}:/tmp/deploy/nginx',
                ]
            ),
        ),
        step(
            6,
            "Windows PowerShell - run bootstrap as root",
            "Installs Docker, nginx, and UFW. Must be root. Do not run this as deploy.",
            f'ssh -i {key_ps} {root} "cd /tmp/deploy && bash bootstrap.sh"',
        ),
        step(
            7,
            "GitHub Actions - not a shell on the droplet",
            f"App containers start here. {variable} must use SSH_HOST={ip} and SSH_USER={user} with this private key.",
            "\n".join(
                [
                    f"Variable: {variable}",
                    "Then run sync-host-secrets, then the service deploy workflow, for:",
                    service_lines,
                ]
            ),
        ),
    ]
    sys.stdout.write("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
