#!/usr/bin/env python3
"""Prepare a Safe Transaction Builder batch; never sign or broadcast transactions."""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from validate_config import address, load_config


def calldata(signature: str, *args: str) -> str:
    result = subprocess.run(["cast", "calldata", signature, *args], check=True, capture_output=True, text=True)
    data = result.stdout.strip()
    if not data.startswith("0x"):
        raise ValueError("cast returned invalid calldata")
    bytes.fromhex(data[2:])
    return data


def build_batch(config: dict[str, Any], sweeper: str, tokens: list[str], include_unpause: bool) -> dict[str, Any]:
    address(sweeper, "sweeper")
    seen: set[str] = set()
    transactions: list[dict[str, str]] = []
    for token in tokens:
        address(token, "token")
        if token.lower() == sweeper.lower() or token.lower() in seen:
            raise ValueError("Tokens must be distinct and must not be the sweeper")
        seen.add(token.lower())
        transactions.append({"to": sweeper, "value": "0", "data": calldata("setTokenAllowed(address,bool)", token, "true")})
    if include_unpause:
        transactions.append({"to": sweeper, "value": "0", "data": calldata("unpause()")})
    if not transactions:
        raise ValueError("Provide --token or explicitly request --include-unpause")
    return {
        "version": "1.0",
        "chainId": str(config["chainId"]),
        "createdAt": int(time.time() * 1000),
        "meta": {
            "name": "BatchPermitSweeper owner configuration",
            "description": "Review target chain, bytecode, tokens and owner before execution.",
            "createdFromSafeAddress": config["owner"],
        },
        "transactions": transactions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--sweeper", required=True)
    parser.add_argument("--token", action="append", default=[])
    parser.add_argument("--include-unpause", action="store_true", help="Explicitly append unpause after token configuration")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        config = load_config(args.config)
        batch = build_batch(config, args.sweeper, args.token, args.include_unpause)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as output:
            json.dump(batch, output, indent=2)
            output.write("\n")
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"Cannot create owner batch: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote unsigned transactions to {args.output}. Nothing was broadcast.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
