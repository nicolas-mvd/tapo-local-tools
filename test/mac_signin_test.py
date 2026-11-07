import importlib.machinery
import importlib.util
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch


def load_worker():
    source = Path(__file__).resolve().parents[1] / "macos/Sign in to Tapo.command"
    loader = importlib.machinery.SourceFileLoader("tapo_sign_in", str(source))
    worker = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(worker)
    return worker


class SignInTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.support = Path(temporary.name)
        self.attempt = self.support / "sign-in-fixture"
        self.attempt.mkdir(mode=0o700)
        self.config = self.attempt / "config.json"
        self.config.write_text("{}")
        self.config.chmod(0o600)
        self.worker = load_worker()

    def sign_in(self, fake_login):
        with (
            patch.object(self.worker, "prepare_cloud_modules"),
            patch.object(self.worker.runpy, "run_path", fake_login),
            patch.object(sys, "path", sys.path.copy()),
            patch.object(sys, "argv", sys.argv.copy()),
        ):
            return self.worker.sign_in(self.support, self.attempt)

    def test_success_only_stages_tokens_for_the_app(self):
        def fake_login(*_args, **_kwargs):
            destination = Path(sys.argv[sys.argv.index("--token-file") + 1])
            self.assertEqual(destination.parent.parent, self.support)
            self.assertNotEqual(destination.parent, self.attempt)
            destination.write_text("fixture-tokens")
            destination.chmod(0o600)

        self.assertEqual(self.sign_in(fake_login), 0)
        self.assertEqual((self.attempt / "camera-tokens.json").read_text(), "fixture-tokens")
        self.assertEqual(list(self.support.iterdir()), [self.attempt])

    @unittest.skipUnless(hasattr(signal, "pthread_kill"), "requires POSIX thread signals")
    def test_cancel_interrupts_waiting_helper(self):
        def interrupt(_signum, _frame):
            raise KeyboardInterrupt

        previous = signal.signal(signal.SIGHUP, interrupt)
        self.addCleanup(signal.signal, signal.SIGHUP, previous)
        read_fd, write_fd = os.pipe()
        self.addCleanup(os.close, read_fd)
        self.addCleanup(os.close, write_fd)

        def fake_login(*_args, **_kwargs):
            cancellation = threading.Timer(0.1, self.config.unlink)
            cancellation.start()
            try:
                select.select([read_fd], [], [], 2)
                self.fail("Cancellation did not interrupt the helper")
            finally:
                cancellation.join()

        with self.assertRaises(KeyboardInterrupt):
            self.sign_in(fake_login)
        self.assertFalse((self.attempt / "camera-tokens.json").exists())


if __name__ == "__main__":
    unittest.main()
