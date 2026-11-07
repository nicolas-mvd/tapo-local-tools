#!/usr/bin/env python3
"""Read Tapo camera motion metadata over local discovery."""

import argparse
import datetime
import errno
import ipaddress
import json
import math
import secrets
import select
import socket
import struct
import subprocess
import time
import zlib


STATUS_INTERVAL = 5
MAX_ALARM_TIMESTAMP = 253402300799


def discovery_body():
    private_key = subprocess.check_output(
        ["openssl", "genrsa", "2048"], stderr=subprocess.DEVNULL
    )
    public_key = subprocess.check_output(
        ["openssl", "rsa", "-pubout"], input=private_key, stderr=subprocess.DEVNULL
    )
    return json.dumps({"params": {"rsa_key": public_key.decode("ascii")}}).encode()


def discovery_packet(body):
    # TP-Link TDP discovery header. The CRC is calculated with the magic value
    # in the checksum slot, then written back into that slot.
    header = struct.pack(
        ">BBHHBBII", 2, 0, 1, len(body), 17, 0, secrets.randbits(32), 0x5A6B7C8D
    )
    packet = header + body
    return packet[:12] + struct.pack(">I", zlib.crc32(packet)) + body


def local_time(timestamp):
    if not isinstance(timestamp, int) or timestamp <= 0:
        return "unknown"
    try:
        return datetime.datetime.fromtimestamp(timestamp).astimezone().isoformat()
    except (OverflowError, OSError, ValueError):
        return "unknown"


def emit(event_type, **fields):
    print(json.dumps({"type": event_type, **fields}), flush=True)


def alarm_value(value):
    if value is None:
        return 0
    if type(value) is int and 0 <= value <= MAX_ALARM_TIMESTAMP:
        return value
    return None


def watch(hosts, duration, events, poll_interval=0.25):
    body = discovery_body()
    latest = {}
    last_reply = {}
    probe_errors = {}
    deadline = time.monotonic() + duration if duration is not None else float("inf")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        if events:
            emit("ready")
        while time.monotonic() < deadline:
            packet = discovery_packet(body)
            for host in hosts:
                try:
                    udp.sendto(packet, (host, 20004))
                except OSError as error:
                    now = time.monotonic()
                    previous = probe_errors.get(host)
                    if previous is None or error.errno != previous[0] or now - previous[1] >= STATUS_INTERVAL:
                        probe_errors[host] = (error.errno, now)
                        reason = errno.errorcode.get(error.errno, "unknown error")
                        if events:
                            emit("error", host=host, reason=f"UDP probe failed ({reason})")

            round_end = min(deadline, time.monotonic() + poll_interval)
            while (remaining := round_end - time.monotonic()) > 0:
                if not select.select([udp], [], [], remaining)[0]:
                    break
                try:
                    data, (host, port) = udp.recvfrom(16384)
                except OSError:
                    # A transient socket error cannot identify a camera on an
                    # unconnected UDP socket. Start another polling round.
                    break
                if host not in hosts or port != 20004:
                    continue
                try:
                    result = json.loads(data[16:]).get("result", {})
                except (AttributeError, ValueError, RecursionError):
                    continue
                if not isinstance(result, dict) or result.get("device_type") != "SMART.IPCAMERA":
                    continue

                current = (result.get("last_alarm_time"), result.get("sd_status"))
                previous = latest.get(host)
                if events:
                    alarm = alarm_value(current[0])
                    changed = alarm is not None and (previous is None or alarm > previous)
                    if changed:
                        latest[host] = alarm
                    now = time.monotonic()
                    recovering = probe_errors.pop(host, None) is not None
                    if changed or recovering or host not in last_reply or now - last_reply[host] >= STATUS_INTERVAL:
                        last_reply[host] = now
                        emit("reply", host=host, alarm=alarm, motion=changed and previous is not None)
                    continue
                if current != previous:
                    latest[host] = current
                    label = result.get("device_name") or host
                    alarm, storage = current
                    print(
                        f"Camera {label} ({host}) | last alarm {local_time(alarm)}"
                        f" | SD status {storage or 'unknown'}",
                        flush=True,
                    )
    if not events:
        print(f"{len(latest)}/{len(hosts)} cameras replied during the test.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hosts", nargs="+", type=ipaddress.IPv4Address)
    parser.add_argument("--seconds", type=int)
    parser.add_argument("--events", action="store_true", help="emit readiness, camera replies and motion as JSON lines")
    parser.add_argument(
        "--interval", type=float, default=0.25,
        help="seconds between discovery probes (0.1–60; default: 0.25)",
    )
    args = parser.parse_args()
    if args.seconds is not None and not 1 <= args.seconds <= 300:
        parser.error("--seconds must be between 1 and 300")
    if not math.isfinite(args.interval) or not 0.1 <= args.interval <= 60:
        parser.error("--interval must be between 0.1 and 60 seconds")
    hosts = {str(host) for host in args.hosts}
    duration = args.seconds if args.events else args.seconds or 60
    watch(hosts, duration, args.events, args.interval)


if __name__ == "__main__":
    main()
