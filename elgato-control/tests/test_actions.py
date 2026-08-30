import json
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from test_streamdeck import module
from test_cli import run_cli


class ActionCatalogTests(unittest.TestCase):
    def test_catalog_includes_lock_launcher_niri_and_none(self):
        catalog = module.action_catalog()
        values = {item["value"] for item in catalog}
        self.assertIn("lock", values)
        self.assertIn("launcher", values)
        self.assertIn("niri_close", values)
        self.assertIn("none", values)
        self.assertIn("workspace_next", values)

    def test_lock_uses_noctalia_session_lock(self):
        with mock.patch.object(module, "which", side_effect=lambda *names: "noctalia" if "noctalia" in names else None):
            self.assertEqual(["noctalia", "msg", "session", "lock"], module.command_for("lock"))
            self.assertEqual(["noctalia", "msg", "panel-toggle", "launcher"], module.command_for("launcher"))
            self.assertEqual(["noctalia", "msg", "media", "toggle"], module.command_for("media_play_pause"))

    def test_lock_falls_back_to_loginctl(self):
        with mock.patch.object(module, "which", side_effect=lambda *names: "loginctl" if "loginctl" in names else None):
            self.assertEqual(["loginctl", "lock-session"], module.command_for("lock"))

    def test_niri_workspace_and_close_use_niri_msg(self):
        def fake_which(*names):
            if "niri" in names:
                return "/run/current-system/sw/bin/niri"
            return None

        with mock.patch.object(module, "which", side_effect=fake_which):
            with mock.patch.dict(os.environ, {"NIRI_SOCKET": "/run/user/1000/niri.sock"}, clear=False):
                self.assertEqual(
                    ["/run/current-system/sw/bin/niri", "msg", "action", "focus-workspace-down"],
                    module.command_for("workspace_next"),
                )
                self.assertEqual(
                    ["/run/current-system/sw/bin/niri", "msg", "action", "close-window"],
                    module.command_for("niri_close"),
                )

    def test_none_is_a_silent_no_op(self):
        self.assertIsNone(module.command_for("none"))
        daemon = mock.Mock()
        daemon.status = {"error": "", "wave": None}
        with mock.patch.object(module.subprocess, "Popen") as popen:
            module.Daemon.act(daemon, "none")
            popen.assert_not_called()


class NixOsDesktopPathTests(unittest.TestCase):
    def test_application_dirs_include_nixos_and_xdg_data_dirs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nix = root / "nix-share"
            extra = root / "extra-share"
            home_data = root / "xdg-data-home"
            env = {
                "XDG_DATA_HOME": str(home_data),
                "XDG_DATA_DIRS": str(extra) + ":" + str(nix),
                "HOME": str(root / "home"),
                "USER": "luxus",
            }
            with mock.patch.dict(os.environ, env, clear=False):
                with mock.patch.object(module.pathlib.Path, "home", return_value=root / "home"):
                    dirs = module.application_dirs()
            text = [str(path) for path in dirs]
            self.assertIn(str(home_data / "applications"), text)
            self.assertIn(str(extra / "applications"), text)
            self.assertIn(str(nix / "applications"), text)
            self.assertIn("/run/current-system/sw/share/applications", text)
            self.assertIn(str(root / "home" / ".nix-profile" / "share" / "applications"), text)
            self.assertIn("/etc/profiles/per-user/luxus/share/applications", text)

    def test_desktop_applications_read_xdg_data_dirs(self):
        with tempfile.TemporaryDirectory() as directory:
            apps = pathlib.Path(directory) / "applications"
            apps.mkdir()
            (apps / "lea-term.desktop").write_text("[Desktop Entry]\nType=Application\nName=Lea Terminal\n")
            (apps / "hidden.desktop").write_text("[Desktop Entry]\nType=Application\nName=Hidden\nNoDisplay=true\n")
            env = {
                "XDG_DATA_HOME": str(directory),
                "XDG_DATA_DIRS": str(directory),
                "HOME": str(pathlib.Path(directory) / "home"),
            }
            with mock.patch.dict(os.environ, env, clear=False):
                with mock.patch.object(module.pathlib.Path, "home", return_value=pathlib.Path(directory) / "home"):
                    found = dict(module.desktop_applications())
                    self.assertEqual("Lea Terminal", found["lea-term"])
                    self.assertNotIn("hidden", found)
                    self.assertTrue(module.desktop_file_exists("lea-term"))
                    self.assertEqual("lea-term", module.desktop_entry("lea-term")["desktopId"])

    def test_search_path_includes_nixos_bin_dirs(self):
        with mock.patch.dict(os.environ, {"PATH": "/opt/bin", "USER": "luxus", "HOME": "/home/luxus"}, clear=False):
            with mock.patch.object(module.pathlib.Path, "home", return_value=pathlib.Path("/home/luxus")):
                path = module.search_path()
        self.assertIn("/opt/bin", path)
        self.assertIn("/run/current-system/sw/bin", path)
        self.assertIn("/home/luxus/.nix-profile/bin", path)
        self.assertIn("/etc/profiles/per-user/luxus/bin", path)


class EditorCliRoundTripTests(unittest.TestCase):
    def test_select_key_set_action_writes_profile_and_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config, state = root / "config", root / "state"
            config.mkdir()
            state.mkdir()
            init = run_cli(["init"], config, state)
            self.assertEqual(0, init.returncode, init.stderr)
            mapped = run_cli(["set-key", "--device", "classic", "1", "lock"], config, state)
            self.assertEqual(0, mapped.returncode, mapped.stderr)
            profile = json.loads((config / "elgato-control" / "profile.json").read_text())
            self.assertEqual("lock", profile["classicKeys"][0]["action"])
            listed = run_cli(["profile"], config, state)
            self.assertEqual("lock", json.loads(listed.stdout)["classicKeys"][0]["action"])
            status = json.loads(run_cli(["status", "--json"], config, state).stdout)
            self.assertFalse(status["running"])
            self.assertEqual("Noctalia Default", status["profile"])
            catalog = json.loads(run_cli(["catalog"], config, state).stdout)
            self.assertTrue(any(item["value"] == "lock" for item in catalog))
            self.assertTrue(any(item["value"] == "niri_close" for item in catalog))


if __name__ == "__main__":
    unittest.main()
