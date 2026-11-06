#!/usr/bin/python3
"""Open this helper in Terminal to authorize live view in Tapo Menu."""

import ast
import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import stat
import sys
import tempfile
from urllib.request import urlopen
from zipfile import ZipFile

from camera_status import is_lan_ipv4


WHEEL_URL = (
    "https://files.pythonhosted.org/packages/0c/c3/"
    "c4f44e04f0f9b2eb711128545641ef5a8b417f8965034935995b59428353/"
    "tplink_cloud_api-5.2.2-py3-none-any.whl"
)
WHEEL_SHA256 = "e2655653d76e5c2981e958118d8569d2fce214bccc6c0836504dd7592918f64c"
WHEEL_FILES = (
    "tplinkcloud/signing.py",
    "tplinkcloud/certs/__init__.py",
    "tplinkcloud/certs/tplink-ca-chain.pem",
    "tplink_cloud_api-5.2.2.dist-info/licenses/LICENSE",
)


def private_path(path, *, directory=False):
    metadata = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise OSError(f"Check that {path} belongs to you and has private permissions.")


def local_config(app_directory):
    app_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    private_path(app_directory, directory=True)
    config = app_directory / "config.json"
    try:
        private_path(config)
        return config
    except FileNotFoundError:
        pass

    print("Enter the local IPv4 address of each camera.")
    hosts = []
    for camera_id in ("1", "2"):
        while True:
            host = input(f"Cam {camera_id} IPv4 address: ").strip()
            if is_lan_ipv4(host) and host not in hosts:
                hosts.append(host)
                break
            print("Enter a distinct private IPv4 address for each camera.")

    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=app_directory) as file:
        cameras = [{"id": str(index), "host": host} for index, host in enumerate(hosts, start=1)]
        json.dump({"cameras": cameras}, file, indent=2)
        file.write("\n")
        file.flush()
        try:
            os.link(file.name, config)
        except FileExistsError:
            pass
    private_path(config)
    return config


def prepare_cloud_modules(directory):
    # The SDK's signing and CA modules use only the standard library.
    with urlopen(WHEEL_URL, timeout=18) as response:
        contents = response.read(64 * 1024 + 1)
    if hashlib.sha256(contents).hexdigest() != WHEEL_SHA256:
        raise ValueError("The downloaded TP-Link sign-in library failed verification.")
    with ZipFile(io.BytesIO(contents)) as wheel:
        for name in WHEEL_FILES:
            destination = directory / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            source = wheel.read(name)
            if name.endswith(".py") and sys.version_info < (3, 10):
                # Postpone newer type annotations for Apple's Python 3.9.
                # Insert the future import after any module docstring.
                text = source.decode("utf-8")
                module = ast.parse(text)
                lines = text.splitlines(keepends=True)
                index = module.body[0].end_lineno if ast.get_docstring(module) is not None else 0
                lines.insert(index, "from __future__ import annotations\n")
                source = "".join(lines).encode("utf-8")
            destination.write_bytes(source)
    (directory / "tplinkcloud/__init__.py").touch()


def main():
    if len(sys.argv) != 1 or not sys.stdin.isatty():
        print("Open this sign-in helper in Terminal to continue.", file=sys.stderr)
        return 1

    os.umask(0o077)
    app_directory = Path.home() / "Library/Application Support/Tapo Menu"
    scripts = Path(__file__).resolve().parent.parent / "scripts"
    login = scripts / "tapo-login.py"
    if not login.is_file() or not (scripts / "install-credentials.py").is_file():
        print("The Tapo Menu sign-in files are missing. Rebuild the app and try again.", file=sys.stderr)
        return 1

    config = local_config(app_directory)
    tokens = app_directory / "camera-tokens.json"
    try:
        private_path(tokens)
    except FileNotFoundError:
        pass

    with tempfile.TemporaryDirectory(prefix="tapo-menu-sign-in-") as directory:
        prepare_cloud_modules(Path(directory))
        sys.path.insert(0, directory)
        sys.argv = [str(login), "--config", str(config), "--token-file", str(tokens), "--require-discovery"]
        runpy.run_path(str(login), run_name="__main__")
    print("Sign-in complete. You can open either camera from Tapo Menu.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (EOFError, KeyboardInterrupt):
        sys.exit(130)
    except (OSError, ValueError, KeyError):
        print("Could not prepare Tapo sign-in. Check your connection and permissions, then try again.", file=sys.stderr)
        sys.exit(1)
