import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parents[1] / "bin" / "elgato-control"

STATUS_EMPTY_KEYS = ("running", "plus", "classic", "pedal", "profile")
STATUS_DAEMON_KEYS = (
    "running", "profile", "plus", "classic", "pedal", "wave", "lights",
    "devices", "recentReports", "lastAction", "lastEvent", "error", "updatedAt",
)


def run_cli(args, config, state, extra_env=None, cache=None):
    env = os.environ.copy()
    env["XDG_CONFIG_HOME"] = str(config)
    env["XDG_STATE_HOME"] = str(state)
    env["XDG_CACHE_HOME"] = str(cache or (config / "cache"))
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=15,
        check=False,
    )


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tempdir.name)
        self.config = root / "config"
        self.state = root / "state"
        self.config.mkdir()
        self.state.mkdir()

    def tearDown(self):
        self.tempdir.cleanup()

    def run_cli(self, *args, extra_env=None):
        return run_cli(list(args), self.config, self.state, extra_env=extra_env)

    def test_missing_command_is_an_error(self):
        result = self.run_cli()
        self.assertNotEqual(0, result.returncode)

    def test_init_writes_default_profile_and_prints_path(self):
        result = self.run_cli("init")
        self.assertEqual(0, result.returncode)
        profile_path = pathlib.Path(result.stdout.strip())
        self.assertTrue(profile_path.is_file())
        self.assertEqual(self.config / "elgato-control" / "profile.json", profile_path)
        profile = json.loads(profile_path.read_text())
        self.assertEqual(8, len(profile["keys"]))
        self.assertEqual(15, len(profile["classicKeys"]))
        self.assertEqual(4, len(profile["dials"]))
        self.assertEqual(3, len(profile["pedals"]))
        self.assertEqual("Noctalia Default", profile["name"])

    def test_status_json_without_daemon_keeps_the_empty_contract(self):
        result = self.run_cli("status", "--json")
        self.assertEqual(0, result.returncode)
        self.assertEqual(result.stdout, json.dumps(json.loads(result.stdout)) + "\n")
        data = json.loads(result.stdout)
        self.assertEqual(set(STATUS_EMPTY_KEYS), set(data))
        self.assertFalse(data["running"])
        self.assertIsNone(data["plus"])
        self.assertIsNone(data["classic"])
        self.assertIsNone(data["pedal"])
        self.assertEqual("Noctalia Default", data["profile"])

    def test_status_without_json_flag_is_the_same_object_pretty_printed(self):
        compact = self.run_cli("status", "--json")
        pretty = self.run_cli("status")
        self.assertEqual(0, compact.returncode)
        self.assertEqual(0, pretty.returncode)
        self.assertEqual(json.loads(compact.stdout), json.loads(pretty.stdout))
        self.assertIn("\n", pretty.stdout)

    def test_status_json_round_trips_a_daemon_shaped_file(self):
        self.run_cli("init")
        status_path = self.state / "elgato-control" / "status.json"
        fixture = {
            "running": True,
            "profile": "Noctalia Default",
            "plus": None,
            "classic": {
                "product": "Stream Deck Mk.2",
                "serial": "ABC",
                "path": "/dev/hidraw0",
                "kind": "classic",
                "family": "classic",
                "capabilities": ["keys", "brightness"],
                "keys": 15,
                "productId": 0x0080,
            },
            "pedal": None,
            "wave": None,
            "lights": [],
            "devices": [{
                "product": "Stream Deck Mk.2",
                "serial": "ABC",
                "path": "/dev/hidraw0",
                "kind": "classic",
                "family": "classic",
                "capabilities": ["keys", "brightness"],
                "keys": 15,
                "productId": 0x0080,
            }],
            "recentReports": {},
            "lastAction": "lock",
            "lastEvent": "04:15:00",
            "error": "",
            "updatedAt": 1,
            "brightness": 55,
        }
        status_path.parent.mkdir(parents=True, exist_ok=True)
        status_path.write_text(json.dumps(fixture, indent=2) + "\n")
        result = self.run_cli("status", "--json")
        self.assertEqual(0, result.returncode)
        data = json.loads(result.stdout)
        for key in STATUS_DAEMON_KEYS:
            self.assertIn(key, data)
        self.assertEqual(fixture, data)
        self.assertTrue(data["running"])
        self.assertEqual("classic", data["classic"]["kind"])
        self.assertEqual(15, data["classic"]["keys"])
        self.assertIsNone(data["plus"])

    def test_set_key_classic_is_one_based_and_persists(self):
        result = self.run_cli("set-key", "--device", "classic", "12", "lock")
        self.assertEqual(0, result.returncode, result.stderr)
        profile = json.loads((self.config / "elgato-control" / "profile.json").read_text())
        self.assertEqual("lock", profile["classicKeys"][11]["action"])
        self.assertNotEqual("lock", profile["keys"][0]["action"])

    def test_set_key_without_device_uses_classic_above_eight(self):
        result = self.run_cli("set-key", "9", "launcher")
        self.assertEqual(0, result.returncode, result.stderr)
        profile = json.loads((self.config / "elgato-control" / "profile.json").read_text())
        self.assertEqual("launcher", profile["classicKeys"][8]["action"])

    def test_set_key_plus_rejects_index_above_eight(self):
        result = self.run_cli("set-key", "--device", "plus", "9", "lock")
        self.assertEqual(2, result.returncode)
        self.assertIn("1–8", result.stderr)

    def test_set_key_rejects_unknown_action(self):
        result = self.run_cli("set-key", "--device", "classic", "1", "not-a-real-action")
        self.assertEqual(2, result.returncode)
        self.assertIn("Unsupported action", result.stderr)

    def test_set_dial_and_set_pedal_persist(self):
        dial = self.run_cli("set-dial", "2", "press", "mic_mute")
        pedal = self.run_cli("set-pedal", "1", "screenshot")
        self.assertEqual(0, dial.returncode, dial.stderr)
        self.assertEqual(0, pedal.returncode, pedal.stderr)
        profile = json.loads((self.config / "elgato-control" / "profile.json").read_text())
        self.assertEqual("mic_mute", profile["dials"][1]["press"])
        self.assertEqual("screenshot", profile["pedals"][0]["action"])

    def test_profile_and_catalog_are_json(self):
        profile = self.run_cli("profile")
        catalog = self.run_cli("catalog")
        self.assertEqual(0, profile.returncode, profile.stderr)
        self.assertEqual(0, catalog.returncode, catalog.stderr)
        parsed_profile = json.loads(profile.stdout)
        parsed_catalog = json.loads(catalog.stdout)
        self.assertEqual(15, len(parsed_profile["classicKeys"]))
        self.assertTrue(any(item["value"] == "lock" for item in parsed_catalog))
        self.assertTrue(any(item["value"] == "key_home" for item in parsed_catalog))
        self.assertTrue(any(item["value"] == "niri_close" for item in parsed_catalog))
        self.assertTrue(any(item["value"] == "none" for item in parsed_catalog))


if __name__ == "__main__":
    unittest.main()
