#!/usr/bin/env python3
"""Provision the configured Tapo cameras from an interactive TP-Link sign-in."""

import argparse
import binascii
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import stat
import struct
import subprocess
import sys
import termios
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from tplinkcloud.certs import get_ca_cert_path
from tplinkcloud.signing import TAPO_ACCESS_KEY, TAPO_SECRET_KEY, get_signing_headers


ACCOUNT_ENTRY = "https://n-wap.i.tplinkcloud.com"
APP_NAME = "TP-Link_Tapo_Android"
APP_VERSION = "3.22.105"
IOT_SERVICE = "nbu.iot-app-server.app-v2"
API_ACCOUNT = "/api/v2/account/"
API_GET_APP_SERVICE = "/api/v2/common/getAppServiceUrl"
DEFAULT_CONFIG = "/etc/tapo-recorder/config.json"
DEFAULT_TOKEN_FILE = "/etc/tapo-recorder/camera-tokens.json"
LAN_NETWORKS = tuple(ipaddress.IPv4Network(network) for network in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
))


class CloudFailure(Exception):
    """Message contains only a fixed stage and, optionally, a numeric code."""


def tp_origin(value):
    if not isinstance(value, str):
        raise CloudFailure("TP-Link did not return a valid regional service URL.")
    try:
        parsed = urllib.parse.urlsplit(value)
        hostname = parsed.hostname or ""
        valid = (
            parsed.scheme == "https"
            and parsed.username is None
            and parsed.password is None
            and parsed.port in (None, 443)
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
            and re.fullmatch(r"[a-z0-9][a-z0-9.-]*", hostname)
            and hostname.endswith((".tplinkcloud.com", ".tplinknbu.com"))
        )
    except ValueError:
        valid = False
    if not valid:
        raise CloudFailure("Rejected a regional URL outside the allowed TP-Link HTTPS domains.")
    return "https://" + hostname


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def terminal_prompt(prompt, *, hidden):
    try:
        with open("/dev/tty", "r", encoding="utf-8") as source:
            with open("/dev/tty", "w", encoding="utf-8") as display:
                fd = source.fileno()
                original = termios.tcgetattr(fd)
                try:
                    if hidden:
                        settings = original.copy()
                        settings[3] &= ~(termios.ECHO | termios.ECHONL)
                        termios.tcsetattr(fd, termios.TCSAFLUSH, settings)
                    display.write(prompt)
                    display.flush()
                    entered = source.readline()
                finally:
                    if hidden:
                        termios.tcsetattr(fd, termios.TCSAFLUSH, original)
                        display.write("\n")
                        display.flush()
    except (OSError, termios.error):
        raise CloudFailure("Could not open an interactive Terminal prompt.") from None
    if not entered:
        raise CloudFailure("Terminal input was closed.")
    return entered.rstrip("\r\n")


