import importlib.machinery
import importlib.util
import os
import pathlib
import subprocess
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
        self.assertEqual("set-mute", command[1])
        self.assertEqual("89", command[2])
        self.assertEqual("toggle", command[3])
        self.assertTrue(str(command[0]).endswith("wpctl"))

    def test_mic_actions_fall_back_to_default_source(self):
        command = module.command_for("mic_up")
        self.assertIn("@DEFAULT_AUDIO_SOURCE@", command)

    def test_media_prefers_noctalia_ipc(self):
        with mock.patch.object(module, "which", side_effect=lambda *names: "noctalia" if "noctalia" in names else None):
            self.assertEqual(["noctalia", "msg", "media", "toggle"], module.command_for("media_play_pause"))
            self.assertEqual(["noctalia", "msg", "screenshot-region"], module.command_for("screenshot"))
            self.assertEqual(["noctalia", "msg", "panel-toggle", "launcher"], module.command_for("launcher"))
            self.assertEqual(["noctalia", "msg", "session", "lock"], module.command_for("lock"))

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

    def test_parse_key_report_classic_v2_uses_offset_four(self):
        spec = module.DEVICE_SPECS[0x0080]
        payload = bytes([1, 0, 15, 0] + [0, 1] + [0] * 13)
        states = module.parse_key_report(payload, spec)
        self.assertEqual(15, len(states))
        self.assertEqual(1, states[1])
        self.assertEqual(0, states[0])

    def test_parse_key_report_rejects_non_key_plus_reports(self):
        spec = module.DEVICE_SPECS[module.PLUS]
        self.assertIsNone(module.parse_key_report(bytes([1, 2, 10, 0, 1]), spec))

    def test_plus_dial_press_is_edge_triggered(self):
        daemon = self.make_daemon()
        pressed = bytes([1, 3, 0, 0, 0, 0, 1, 0, 0])
        daemon.parse_plus(pressed)
        daemon.parse_plus(pressed)
        self.assertEqual(["press-1"], daemon.actions)

    def test_plus_dial_rotation_maps_signed_ticks(self):
        daemon = self.make_daemon()
        report = bytes([1, 3, 0, 0, 1, 1, 255, 0, 0])
        daemon.parse_plus(report)
        self.assertEqual(["right-0", "left-1"], daemon.actions)


class HidapiTests(unittest.TestCase):
    def test_elgato_hidapi_is_the_first_candidate(self):
        path = "/nix/store/fake-hidapi/lib/libhidapi-hidraw.so.0"
        with mock.patch.dict(os.environ, {"ELGATO_HIDAPI": path, "HIDAPI_PATH": "/unused.so"}, clear=False):
            candidates = module.hidapi_candidates()
        self.assertEqual(path, candidates[0])
        self.assertNotIn("/unused.so", candidates[:1])

    def test_hidapi_path_is_used_when_elgato_hidapi_is_unset(self):
        path = "/opt/libhidapi-hidraw.so.0"
        env = {key: value for key, value in os.environ.items() if key not in ("ELGATO_HIDAPI", "HIDAPI_PATH")}
        env["HIDAPI_PATH"] = path
        with mock.patch.dict(os.environ, env, clear=True):
            candidates = module.hidapi_candidates()
        self.assertEqual(path, candidates[0])

    def test_empty_elgato_hidapi_is_skipped_and_nixos_path_remains(self):
        env = {key: value for key, value in os.environ.items() if key not in ("ELGATO_HIDAPI", "HIDAPI_PATH")}
        env["ELGATO_HIDAPI"] = ""
        env["HIDAPI_PATH"] = ""
        with mock.patch.dict(os.environ, env, clear=True):
            candidates = module.hidapi_candidates()
        self.assertNotIn("", candidates)
        self.assertIn("libhidapi-hidraw.so.0", candidates)
        self.assertIn("/run/current-system/sw/lib/libhidapi-hidraw.so.0", candidates)
        self.assertIn("/usr/lib/x86_64-linux-gnu/libhidapi-hidraw.so.0", candidates)

    def test_hid_loads_elgato_hidapi_before_other_names(self):
        chosen = "/nix/store/aaaa/lib/libhidapi-hidraw.so.0"
        loaded = []

        def fake_cdll(name):
            loaded.append(name)
            if name != chosen:
                raise OSError("not this one")
            return mock.Mock()

        with mock.patch.dict(os.environ, {"ELGATO_HIDAPI": chosen}, clear=False):
            with mock.patch.object(module.ctypes, "CDLL", side_effect=fake_cdll):
                hid = module.Hid()
        self.assertEqual(chosen, loaded[0])
        self.assertIsNotNone(hid.lib)
        hid.lib.hid_init.assert_called_once()

    def test_hid_falls_through_when_elgato_hidapi_cannot_load(self):
        def fake_cdll(name):
            if name == "/missing/libhidapi-hidraw.so.0":
                raise OSError("missing")
            if name == "libhidapi-hidraw.so.0":
                return mock.Mock()
            raise OSError("skip")

        with mock.patch.dict(os.environ, {"ELGATO_HIDAPI": "/missing/libhidapi-hidraw.so.0"}, clear=False):
            with mock.patch.object(module.ctypes, "CDLL", side_effect=fake_cdll):
                hid = module.Hid()
        self.assertTrue(hid.lib.hid_init.called)

    def test_hid_errors_when_no_candidate_loads(self):
        with mock.patch.object(module.ctypes, "CDLL", side_effect=OSError("not found")):
            with self.assertRaisesRegex(RuntimeError, "hidapi-hidraw"):
                module.Hid()


