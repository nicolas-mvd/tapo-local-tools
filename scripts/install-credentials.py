#!/usr/bin/env python3
"""Atomically install camera credentials received on stdin. Never echo them."""

import ipaddress
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def validate(payload):
    if not isinstance(payload, dict) or payload.get("type") != "tapo-lat/v1":
        return False
    cameras = payload.get("cameras")
    if not isinstance(cameras, dict) or not 1 <= len(cameras) <= 16:
        return False
    for name, entry in cameras.items():
        if not re.fullmatch(r"camera[a-zA-Z0-9][a-zA-Z0-9-]{0,23}", name):
            return False
        if not isinstance(entry, dict) or set(entry) != {"host", "lat"}:
            return False
        try:
            ipaddress.IPv4Address(entry["host"])
        except (TypeError, ValueError):
            return False
        if not isinstance(entry["lat"], str) or not re.fullmatch(r"[!-~]{1,4096}", entry["lat"]):
            return False
    return True


def main():
    if len(sys.argv) != 2 or sys.stdin.isatty():
        sys.exit("Usage: camera credential pipe | install-credentials.py /absolute/destination.json")
    destination = Path(sys.argv[1])
    if not destination.is_absolute():
        sys.exit("Credential destination must be absolute.")
    maximum = 64 * 1024
    try:
        raw = sys.stdin.buffer.read(maximum + 1)
        payload = json.loads(raw) if len(raw) <= maximum else None
    except (ValueError, OSError, RecursionError):
        payload = None
    if not validate(payload):
        sys.exit("Invalid or empty camera credentials. Existing credentials were preserved.")

    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(payload, handle, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except OSError:
        sys.exit("Could not install camera credentials.")
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print(f"Installed credentials for {len(payload['cameras'])} camera(s).", file=sys.stderr)


if __name__ == "__main__":
    main()
