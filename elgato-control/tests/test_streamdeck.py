import importlib.machinery
import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).parents[1] / "bin" / "elgato-control"
loader = importlib.machinery.SourceFileLoader("elgato_control", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class DeviceModelTests(unittest.TestCase):
    def test_plus_capabilities_are_optional_and_explicit(self):
        caps = module.DEVICE_SPECS[module.PLUS]["capabilities"]
        self.assertIn("lcd", caps)
        self.assertIn("dials", caps)
        self.assertNotIn("pedals", caps)

    def test_classic_family_covers_mk2_and_2019(self):
        for pid in (0x006D, 0x0080, 0x00A5, 0x00B9):
            spec = module.DEVICE_SPECS[pid]
            self.assertEqual("classic", spec["kind"])
            self.assertEqual(15, spec["keys"])
            self.assertEqual("jpeg", spec["image"])
            self.assertEqual(180, spec["rotate"])
            self.assertFalse(spec["origin_flip"])

    def test_original_2017_uses_bmp_and_mirrored_columns(self):
        spec = module.DEVICE_SPECS[module.ORIGINAL]
        self.assertEqual("bmp", spec["image"])
        self.assertTrue(spec["origin_flip"])
        self.assertEqual(8191, spec["report"])
        self.assertEqual(4, module.origin_index(0))
        self.assertEqual(0, module.origin_index(4))
        self.assertEqual(9, module.origin_index(5))

    def test_pedal_capabilities_do_not_assume_lcd(self):
        self.assertEqual(["pedals"], module.DEVICE_SPECS[module.PEDAL]["capabilities"])

    def test_lcd_svg_has_required_dimensions_and_labels(self):
        profile = {"dials": [{"label": "Volume"}, {"label": "Microphone"}]}
        svg = module.lcd_svg(profile, 55, [])
        self.assertIn('width="800" height="100"', svg)
        self.assertIn("Volume", svg)
        self.assertIn("Microphone", svg)

    def test_wave_actions_target_detected_source(self):
        command = module.command_for("mic_mute", {"sourceId": 89})
        self.assertEqual(["wpctl", "set-mute", "89", "toggle"], command)

    def test_mic_actions_fall_back_to_default_source(self):
        command = module.command_for("mic_up")
        self.assertIn("@DEFAULT_AUDIO_SOURCE@", command)

    def test_media_prefers_noctalia_ipc(self):
        with mock.patch.object(module, "which", side_effect=lambda *names: "noctalia" if "noctalia" in names else None):
            self.assertEqual(["noctalia", "msg", "media", "toggle"], module.command_for("media_play_pause"))
            self.assertEqual(["noctalia", "msg", "screenshot-region"], module.command_for("screenshot"))
            self.assertEqual(["noctalia", "msg", "panel-toggle", "launcher"], module.command_for("launcher"))

    def test_home_key_action_uses_wtype_without_a_shell(self):
        with mock.patch.object(module, "which", return_value="wtype"):
            self.assertEqual(["wtype", "-k", "Home"], module.command_for("key_home"))

    def test_voxtype_push_to_talk_has_press_and_release_commands(self):
        with mock.patch.object(module, "which", return_value="voxtype"):
            self.assertEqual(["voxtype", "record", "start"], module.command_for("voxtype_push_to_talk"))
            self.assertEqual(["voxtype", "record", "stop"], module.release_command_for("voxtype_push_to_talk"))

    def test_set_classic_key_persists_selected_action(self):
        with tempfile.TemporaryDirectory() as directory:
            config = pathlib.Path(directory)
            profile_path = config / "profile.json"
            profile_path.write_text('{"keys":[{"label":"Old","action":"terminal"}],"classicKeys":[{"label":"Old","action":"terminal"}]}')
            with mock.patch.object(module, "CONFIG", config), mock.patch.object(module, "PROFILE", profile_path), \
                 mock.patch.object(module, "STATE", config / "state"):
                module.set_control_action("classic", 0, "action", "lock")
                saved = module.json.loads(profile_path.read_text())
            self.assertEqual("lock", saved["classicKeys"][0]["action"])

    def test_normalize_profile_fills_fifteen_classic_keys(self):
        profile = module.normalize_profile({"keys": [{"action": "terminal"}]})
        self.assertEqual(8, len(profile["keys"]))
        self.assertEqual(15, len(profile["classicKeys"]))
        self.assertEqual("launcher", profile["classicKeys"][14]["action"])

    def test_legacy_profile_is_migrated_to_elgato_control_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            config = root / "elgato-control"
            state = root / "state"
            legacy = root / "omarchy-streamdeck"
            legacy.mkdir()
            (legacy / "profile.json").write_text('{"name":"Migrated","keys":[]}')
            with mock.patch.object(module, "CONFIG", config), mock.patch.object(module, "STATE", state), \
                 mock.patch.object(module, "PROFILE", config / "profile.json"), \
                 mock.patch.object(module, "LEGACY_CONFIG", legacy):
                module.ensure_profile()
                self.assertEqual("Migrated", module.load_profile()["name"])
                self.assertEqual(15, len(module.load_profile()["classicKeys"]))

    def test_avahi_discovery_keeps_resolved_ipv4_only(self):
        output = "\n".join([
            "=;eth0;IPv4;Key\\032Light\\032Left;_elg._tcp;local;left.local;192.0.2.2;9123;",
            "=;eth0;IPv6;Key Light Left;_elg._tcp;local;left.local;fe80::1;9123;",
            "+;eth0;IPv4;Unresolved;_elg._tcp;local",
        ])
        self.assertEqual([{"name": "Key Light Left", "host": "192.0.2.2", "port": 9123}],
                         module.parse_avahi_lights(output))

    def test_key_light_hosts_are_local_only(self):
        self.assertEqual("key-light.local", module.validate_light_host("key-light.local."))
        self.assertEqual("192.168.1.20", module.validate_light_host("192.168.1.20"))
        with self.assertRaises(ValueError):
            module.validate_light_host("example.com")
        with self.assertRaises(ValueError):
            module.validate_light_host("8.8.8.8")

    def test_wave_gain_action_changes_hardware_control_without_shell(self):
        wave = {"card": 2, "gainRaw": 40, "sourceId": 89}
        with mock.patch.object(module, "set_alsa_control") as setter:
            module.perform_wave_action(wave, "wave_gain_up")
        setter.assert_called_once_with(2, "Mic Capture Volume", 42)


class ParserTests(unittest.TestCase):
    def make_daemon(self):
        daemon = module.Daemon.__new__(module.Daemon)
        daemon.previous = {}
        daemon.profile = {
            "keys": [{"action": "plus-%d" % i} for i in range(8)],
            "classicKeys": [{"action": "classic-%d" % i} for i in range(15)],
            "dials": [{"left": "left-%d" % i, "right": "right-%d" % i, "press": "press-%d" % i} for i in range(4)],
            "pedals": [{"action": "left"}, {"action": "middle"}, {"action": "right"}],
        }
        daemon.actions = []
        daemon.releases = []
        daemon.act = daemon.actions.append
        daemon.release = daemon.releases.append
        return daemon

    def test_classic_v2_key_report_is_edge_triggered(self):
        daemon = self.make_daemon()
        spec = module.DEVICE_SPECS[0x0080]
        payload = bytes([1, 0, 15, 0] + [0] * 15)
        pressed = bytes([1, 0, 15, 0, 0, 1] + [0] * 13)
        daemon.parse_classic(pressed, spec)
        daemon.parse_classic(pressed, spec)
        daemon.parse_classic(payload, spec)
        self.assertEqual(["classic-1"], daemon.actions)

    def test_original_key_report_mirrors_columns(self):
        daemon = self.make_daemon()
        spec = module.DEVICE_SPECS[module.ORIGINAL]
        # Hardware byte 1 (index 0 after report id) is the rightmost key of row 1 = visual key 4
        report = bytes([1, 1] + [0] * 14)
        daemon.parse_classic(report, spec)
        self.assertEqual(["classic-4"], daemon.actions)

    def test_plus_key_report_uses_first_eight_keys(self):
        daemon = self.make_daemon()
        report = bytes([1, 0, 8, 0, 1] + [0] * 7)
        daemon.parse_plus(report)
        self.assertEqual(["plus-0"], daemon.actions)

    def test_plus_touch_tap_maps_to_nearest_dial_press(self):
        daemon = self.make_daemon()
        # TAP at x=450 -> dial 2
        report = bytes([1, 2, 10, 0, 1, 0, 450 & 255, 450 >> 8, 0, 0])
        daemon.parse_plus(report)
        self.assertEqual(["press-2"], daemon.actions)

    def test_three_byte_pedal_report_press_is_edge_triggered(self):
        daemon = self.make_daemon()
        daemon.parse_pedal(bytes([1, 0, 3, 1, 0, 0]))
        daemon.parse_pedal(bytes([1, 0, 3, 1, 0, 0]))
        daemon.parse_pedal(bytes([1, 0, 3, 0, 0, 0]))
        self.assertEqual(["left"], daemon.actions)
        self.assertEqual(["left"], daemon.releases)

    def test_legacy_padded_pedal_report_is_supported(self):
        daemon = self.make_daemon()
        daemon.parse_pedal(bytes([1, 0, 3, 0, 0, 1, 0]))
        self.assertEqual(["middle"], daemon.actions)


if __name__ == "__main__":
    unittest.main()