class ProtocolEncodeTests(unittest.TestCase):
    def fake_hid(self):
        hid = mock.Mock()
        hid.writes = []
        hid.features = []
        hid.write.side_effect = lambda handle, values: hid.writes.append(list(values)) or len(values)
        hid.feature.side_effect = lambda handle, values, length=32: hid.features.append((list(values), length)) or length
        return hid

    def daemon_with(self, hid):
        daemon = module.Daemon.__new__(module.Daemon)
        daemon.hid = hid
        daemon.profile = {"dials": [{"label": "Volume"}], "brightness": 55}
        daemon.light_states = []
        daemon.lcd_signature = None
        daemon.status = {"error": ""}
        daemon.brightness = 55
        return daemon

    def test_original_brightness_feature_report(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        spec = module.DEVICE_SPECS[module.ORIGINAL]
        daemon.set_brightness("dev", spec, 40)
        values, length = hid.features[0]
        self.assertEqual([0x05, 0x55, 0xAA, 0xD1, 0x01, 40], values)
        self.assertEqual(17, length)

    def test_classic_jpeg_brightness_feature_report(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        spec = module.DEVICE_SPECS[0x0080]
        daemon.set_brightness("dev", spec, 55)
        values, length = hid.features[0]
        self.assertEqual([0x03, 0x08, 55], values)
        self.assertEqual(32, length)

    def test_jpeg_key_image_pages_use_v2_header(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        spec = module.DEVICE_SPECS[0x0080]
        payload = bytes(range(256)) * 8
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as handle:
            handle.write(payload)
            path = pathlib.Path(handle.name)
        try:
            with mock.patch.object(module, "rendered_key_image", return_value=path):
                daemon.send_key_image("dev", spec, 3, {"action": "lock", "label": "Lock"})
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(3, len(hid.writes))
        self.assertEqual([0x02, 0x07, 3, 0, 1016 & 255, 1016 >> 8, 0, 0], hid.writes[0][:8])
        self.assertEqual(1024, len(hid.writes[0]))
        self.assertEqual([0x02, 0x07, 3, 1, 16, 0, 2, 0], hid.writes[-1][:8])
        self.assertEqual(list(payload[:1016]), hid.writes[0][8:8 + 1016])

    def test_original_bmp_pages_mirror_columns_in_header(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        spec = module.DEVICE_SPECS[module.ORIGINAL]
        payload = b"BMPIMG"
        with tempfile.NamedTemporaryFile(suffix=".bmp", delete=False) as handle:
            handle.write(payload)
            path = pathlib.Path(handle.name)
        try:
            with mock.patch.object(module, "rendered_key_image", return_value=path):
                daemon.send_key_image("dev", spec, 0, {"action": "lock", "label": "Lock"})
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(2, len(hid.writes))
        self.assertEqual(8191, len(hid.writes[0]))
        self.assertEqual([0x02, 0x01, 1, 0, 0, 5], hid.writes[0][:6])
        self.assertEqual([0x02, 0x01, 2, 0, 1, 5], hid.writes[1][:6])

    def test_lcd_pages_use_plus_lcd_header(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        jpeg = b"\xff\xd8" + b"J" * 1200

        def fake_run(command, **_kwargs):
            pathlib.Path(command[-1]).write_bytes(jpeg)
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(module.shutil, "which", return_value="magick"), \
             mock.patch.object(module.subprocess, "run", side_effect=fake_run):
            daemon.update_lcd("dev", force=True)
        self.assertGreaterEqual(len(hid.writes), 2)
        self.assertEqual([0x02, 0x0B, 0, 0, 1016 & 255, 1016 >> 8, 0, 0], hid.writes[0][:8])
        self.assertEqual(1, hid.writes[-1][3])
        self.assertEqual(1024, len(hid.writes[0]))


if __name__ == "__main__":
    unittest.main()
