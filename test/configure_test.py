import json
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


CONFIGURE = Path(__file__).resolve().parents[1] / "scripts/configure.py"


class ProfileTest(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.root = Path(root.name)
        self.destination = self.root / "staged.json"

    def configure(self, *args, previous="", answers=""):
        return subprocess.run(
            [sys.executable, str(CONFIGURE), str(previous), str(self.destination),
             str(self.root / "default"), str(self.root / "status.json"), *args],
            input=answers, capture_output=True, text=True, check=False,
        )

    def profile(self, config):
        directory = self.root / "previous"
        directory.mkdir()
        (directory / "config.json").write_text(json.dumps(config))
        return directory

    def test_interactive_single_camera_and_exact_folder(self):
        folder = self.root / "Local Recordings"
        result = self.configure(answers=f"10.42.0.21\nPorch\n\n{folder}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.destination.read_text())
        self.assertEqual(config["cameras"], [{"id": "1", "host": "10.42.0.21", "name": "Porch"}])
        self.assertEqual(config["recordingsDir"], str(folder))
        self.assertEqual(stat.S_IMODE(self.destination.stat().st_mode), 0o600)

    def test_refresh_preserves_existing_config(self):
        config = {
            "cameras": [{"id": "door", "host": "10.42.0.21", "name": "Front door"}],
            "recordingsDir": str(self.root / "custom"),
            "pollIntervalMs": 800,
            "retentionDays": 14,
            "maxStorageBytes": 4096,
        }
        result = self.configure("--refresh-tokens", previous=self.profile(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        written = json.loads(self.destination.read_text())
        self.assertEqual(written, {**config, "statusFile": str(self.root / "status.json")})

    def test_explicit_cameras_and_storage_settings(self):
        result = self.configure("--camera", "front", "10.42.0.21", "Front door",
                                "--camera", "side", "10.42.0.22", "Side door",
                                "--retention-days", "7", "--max-storage-mib", "2048",
                                "--min-free-mib", "512", "--clip-seconds", "25")
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.destination.read_text())
        self.assertEqual([camera["id"] for camera in config["cameras"]], ["front", "side"])
        self.assertEqual(config["retentionDays"], 7)
        self.assertEqual(config["maxStorageBytes"], 2048 * 1024**2)
        self.assertEqual(config["minFreeBytes"], 512 * 1024**2)
        self.assertEqual(config["clipSeconds"], 25)

    def test_legacy_address_override_keeps_name_and_folder(self):
        previous = self.profile({
            "cameras": [{"id": "1", "host": "10.42.0.21", "name": "Porch"}],
            "recordingsDir": str(self.root / "custom"),
        })
        result = self.configure("--camera-1", "10.42.0.22", previous=previous)
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.destination.read_text())
        self.assertEqual(config["cameras"], [{"id": "1", "host": "10.42.0.22", "name": "Porch"}])
        self.assertEqual(config["recordingsDir"], str(self.root / "custom"))

    def test_rejects_invalid_or_conflicting_settings(self):
        for args in [
            ("--camera", "front", "8.8.8.8", "Front"),
            ("--camera", "front", "10.42.0.21", "Front", "--camera", "side", "10.42.0.21", "Side"),
            ("--camera-1", "10.42.0.21", "--recordings-dir", "/"),
            ("--camera-1", "10.42.0.21", "--min-free-mib", "-1"),
            ("--refresh-tokens",),
        ]:
            with self.subTest(args=args):
                result = self.configure(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.destination.exists())
