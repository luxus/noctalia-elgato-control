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
        self.assertIn("libhidapi-libusb.so.0", candidates)
        self.assertIn("/run/current-system/sw/lib/libhidapi-libusb.so.0", candidates)

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
        self.assertEqual([0x02, 0x0C, 0, 0, 0, 0, 800 & 255, 800 >> 8, 100, 0, 0, 0, 0, 1008 & 255, 1008 >> 8, 0], hid.writes[0][:16])
        self.assertEqual(1, hid.writes[-1][10])
        self.assertEqual(1024, len(hid.writes[0]))

    def test_lcd_finds_magick_via_search_path_which(self):
        hid = self.fake_hid()
        daemon = self.daemon_with(hid)
        jpeg = b"\xff\xd8" + b"J" * 200

        def fake_run(command, **_kwargs):
            pathlib.Path(command[-1]).write_bytes(jpeg)
            return subprocess.CompletedProcess(command, 0)

        with mock.patch.object(module, "which", return_value="/run/current-system/sw/bin/magick") as finder, \
             mock.patch.object(module.subprocess, "run", side_effect=fake_run):
            daemon.update_lcd("dev", force=True)
        finder.assert_called_with("magick", "convert")
        self.assertEqual(0x02, hid.writes[0][0])
        self.assertEqual(0x0C, hid.writes[0][1])

    def test_resolve_icon_does_not_recursive_glob(self):
        with mock.patch.object(module.pathlib.Path, "glob", side_effect=AssertionError("no recursive glob")):
            self.assertEqual("", module.resolve_icon("missing-icon-name"))


class FramingHelperTests(unittest.TestCase):
    def test_brightness_is_clamped_and_original_uses_feature_17(self):
        values, length = module.brightness_feature(module.DEVICE_SPECS[module.ORIGINAL], 140)
        self.assertEqual([0x05, 0x55, 0xAA, 0xD1, 0x01, 100], values)
        self.assertEqual(17, length)
        values, length = module.brightness_feature(module.DEVICE_SPECS[0x0080], -3)
        self.assertEqual([0x03, 0x08, 0], values)
        self.assertEqual(32, length)

    def test_plus_lcd_header_is_sixteen_byte_0x0c_rectangle(self):
        header = module.plus_lcd_header(2, 194, True, 0, 0, 800, 100)
        self.assertEqual(16, len(header))
        self.assertEqual(0x02, header[0])
        self.assertEqual(0x0C, header[1])
        self.assertEqual([800 & 255, 800 >> 8], header[6:8])
        self.assertEqual(1, header[10])
        self.assertEqual(2, header[11])
        self.assertEqual(194, header[13])

    def test_jpeg_key_header_marks_final_page(self):
        header = module.jpeg_key_header(3, 2, 16, True)
        self.assertEqual([0x02, 0x07, 3, 1, 16, 0, 2, 0], header)

    def test_blank_bmp_is_valid_72_header(self):
        data = module.blank_bmp(72)
        self.assertTrue(data.startswith(b"BM"))
        self.assertGreater(len(data), 54)

    def test_send_key_image_writes_blank_jpeg_when_renderer_missing(self):
        hid = mock.Mock()
        hid.writes = []
        hid.write.side_effect = lambda handle, values: hid.writes.append(list(values)) or len(values)
        daemon = module.Daemon.__new__(module.Daemon)
        daemon.hid = hid
        spec = module.DEVICE_SPECS[0x0080]
        with mock.patch.object(module, "rendered_key_image", return_value=None):
            daemon.send_key_image("dev", spec, 1, {"action": "lock", "label": "Lock"})
        self.assertGreaterEqual(len(hid.writes), 1)
        self.assertEqual([0x02, 0x07, 1], hid.writes[0][:3])
        self.assertEqual(1024, len(hid.writes[0]))