def number(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if isinstance(value, str) and re.fullmatch(r"-?[0-9]{1,10}", value):
        return int(value)
    return None


def error_code(reply):
    return number(reply.get("error_code", reply.get("errorCode")))


def result_body(reply):
    data = reply.get("result")
    return data if isinstance(data, dict) else {}


def require_success(reply, stage):
    code = error_code(reply)
    if code != 0:
        if code is None:
            raise CloudFailure(f"{stage}: unexpected response format.")
        raise CloudFailure(f"{stage}: TP-Link reported code {code}.")
    return result_body(reply)


class CloudClient:
    def __init__(self):
        self.terminal = uuid.uuid4().hex.upper()
        self.query = {
            "appName": APP_NAME, "appVer": APP_VERSION, "netType": "wifi",
            "termID": self.terminal, "ospf": "Android 14", "brand": "TPLINK",
            "locale": "en_US", "model": "Android", "termName": "Android",
            "termMeta": "Android",
        }
        self.agent = f"{APP_NAME}/{APP_VERSION}(Android/;Android 14)"
        context = ssl.create_default_context()
        context.load_verify_locations(cafile=get_ca_cert_path())
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            urllib.request.HTTPSHandler(context=context),
        )

    def request(self, host, path, stage, *, query=None, headers=None, body=None):
        url = tp_origin(host) + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url, data=body,
            headers={"Accept": "application/json", "User-Agent": self.agent, **(headers or {})},
            method="POST" if body is not None else "GET",
        )
        try:
            with self.opener.open(request, timeout=18) as response:
                raw = response.read(4 * 1024 * 1024 + 1)
        except urllib.error.HTTPError as exc:
            raise CloudFailure(f"{stage}: TP-Link returned HTTP {exc.code}.") from None
        except (urllib.error.URLError, OSError):
            raise CloudFailure(f"{stage}: HTTPS connection failed.") from None
        if len(raw) > 4 * 1024 * 1024:
            raise CloudFailure(f"{stage}: response exceeded the size limit.")
        try:
            reply = json.loads(raw)
        except (UnicodeError, ValueError, RecursionError):
            raise CloudFailure(f"{stage}: response was not valid JSON.") from None
        if not isinstance(reply, dict):
            raise CloudFailure(f"{stage}: unexpected response format.")
        return reply

    def account_post(self, host, path, stage, payload, *, token=None):
        body = json.dumps(payload, separators=(",", ":"))
        headers = {
            "Content-Type": "application/json;charset=UTF-8",
            **get_signing_headers(body, path, TAPO_ACCESS_KEY, TAPO_SECRET_KEY),
        }
        query = self.query.copy()
        if token:
            query["token"] = token
        return self.request(host, path, stage, query=query, headers=headers, body=body.encode())

    def login(self, email, password):
        identity = {"appType": APP_NAME, "cloudUserName": email}
        status = self.account_post(
            ACCOUNT_ENTRY, API_ACCOUNT + "getAccountStatusAndUrl", "Regional lookup", identity,
        )
        location = require_success(status, "Regional lookup")
        region = tp_origin(location.get("appServerUrlV2") or location.get("appServerUrl"))
        terminal = {"cloudPassword": password, "terminalUUID": self.terminal}
        request = {
            **identity, **terminal, "appVersion": APP_VERSION, "platform": "Android",
            "refreshTokenNeeded": False, "supportBindAccount": False,
            "terminalName": "Android", "terminalMeta": "Android",
        }
        login = self.account_post(region, API_ACCOUNT + "login", "Sign-in", request)
        redirect = result_body(login)
        redirected_url = redirect.get("appServerUrlV2") or redirect.get("appServerUrl")
        if error_code(login) == -20212 and redirected_url:
            redirected = tp_origin(redirected_url)
            if redirected != region:
                region = redirected
                login = self.account_post(region, API_ACCOUNT + "login", "Sign-in", request)
        result = result_body(login)
        process = result.get("MFAProcessId", result.get("mfaProcessId"))
        if process and not result.get("token") and error_code(login) in (0, -20677):
            methods = result.get("supportedMFATypes", [])
            if not isinstance(methods, list) or not any(number(item) == 2 for item in methods):
                raise CloudFailure("This account did not offer email verification for this sign-in.")
            send = self.account_post(
                region, API_ACCOUNT + "getEmailVC4TerminalMFA",
                "Email verification request", {**identity, **terminal, "locale": "en_US"},
            )
            send_data = require_success(send, "Email verification request")
            if error_code(send_data) not in (None, 0):
                require_success(send_data, "Email verification request")
            otp = terminal_prompt("TP-Link verification code from your email: ", hidden=True).strip()
            if not re.fullmatch(r"[0-9]{4,12}", otp):
                raise CloudFailure("The verification code did not have the expected format.")
            verification = {
                **identity, "MFAProcessId": process, "MFAType": 2, "code": otp,
                "terminalBindEnabled": False, "supportBindAccount": False,
            }
            login = self.account_post(
                region, API_ACCOUNT + "checkMFACodeAndLogin", "Email verification", verification,
            )
            result = require_success(login, "Email verification")
        else:
            result = require_success(login, "Sign-in")
        token = result.get("token")
        if not valid_token(token):
            raise CloudFailure("TP-Link did not return a usable account session token.")
        return region, token

    def iot_origin(self, region, token):
        reply = self.account_post(
            region, API_GET_APP_SERVICE, "Camera service lookup",
            {"serviceIds": [IOT_SERVICE]}, token=token,
        )
        mapping = require_success(reply, "Camera service lookup").get("serviceUrls")
        return tp_origin(mapping.get(IOT_SERVICE) if isinstance(mapping, dict) else None)

    def camera_credentials(self, origin, token, targets):
        headers = {
            "Authorization": "ut|" + token,
            "app-cid": f"app:{APP_NAME}:{self.terminal}",
            "x-app-name": APP_NAME, "x-app-version": APP_VERSION,
            "x-term-id": self.terminal, "x-ospf": "Android 14",
            "x-net-type": "wifi", "x-strict": "0", "x-locale": "en_US",
        }
        query = {
            "pageSize": 100, "deviceTypes": "SMART.IPCAMERA",
            "includePcDevice": "false", "includeKasaShareDevices": "true",
            "includeMatterDevice": "false", "includeExternalVendorDeviceInfo": "true",
        }
        found = self._scan_cameras(origin, headers, query, targets, {})
        if len(found) < len(targets):
            del query["deviceTypes"]
            found = self._scan_cameras(origin, headers, query, targets, found)
        return found

    def _scan_cameras(self, origin, headers, query, targets, found):
        for page in range(10):
            reply = self.request(
                origin, "/v2/things", "Camera list", query={"page": page, **query}, headers=headers,
            )
            if error_code(reply) is not None:
                reply = require_success(reply, "Camera list")
            data = reply.get("data")
            if not isinstance(data, list):
                raise CloudFailure("Camera list: unexpected response format.")
            for thing in data:
                if not isinstance(thing, dict):
                    continue
                target = targets.get(normalize_mac(thing.get("mac")))
                lat = thing.get("localAccessToken")
                if target and valid_token(lat):
                    name, host = target
                    entry = {"host": host, "lat": lat}
                    if name in found and found[name] != entry:
                        raise CloudFailure("TP-Link returned conflicting credentials for a target camera.")
                    found[name] = entry
            total = number(reply.get("total"))
            if total is None:
                last_page = len(data) < query["pageSize"]
            else:
                last_page = (page + 1) * query["pageSize"] >= total
            if len(found) == len(targets) or not data or last_page:
                break
        return found


