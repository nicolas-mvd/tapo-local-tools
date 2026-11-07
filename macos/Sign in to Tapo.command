#!/usr/bin/python3
"""Open this helper in Terminal to authorize live view in Tapo Menu."""

import ast
import hashlib
import io
import os
from pathlib import Path
import re
import runpy
import signal
import stat
import sys
import tempfile
import threading
from urllib.request import urlopen
from zipfile import ZipFile

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


def sign_in(app_directory, attempt):
    scripts = Path(__file__).resolve().parent.parent / "scripts"
    login = scripts / "tapo-login.py"
    if not login.is_file() or not (scripts / "install-credentials.py").is_file():
        print("The Tapo Menu sign-in files are missing. Rebuild the app and try again.", file=sys.stderr)
        return 1

    config = attempt / "config.json"
    private_path(config)
    with tempfile.TemporaryDirectory(prefix=".sign-in-", dir=app_directory) as directory:
        working = Path(directory)
        tokens = working / "camera-tokens.json"
        prepare_cloud_modules(working)
        sys.path.insert(0, directory)
        sys.argv = [str(login), "--config", str(config), "--token-file", str(tokens)]
        if not config.is_file():
            return 130
        finished = threading.Event()
        terminal_thread = threading.get_ident()

        def watch_attempt():
            while not finished.wait(0.25):
                if not config.is_file():
                    # Interrupt this helper only, including if it is waiting on Terminal input.
                    signal.pthread_kill(terminal_thread, signal.SIGHUP)
                    return

        watcher = threading.Thread(target=watch_attempt, daemon=True)
        watcher.start()
        try:
            runpy.run_path(str(login), run_name="__main__")
        finally:
            finished.set()
            watcher.join()
        try:
            os.replace(tokens, attempt / "camera-tokens.json")
        except FileNotFoundError:
            print("The sign-in attempt was canceled in Tapo Menu.")
            return 130
    print("Sign-in complete. You can return to Tapo Menu.")
    return 0


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"[A-F0-9-]{36}", sys.argv[1]) or not sys.stdin.isatty():
        print("Choose Sign In from the Tapo Menu icon to continue.", file=sys.stderr)
        return 1

    os.umask(0o077)
    app_directory = Path.home() / "Library/Application Support/Tapo Menu"
    attempt = app_directory / ("sign-in-" + sys.argv[1])

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGHUP, interrupted)
    result = 1
    try:
        private_path(app_directory, directory=True)
        private_path(attempt, directory=True)
        result = sign_in(app_directory, attempt)
    except SystemExit as exc:
        result = exc.code if isinstance(exc.code, int) and exc.code else 1
    except (EOFError, KeyboardInterrupt):
        print("Tapo sign-in canceled.", file=sys.stderr)
        result = 130
    except (OSError, ValueError, KeyError):
        print("Could not prepare Tapo sign-in. Check your connection and permissions, then try again.", file=sys.stderr)
    finally:
        if result:
            try:
                (attempt / "failed").touch(mode=0o600)
            except OSError:
                pass
    return result


if __name__ == "__main__":
    sys.exit(main())