class DualOpenAndDiscoveryTests(unittest.TestCase):
    def classic_info(self, path="/dev/hidraw0", interface=0):
        spec = module.DEVICE_SPECS[0x0080]
        return {
            "path": path, "productId": 0x0080, "serial": "CLASSIC",
            "product": spec["name"], "kind": "classic", "family": "classic",
            "capabilities": spec["capabilities"], "spec": spec, "interface": interface,
            "alternates": [],
        }

    def plus_info(self, path="/dev/hidraw1", interface=0):
        spec = module.DEVICE_SPECS[module.PLUS]
        return {
            "path": path, "productId": module.PLUS, "serial": "PLUS",
            "product": spec["name"], "kind": "plus", "family": "plus",
            "capabilities": spec["capabilities"], "spec": spec, "interface": interface,
            "alternates": [],
        }

    def pedal_info(self, path="/dev/hidraw2"):
        spec = module.DEVICE_SPECS[module.PEDAL]
        return {
            "path": path, "productId": module.PEDAL, "serial": "PEDAL",
            "product": spec["name"], "kind": "pedal", "family": "pedal",
            "capabilities": spec["capabilities"], "spec": spec, "interface": 0,
            "alternates": [],
        }

    def daemon(self, hid):
        daemon = module.Daemon.__new__(module.Daemon)
        daemon.hid = hid
        daemon.devices = {}
        daemon.previous = {}
        daemon.profile = module.normalize_profile({})
        daemon.brightness = 55
        daemon.light_states = []
        daemon.status = {"error": "", "lights": []}
        daemon.lcd_signature = None
        return daemon

    def fake_hid(self, found, opens=None):
        hid = mock.Mock()
        hid.paths.return_value = found
        opened = []

        def open_path(path):
            opened.append(path)
            if opens is None:
                return "handle:%s" % path
            return opens.get(path)

        hid.open.side_effect = open_path
        hid.close = mock.Mock()
        hid.last_error.return_value = "permission denied"
        hid.write.return_value = 1024
        hid.feature.return_value = 32
        hid._opened = opened
        return hid

    def test_group_hid_devices_keeps_classic_and_plus(self):
        grouped = module.group_hid_devices([
            self.classic_info("/dev/hidraw0", 3),
            self.classic_info("/dev/hidraw0b", 0),
            self.plus_info("/dev/hidraw1", 0),
        ])
        kinds = {row["kind"] for row in grouped}
        self.assertEqual({"classic", "plus"}, kinds)
        classic = next(row for row in grouped if row["kind"] == "classic")
        self.assertEqual("/dev/hidraw0b", classic["path"])
        self.assertIn("/dev/hidraw0", classic["alternates"])

    def test_connect_opens_classic_and_plus_together(self):
        found = [self.classic_info(), self.plus_info()]
        hid = self.fake_hid(found)
        daemon = self.daemon(hid)
        decorated = []
        daemon.decorate = decorated.append
        with mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertEqual(["/dev/hidraw0", "/dev/hidraw1"], hid._opened)
        self.assertEqual(2, len(daemon.devices))
        self.assertEqual("classic", daemon.status["classic"]["kind"])
        self.assertEqual("plus", daemon.status["plus"]["kind"])
        self.assertEqual(15, daemon.status["classic"]["keys"])
        self.assertEqual(8, daemon.status["plus"]["keys"])
        self.assertIn("dials", daemon.status["plus"]["capabilities"])
        self.assertEqual({"classic", "plus"}, {item["kind"] for item in daemon.status["devices"]})
        self.assertEqual({"classic", "plus"}, {item["kind"] for item in decorated})

    def test_connect_opens_pedal_without_artwork_and_keeps_decks(self):
        hid = self.fake_hid([self.classic_info(), self.plus_info(), self.pedal_info()])
        daemon = self.daemon(hid)
        with mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertEqual(3, len(daemon.devices))
        self.assertEqual("pedal", daemon.status["pedal"]["kind"])
        kinds = [item["kind"] for item in daemon.status["devices"]]
        self.assertEqual(["classic", "plus", "pedal"], kinds)

    def test_open_failure_is_recorded_and_does_not_drop_the_other_deck(self):
        found = [self.classic_info(), self.plus_info()]
        hid = self.fake_hid(found, opens={"/dev/hidraw0": "classic-handle", "/dev/hidraw1": None})
        daemon = self.daemon(hid)
        daemon.decorate = mock.Mock()
        with mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertIn("/dev/hidraw0", daemon.devices)
        self.assertNotIn("/dev/hidraw1", daemon.devices)
        self.assertIsNotNone(daemon.status["classic"])
        self.assertIsNone(daemon.status["plus"])
        self.assertEqual("", daemon.status["error"] or "")

    def test_open_failure_when_no_device_opens_sets_status_error(self):
        hid = self.fake_hid([self.classic_info()], opens={"/dev/hidraw0": None})
        daemon = self.daemon(hid)
        with mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertEqual({}, daemon.devices)
        self.assertIn("HID open failed", daemon.status["error"])
        self.assertIn("permission denied", daemon.status["error"])

    def test_open_retries_alternate_interface_path(self):
        info = self.classic_info("/dev/hidraw-bad", 3)
        info["alternates"] = ["/dev/hidraw-good"]
        hid = self.fake_hid([info], opens={"/dev/hidraw-bad": None, "/dev/hidraw-good": "ok"})
        daemon = self.daemon(hid)
        daemon.decorate = mock.Mock()
        with mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertIn("/dev/hidraw-good", daemon.devices)
        self.assertEqual("ok", daemon.devices["/dev/hidraw-good"]["handle"])

    def test_hid_open_returns_none_without_nonblocking(self):
        hid = module.Hid.__new__(module.Hid)
        hid.lib = mock.Mock()
        hid.lib.hid_open_path.return_value = None
        self.assertIsNone(hid.open("/dev/hidraw0"))
        hid.lib.hid_set_nonblocking.assert_not_called()

    def test_hid_open_empty_path_is_a_fail(self):
        hid = module.Hid.__new__(module.Hid)
        hid.lib = mock.Mock()
        self.assertIsNone(hid.open(""))
        hid.lib.hid_open_path.assert_not_called()

    def test_connect_without_hidapi_records_error(self):
        daemon = self.daemon(None)
        with mock.patch.object(module, "Hid", side_effect=RuntimeError("hidapi-hidraw is not installed")), \
             mock.patch.object(module, "detect_wave", return_value=None):
            daemon.connect()
        self.assertIn("hidapi-hidraw", daemon.status["error"])
        self.assertIsNone(daemon.status["classic"])
        self.assertIsNone(daemon.status["plus"])

    def test_decorate_plus_sends_brightness_keys_and_lcd(self):
        hid = mock.Mock()
        hid.writes = []
        hid.features = []
        hid.write.side_effect = lambda handle, values: hid.writes.append(list(values)) or len(values)
        hid.feature.side_effect = lambda handle, values, length=32: hid.features.append((list(values), length)) or length
        daemon = self.daemon(hid)
        spec = module.DEVICE_SPECS[module.PLUS]
        device = {"spec": spec, "handle": "plus", "kind": "plus"}
        with mock.patch.object(module, "rendered_key_image", return_value=None), \
             mock.patch.object(module.shutil, "which", return_value=None):
            daemon.decorate(device)
        self.assertEqual([0x03, 0x08, 55], hid.features[0][0])
        self.assertTrue(any(row[:2] == [0x02, 0x07] for row in hid.writes))
        self.assertEqual("LCD rendering requires ImageMagick", daemon.status["error"])

    def test_decorate_pedal_does_not_write_artwork(self):
        hid = mock.Mock()
        daemon = self.daemon(hid)
        daemon.decorate({"spec": module.DEVICE_SPECS[module.PEDAL], "handle": "pedal", "kind": "pedal"})
        hid.write.assert_not_called()
        hid.feature.assert_not_called()


