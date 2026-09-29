#!/usr/bin/env python3
"""Validate public deployment inputs without signing or making network requests."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
FIELDS = {"chainId", "owner", "recipient", "workers", "requireSafeOwner"}


def address(value: Any, label: str) -> str:
    if not isinstance(value, str) or not ADDRESS.fullmatch(value) or int(value, 16) == 0:
        raise ValueError(f"{label} must be a nonzero 20-byte hexadecimal address")
    return value


def validate(config: Any) -> dict[str, Any]:
    if not isinstance(config, dict) or set(config) != FIELDS:
        raise ValueError(f"Config must contain exactly these public fields: {sorted(FIELDS)}")
    if type(config["chainId"]) is not int or not 0 < config["chainId"] < 2**256:
        raise ValueError("chainId must be a positive uint256 integer")
    owner = address(config["owner"], "owner").lower()
    address(config["recipient"], "recipient")
    if not isinstance(config["workers"], list):
        raise ValueError("workers must be an array, including for a single worker")
    seen: set[str] = set()
    for i, value in enumerate(config["workers"]):
        worker = address(value, f"workers[{i}]").lower()
        if worker == owner:
            raise ValueError("Keep the owner separate from workers")
        if worker in seen:
            raise ValueError(f"Duplicate worker: {value}")
        seen.add(worker)
    if type(config["requireSafeOwner"]) is not bool:
        raise ValueError("requireSafeOwner must be a boolean")
    return config


def load_config(path: str | Path) -> dict[str, Any]:
    # Reject duplicate JSON keys instead of silently accepting the last value.
    def unique_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"Duplicate JSON key: {key}")
            result[key] = value
        return result

    return validate(json.loads(Path(path).read_text(encoding="utf-8"), object_pairs_hook=unique_pairs))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
    except (OSError, ValueError) as exc:
        print(f"Invalid configuration: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(config, indent=2))
    print("Structural validation passed. Chain, Safe modules and token behavior still require verification.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