def valid_token(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[!-~]{1,4096}", value))


def normalize_mac(value):
    if not isinstance(value, str):
        return None
    mac = re.sub(r"[-:.]", "", value.strip()).lower()
    if not re.fullmatch(r"[0-9a-f]{12}", mac) or mac in {"0" * 12, "f" * 12}:
        return None
    return mac


def read_config(filename):
    try:
        with Path(filename).open("rb") as source:
            raw = source.read(64 * 1024 + 1)
        config = json.loads(raw) if len(raw) <= 64 * 1024 else None
    except (OSError, ValueError, RecursionError):
        config = None
    cameras = config.get("cameras") if isinstance(config, dict) else None
    if not isinstance(cameras, list) or not 1 <= len(cameras) <= 16:
        raise CloudFailure("The recorder config needs between 1 and 16 cameras.")
    ids, hosts = set(), set()
    for camera in cameras:
        if not isinstance(camera, dict):
            raise CloudFailure("The recorder config contains an invalid camera.")
        name = camera.get("id")
        host = camera.get("host")
        if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,23}", name):
            raise CloudFailure("The recorder config contains an invalid camera ID.")
        try:
            address = ipaddress.IPv4Address(host) if isinstance(host, str) else None
        except ValueError:
            address = None
        if address is None or not any(address in network for network in LAN_NETWORKS):
            raise CloudFailure("Every camera must use a private IPv4 address.")
        if name in ids or host in hosts:
            raise CloudFailure("The recorder config repeats a camera ID or address.")
        ids.add(name)
        hosts.add(host)
    return config


def discovery_body():
    """Generate the public key for Tapo discovery without a private key on disk."""
    try:
        generated = subprocess.run(
            ["openssl", "genrsa", "2048"], capture_output=True, check=True, timeout=8,
        )
        public = subprocess.run(
            ["openssl", "rsa", "-pubout"], input=generated.stdout,
            capture_output=True, check=True, timeout=4,
        ).stdout.decode("ascii")
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None
    return json.dumps({"params": {"rsa_key": public}}, separators=(",", ":")).encode()


def discovery_packet(payload):
    header = struct.pack(
        ">BBHHBBII", 2, 0, 1, len(payload), 17, 0, secrets.randbits(32), 0x5A6B7C8D,
    )
    packet = bytearray(header + payload)
    struct.pack_into(">I", packet, 12, binascii.crc32(packet))
    return packet


def discovery_mac(packet):
    try:
        reply = json.loads(packet[16:])
    except (ValueError, RecursionError):
        return None
    info = result_body(reply) if isinstance(reply, dict) else {}
    if info.get("device_type") != "SMART.IPCAMERA":
        return None
    return normalize_mac(info.get("mac"))


def discover_macs(hosts, payload, ports):
    found = {}
    pending = set(hosts)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
            for _ in range(3):
                probe = discovery_packet(payload)
                for host in pending:
                    for port in ports:
                        try:
                            connection.sendto(probe, (host, port))
                        except OSError:
                            continue
                deadline = time.monotonic() + 2
                while pending and (remaining := deadline - time.monotonic()) > 0:
                    connection.settimeout(remaining)
                    try:
                        packet, (peer, port) = connection.recvfrom(65535)
                    except socket.timeout:
                        break
                    if peer in pending and port in ports and (mac := discovery_mac(packet)):
                        found[peer] = mac
                        pending.remove(peer)
                if not pending:
                    break
    except OSError:
        pass
    return found


