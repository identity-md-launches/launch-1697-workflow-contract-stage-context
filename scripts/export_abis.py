#!/usr/bin/env python3
"""Export only compiler-produced ABI arrays; --check detects stale documentation."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name in ("LaunchToken", "Graveyard"):
        artifact_path = root / "out" / f"{name}.sol" / f"{name}.json"
        if not artifact_path.is_file():
            raise SystemExit(f"Missing {artifact_path}; run forge build first.")
        artifact = json.loads(artifact_path.read_text())
        contents = json.dumps(artifact["abi"], indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.is_file() or destination.read_text() != contents:
                raise SystemExit(f"Stale or missing {destination}; regenerate ABIs.")
            print(f"ABI matches: {name}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(contents)
            print(f"Exported: {name}")


if __name__ == "__main__":
    main()
