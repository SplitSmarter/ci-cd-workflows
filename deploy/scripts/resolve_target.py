#!/usr/bin/env python3
"""Resolve deploy targets from deploy/instances.yml for GitHub Actions outputs."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


def service_rest(service_name: str) -> str:
    return service_name.replace("-", "").upper()


def instance_name(env: str, target_id) -> str:
    return f"{env.upper()}_INSTANCE_{target_id}"


def appsecret_name(env: str, service_name: str) -> str:
    return f"{env.upper()}_APPSECRET_{service_rest(service_name)}"


def resolve_env(branch_name: str, branch_map: dict) -> str:
    return branch_map.get(branch_name, "development")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--branch-name", default="")
    parser.add_argument("--environment", default="")
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--instance-id", default="")
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()

    data = yaml.safe_load(args.inventory.read_text(encoding="utf-8"))
    defaults = data.get("defaults") or {}
    branch_map = data.get("branch_map") or {}
    instances = data.get("instances") or {}

    if args.environment:
        env = args.environment
    elif args.branch_name:
        env = resolve_env(args.branch_name, branch_map)
    else:
        print("Either --environment or --branch-name is required", file=sys.stderr)
        return 1

    if env not in instances:
        print(f"Unknown environment '{env}' in inventory", file=sys.stderr)
        return 1

    block = instances[env]
    services = block.get("services") or {}
    if args.service_name not in services:
        print(
            f"Service '{args.service_name}' is not defined for environment '{env}'",
            file=sys.stderr,
        )
        return 1

    service = services[args.service_name]
    targets = block.get("targets") or []
    if args.instance_id:
        targets = [t for t in targets if str(t.get("id")) == str(args.instance_id)]
        if not targets:
            print(
                f"Instance id '{args.instance_id}' not found for environment '{env}'",
                file=sys.stderr,
            )
            return 1

    # Optional per-service placement: services.<name>.target_ids
    service_target_ids = service.get("target_ids")
    if service_target_ids is not None:
        wanted = {str(x) for x in service_target_ids}
        targets = [t for t in targets if str(t.get("id")) in wanted]
        if not targets:
            print(
                f"Service '{args.service_name}' target_ids {sorted(wanted)} "
                f"do not match any targets for environment '{env}'",
                file=sys.stderr,
            )
            return 1

    target_ids = [str(t["id"]) for t in targets]
    instance_names = [instance_name(env, tid) for tid in target_ids]
    appsec = appsecret_name(env, args.service_name)

    result = {
        "env": env,
        "service_name": args.service_name,
        "compose_service": service.get("compose_service", args.service_name),
        "image_name": service.get("image_name", args.service_name),
        "container_port": str(service.get("container_port", 8083)),
        "health_path": service.get("health_path", "/health"),
        # Public nginx path prefix (e.g. /mail). Empty = skip edge traffic check.
        "edge_path": str(service.get("edge_path") or ""),
        "deploy_path": defaults.get("deploy_path", "/opt/splitsmarter"),

        "registry": defaults.get("registry", "ghcr.io/splitsmarter"),
        "appsecret_name": appsec,
        "target_ids": json.dumps(target_ids),
        "instance_names": json.dumps(instance_names),
        "instance_name": instance_names[0] if len(instance_names) == 1 else "",
        "target_id": target_ids[0] if len(target_ids) == 1 else "",
    }

    if args.github_output:
        github_output = os.environ.get("GITHUB_OUTPUT")
        if not github_output:
            print("GITHUB_OUTPUT is not set", file=sys.stderr)
            return 1
        with open(github_output, "a", encoding="utf-8") as fh:
            for key, value in result.items():
                fh.write(f"{key}={value}\n")
    else:
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