def resolve_camera_targets(cameras, *, require_discovery):
    payload = discovery_body()
    if payload is None and require_discovery:
        raise CloudFailure("Could not create the discovery probe. Check that OpenSSL is available.")
    ports = (20004,) if require_discovery else (20004, 20002)
    found = discover_macs([camera["host"] for camera in cameras], payload, ports) if payload else {}
    targets = {}
    for camera in cameras:
        name, host = camera["id"], camera["host"]
        mac = found.get(host)
        if mac is None:
            guidance = "Wake the camera and check that this machine can reach it on UDP 20004."
            if require_discovery:
                raise CloudFailure(f"Camera {name} ({host}) did not reply. {guidance}")
            print(f"Camera {name} ({host}) did not reply. {guidance}", file=sys.stderr)
            mac = normalize_mac(terminal_prompt(
                f"Camera {name} MAC address from its label: ", hidden=False,
            ))
            if mac is None:
                raise CloudFailure(f"Camera {name} needs a valid MAC address.")
        if mac in targets:
            raise CloudFailure("Two configured cameras resolved to the same MAC address.")
        targets[mac] = ("camera" + name, host)
    return targets


def credential_destination(value):
    if not isinstance(value, str):
        raise CloudFailure("The token file path must be an absolute runtime path.")
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise CloudFailure("The token file path must be an absolute runtime path.")
    try:
        owner = os.geteuid()
        parent = path.parent.resolve()
        destination = parent / path.name
        if destination.is_relative_to("/nix/store"):
            raise CloudFailure("The token file must be outside the Nix store.")
        closest = parent
        while not closest.exists():
            closest = closest.parent
        for ancestor in reversed((parent, *parent.parents)):
            if ancestor.exists():
                metadata = ancestor.stat()
                if (
                    not stat.S_ISDIR(metadata.st_mode)
                    or metadata.st_uid not in (0, owner)
                    or metadata.st_mode & 0o022
                ):
                    raise CloudFailure("Token file directories must belong to you or root and exclude other writers.")
        if not os.access(closest, os.W_OK | os.X_OK):
            raise CloudFailure("The token file directory is not writable. Use --token-file for a private writable location.")
        if destination.is_symlink():
            raise CloudFailure("The token file path must not be a symlink.")
        if destination.exists():
            metadata = destination.stat()
            if metadata.st_uid != owner or not stat.S_ISREG(metadata.st_mode):
                raise CloudFailure("The existing token file must be a regular file that you own.")
    except (OSError, RuntimeError, ValueError):
        raise CloudFailure("Could not validate the token file path.") from None
    return destination


def install_credentials(destination, credentials):
    try:
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        installer = Path(__file__).with_name("install-credentials.py")
        document = {"type": "tapo-lat/v1", "cameras": credentials}
        result = subprocess.run(
            [sys.executable, str(installer), str(destination)],
            input=json.dumps(document, separators=(",", ":")).encode(),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError:
        raise CloudFailure("Could not install camera credentials.") from None
    if result.returncode:
        raise CloudFailure("Could not install camera credentials. Existing credentials were preserved.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="recorder JSON config path")
    parser.add_argument("--token-file", help="override the private runtime token file path")
    parser.add_argument(
        "--require-discovery", action="store_true",
        help="require each camera to respond on the local network before sign-in",
    )
    args = parser.parse_args()
    os.umask(0o077)
    config = read_config(args.config)
    destination = credential_destination(args.token_file or config.get("tokenFile", DEFAULT_TOKEN_FILE))
    targets = resolve_camera_targets(config["cameras"], require_discovery=args.require_discovery)

    client = CloudClient()
    email = terminal_prompt("TP-Link ID (email, hidden): ", hidden=True).strip()
    if "@" not in email or len(email) > 320:
        raise CloudFailure("Enter the email address for the owner’s TP-Link ID.")
    password = terminal_prompt("TP-Link password (hidden): ", hidden=True)
    if not password:
        raise CloudFailure("No password was entered.")
    region, token = client.login(email, password)
    del email, password
    credentials = client.camera_credentials(client.iot_origin(region, token), token, targets)
    missing = [name[6:] for name, _ in targets.values() if name not in credentials]
    if missing:
        raise CloudFailure(
            "TP-Link returned no local access token for camera ID(s) "
            + ", ".join(missing) + ". Existing credentials were preserved."
        )
    install_credentials(destination, credentials)
    print(f"Installed local access tokens for {len(credentials)} camera(s).", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except CloudFailure as exc:
        print(f"Tapo sign-in: {exc}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Tapo sign-in canceled.", file=sys.stderr)
        sys.exit(130)
    except Exception:
        print("Tapo sign-in stopped due to an unexpected local error.", file=sys.stderr)
        sys.exit(1)
