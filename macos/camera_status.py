#!/usr/bin/env python3
"""Read configured Tapo cameras' battery status via LAN discovery."""

import argparse
import ipaddress
import json
from pathlib import Path
import re
import socket
import subprocess
import sys
import time


# Support running in the checkout or from the app bundle alongside the helper.
sys.path.append(str(Path(__file__).resolve().parent.parent))
from watch_detection import discovery_body, discovery_packet


PORT = 20004
ATTEMPTS = 6
REPLY_WINDOW = 0.45
LAN_NETWORKS = tuple(map(ipaddress.IPv4Network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


def load_cameras(config_path, hosts):
    if config_path is None:
        return tuple((str(index), host) for index, host in enumerate(hosts, start=1))
    with config_path.open("rb") as source:
        data = source.read(65537)
    if len(data) > 65536:
        raise ValueError("camera configuration is too large")
    cameras = json.loads(data)["cameras"]
    if not isinstance(cameras, list):
        raise ValueError("expected a list of configured cameras")
    return tuple((camera["id"], camera["host"]) for camera in cameras)


def is_lan_ipv4(host):
    try:
        address = ipaddress.IPv4Address(host)
    except ValueError:
        return False
    return any(address in network for network in LAN_NETWORKS)


def validate_cameras(cameras):
    if not 1 <= len(cameras) <= 16:
        raise ValueError("expected 1 to 16 configured cameras")
    result = {}
    ids = set()
    for camera_id, host in cameras:
        if not isinstance(camera_id, str) or not isinstance(host, str):
            raise ValueError("camera ID and host must be strings")
        if not is_lan_ipv4(host):
            raise ValueError("camera address must be private IPv4")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,23}", camera_id) or camera_id in ids or host in result:
            raise ValueError("expected distinct camera addresses and IDs")
        ids.add(camera_id)
        result[host] = {
            "id": camera_id,
            "host": host,
            "batteryPercent": None,
            "charging": None,
            "online": False,
        }
    return result


def read_battery(packet):
    try:
        reply = json.loads(packet[16:])
    except (ValueError, RecursionError):
        return None
    fields = reply.get("result") if isinstance(reply, dict) else None
    if not isinstance(fields, dict) or fields.get("device_type") != "SMART.IPCAMERA":
        return None
    battery = fields.get("battery_percent")
    charging = fields.get("battery_charging")
    return {
        "batteryPercent": battery if type(battery) is int and 0 <= battery <= 100 else None,
        "charging": bool(charging) if type(charging) in (bool, int) and charging in (0, 1) else None,
        "online": True,
    }


def discover(status):
    body = discovery_body()
    pending = set(status)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        for _ in range(ATTEMPTS):
            packet = discovery_packet(body)
            for host in pending:
                try:
                    connection.sendto(packet, (host, PORT))
                except OSError:
                    continue
            deadline = time.monotonic() + REPLY_WINDOW
            while pending:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                connection.settimeout(remaining)
                try:
                    reply, (host, port) = connection.recvfrom(16384)
                except socket.timeout:
                    break
                if host not in pending or port != PORT:
                    continue
                battery = read_battery(reply)
                if battery is not None:
                    status[host].update(battery)
                    pending.remove(host)
            if not pending:
                break


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="recorder JSON config with camera IDs and IPs")
    parser.add_argument("hosts", nargs="*", help="private camera IPs when --config is omitted")
    args = parser.parse_args()
    if bool(args.hosts) == bool(args.config):
        parser.error("provide either a config or camera IPs")
    try:
        status = validate_cameras(load_cameras(args.config, args.hosts))
    except (KeyError, OSError, TypeError, ValueError):
        parser.error("expected 1 to 16 distinct cameras with private IPv4 addresses")
    try:
        discover(status)
    except (OSError, subprocess.SubprocessError):
        sys.exit("Camera discovery could not run.")
    print(json.dumps(sorted(status.values(), key=lambda camera: camera["id"]), separators=(",", ":")))


if __name__ == "__main__":
    main()
