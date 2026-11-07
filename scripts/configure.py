#!/usr/bin/env python3
"""Write a staged recorder configuration without touching the active profile."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import sys


LAN_NETWORKS = tuple(map(ipaddress.IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def camera_entry(camera_id, host, name=None):
    if not isinstance(camera_id, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,23}", camera_id):
        raise ValueError("Use 1–24 letters, digits or hyphens for each camera ID.")
    if not isinstance(host, str):
        raise ValueError(f"Camera {camera_id} needs a private IPv4 address.")
    address = ipaddress.IPv4Address(host)
    if not any(address in network for network in LAN_NETWORKS):
        raise ValueError(f"Camera {camera_id} needs a private IPv4 address.")
    if name is not None and (
        not isinstance(name, str) or not name.strip() or len(name) > 80
        or any(ord(character) < 32 or ord(character) == 127 for character in name)
    ):
        raise ValueError(f"Camera {camera_id} needs a name of 1–80 characters.")
    result = {"id": camera_id, "host": str(address)}
    if name is not None:
        result["name"] = name.strip()
    return result


def prompt_cameras():
    cameras = []
    for index in range(1, 17):
        label = f"Cam {index}"
        guidance = " (Enter to finish)" if cameras else ""
        host = input(f"{label} private IPv4 address{guidance}: ").strip()
        if not host and cameras:
            break
        name = input(f"{label} name (Enter for {label}): ").strip() or label
        cameras.append(camera_entry(str(index), host, name))
    return cameras


def absolute_folder(value):
    if (
        not isinstance(value, str) or not Path(value).is_absolute()
        or len(Path(os.path.normpath(value)).parts) < 2
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError("Choose an absolute recordings folder other than /.")
    return os.path.normpath(value)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("previous_profile")
    parser.add_argument("destination", type=Path)
    parser.add_argument("default_folder")
    parser.add_argument("status_file")
    parser.add_argument("--camera", nargs=3, metavar=("ID", "IPV4", "NAME"), action="append")
    parser.add_argument("--camera-1")
    parser.add_argument("--camera-2")
    parser.add_argument("--recordings-dir")
    parser.add_argument("--retention-days", type=int)
    parser.add_argument("--max-storage-mib", type=int)
    parser.add_argument("--min-free-mib", type=int)
    parser.add_argument("--clip-seconds", type=int)
    parser.add_argument("--refresh-tokens", action="store_true")
    args = parser.parse_args()
    os.umask(0o077)

    try:
        settings = (args.camera, args.camera_1, args.camera_2, args.recordings_dir, args.retention_days,
                    args.max_storage_mib, args.min_free_mib, args.clip_seconds)
        if args.refresh_tokens and (not args.previous_profile or any(value is not None for value in settings)):
            raise ValueError("Token refresh needs an existing install and accepts no configuration overrides.")
        if args.camera and (args.camera_1 or args.camera_2):
            raise ValueError("Use either --camera or the --camera-1/--camera-2 shortcuts.")
        config = {}
        if args.previous_profile:
            config = json.loads((Path(args.previous_profile) / "config.json").read_text())
            if not isinstance(config, dict):
                raise ValueError("The existing configuration is invalid.")
        prompted = False
        if args.camera:
            cameras = [camera_entry(*entry) for entry in args.camera]
        else:
            cameras = [
                camera_entry(entry["id"], entry["host"], entry.get("name")) for entry in config.get("cameras", [])
            ]
            overrides = {"1": args.camera_1, "2": args.camera_2}
            for camera in cameras:
                host = overrides.pop(camera["id"], None)
                if host is not None:
                    camera.update(camera_entry(camera["id"], host))
            cameras.extend(camera_entry(camera_id, host) for camera_id, host in overrides.items() if host is not None)
            if not cameras and not args.previous_profile:
                cameras = prompt_cameras()
                prompted = True
        if (
            not 1 <= len(cameras) <= 16
            or len({entry["id"] for entry in cameras}) != len(cameras)
            or len({entry["host"] for entry in cameras}) != len(cameras)
        ):
            raise ValueError("Configure 1–16 cameras with unique IDs and addresses.")

        config["cameras"] = cameras
        recordings_dir = args.recordings_dir
        if prompted and recordings_dir is None:
            recordings_dir = input(f"Recordings folder (Enter for {args.default_folder}): ").strip() or args.default_folder
        config["recordingsDir"] = absolute_folder(
            recordings_dir if recordings_dir is not None else config.get("recordingsDir", args.default_folder)
        )
        config.setdefault("statusFile", args.status_file)
        for key, value, maximum, scale in (
            ("retentionDays", args.retention_days, 36500, 1),
            ("maxStorageBytes", args.max_storage_mib, 1_000_000_000, 1024 * 1024),
            ("minFreeBytes", args.min_free_mib, 1_000_000_000, 1024 * 1024),
        ):
            if value is not None:
                if not 0 <= value <= maximum:
                    raise ValueError(f"{key} is out of range.")
                config[key] = value * scale
        if args.clip_seconds is not None:
            if not 1 <= args.clip_seconds <= 120:
                raise ValueError("Clip duration must be 1–120 seconds.")
            config["clipSeconds"] = args.clip_seconds
        args.destination.write_text(json.dumps(config, indent=2) + "\n")
    except EOFError:
        sys.exit("Tapo camera configuration: setup canceled.")
    except (OSError, KeyError, TypeError, ValueError) as error:
        sys.exit(f"Tapo camera configuration: {error}")


if __name__ == "__main__":
    main()