class WaveXlrTests(unittest.TestCase):
    WPCTL_XLR = """
Audio
 ├─ Devices:
 │      42. Built-in Audio
 │      55. Elgato Wave XLR
 ├─ Sinks:
 │  *   56. Elgato Wave XLR Analog Stereo
 ├─ Sources:
 │      90. Monitor of Elgato Wave XLR Analog Stereo
 │  *   57. Elgato Wave XLR Analog Mono
 ├─ Filters:
"""

    WPCTL_WAVE3 = """
Audio
 ├─ Sinks:
 │      12. Elgato Wave:3 Analog Stereo
 ├─ Sources:
 │      13. Elgato Wave:3
"""

    def test_wave_xlr_is_detected_and_monitor_is_ignored(self):
        wave = module.parse_wpctl_wave(self.WPCTL_XLR)
        self.assertEqual("wave_xlr", wave["model"])
        self.assertEqual(57, wave["sourceId"])
        self.assertEqual(56, wave["sinkId"])
        self.assertIn("XLR", wave["product"])

    def test_wave3_is_still_detected(self):
        wave = module.parse_wpctl_wave(self.WPCTL_WAVE3)
        self.assertEqual("wave3", wave["model"])
        self.assertEqual(13, wave["sourceId"])
        self.assertEqual(12, wave["sinkId"])

    def test_no_wave_returns_none(self):
        self.assertIsNone(module.parse_wpctl_wave("Audio\n ├─ Sources:\n │      1. Built-in Analog Stereo\n"))

    def test_wave_xlr_gain_uses_pipewire_when_alsa_is_missing(self):
        wave = {"model": "wave_xlr", "sourceId": 57, "sinkId": 56, "card": None}
        with mock.patch.object(module, "wpctl_adjust") as adjust:
            module.perform_wave_action(wave, "wave_gain_up")
        adjust.assert_called_once_with(57, delta=5)

    def test_wave_xlr_mute_uses_pipewire_when_alsa_is_missing(self):
        wave = {"model": "wave_xlr", "sourceId": 57, "card": None}
        with mock.patch.object(module, "wpctl_adjust") as adjust:
            module.perform_wave_action(wave, "wave_mute")
        adjust.assert_called_once_with(57, mute=True)

    def test_wave_xlr_skips_mic_capture_even_when_card_is_set(self):
        wave = {"model": "wave_xlr", "sourceId": 57, "sinkId": 56, "card": 3, "gainRaw": 40}
        with mock.patch.object(module, "wpctl_adjust") as adjust, \
             mock.patch.object(module, "set_alsa_control") as setter:
            module.perform_wave_action(wave, "wave_mute")
            module.perform_wave_action(wave, "wave_gain_up")
        setter.assert_not_called()
        self.assertEqual([mock.call(57, mute=True), mock.call(57, delta=5)], adjust.call_args_list)

    def test_hidapi_sibling_swaps_hidraw_and_libusb(self):
        self.assertTrue(module.hidapi_sibling("/nix/store/x/lib/libhidapi-hidraw.so.0").endswith("libhidapi-libusb.so.0"))

    def test_hidapi_search_dirs_include_nix_profile(self):
        with mock.patch.dict(os.environ, {"USER": "luxus", "HOME": "/home/luxus"}, clear=False):
            with mock.patch.object(module.pathlib.Path, "home", return_value=pathlib.Path("/home/luxus")):
                dirs = [str(path) for path in module.hidapi_search_dirs()]
        self.assertIn("/run/current-system/sw/lib", dirs)
        self.assertIn("/home/luxus/.nix-profile/lib", dirs)
        self.assertIn("/etc/profiles/per-user/luxus/lib", dirs)


if __name__ == "__main__":
    unittest.main()
