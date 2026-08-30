import json
import pathlib
import shutil
import subprocess
import tomllib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "elgato-control"
LUAU_FILES = {
    "widget.luau": ("update", "onClick"),
    "panel.luau": ("render", "onOpen", "update"),
    "service.luau": ("onEnable", "update"),
    "shortcut.luau": ("onClick",),
}


class FixtureTests(unittest.TestCase):
    def test_plugin_toml_matches_catalog(self):
        plugin = tomllib.loads((PLUGIN / "plugin.toml").read_text())
        catalog = tomllib.loads((ROOT / "catalog.toml").read_text())
        self.assertEqual("luxus/elgato-control", plugin["id"])
        self.assertEqual(24, plugin["plugin_api"])
        self.assertEqual("hidapi_path", plugin["setting"][1]["key"])
        self.assertEqual("", plugin["setting"][1]["default"])
        entry = catalog["plugin"][0]
        for key in ("id", "name", "version", "plugin_api", "author"):
            self.assertEqual(plugin[key], entry[key], key)
        self.assertEqual("widget.luau", plugin["widget"][0]["entry"])
        self.assertEqual("panel.luau", plugin["panel"][0]["entry"])
        self.assertEqual("service.luau", plugin["service"][0]["entry"])
        self.assertEqual("shortcut.luau", plugin["shortcut"][0]["entry"])

    def test_translations_cover_plugin_settings(self):
        translations = json.loads((PLUGIN / "translations" / "en.json").read_text())
        plugin = tomllib.loads((PLUGIN / "plugin.toml").read_text())
        settings = translations["settings"]
        self.assertIn("hidapi_path", settings)
        self.assertIn("brightness", settings)
        self.assertIn("show_label", settings)
        for block in plugin["setting"]:
            self.assertIn(block["key"], settings)
            self.assertEqual(f"settings.{block['key']}.label", block["label_key"])

    def test_default_profile_shape(self):
        profile = json.loads((PLUGIN / "defaults" / "profile.json").read_text())
        self.assertEqual(8, len(profile["keys"]))
        self.assertEqual(15, len(profile["classicKeys"]))
        self.assertEqual(4, len(profile["dials"]))
        self.assertEqual(3, len(profile["pedals"]))
        self.assertEqual("launcher", profile["classicKeys"][14]["action"])

    def test_udev_rules_cover_elgato_vid(self):
        rules = (PLUGIN / "udev" / "99-elgato-streamdeck.rules").read_text()
        self.assertIn('ATTRS{idVendor}=="0fd9"', rules)
        self.assertIn('KERNEL=="hidraw*"', rules)
        self.assertIn("uaccess", rules)

    def test_readme_paths_match_the_tree(self):
        for path in (ROOT / "README.md", PLUGIN / "README.md"):
            text = path.read_text()
            self.assertNotIn("plugin/elgato-control", text, path)
            self.assertIn("elgato-control", text)
        plugin_readme = (PLUGIN / "README.md").read_text()
        self.assertIn("elgato-control/bin/elgato-control", plugin_readme)
        self.assertIn("elgato-control/tests/test_streamdeck.py", plugin_readme)
        self.assertIn("x86_64-linux", plugin_readme)
        self.assertIn("ELGATO_HIDAPI", plugin_readme)
        self.assertIn("nix flake check", plugin_readme)

    def test_luau_entrypoints_exist_and_are_not_qml(self):
        service = (PLUGIN / "service.luau").read_text()
        self.assertIn("ELGATO_HIDAPI", service)
        self.assertIn("hidapi_path", service)
        for name, functions in LUAU_FILES.items():
            text = (PLUGIN / name).read_text()
            self.assertTrue(text.startswith("--!nonstrict"), name)
            self.assertNotIn("QtQuick", text)
            self.assertNotIn("import Qt", text)
            for function in functions:
                self.assertIn("function %s(" % function, text, "%s %s" % (name, function))

    def test_luau_syntax_when_compiler_is_available(self):
        compiler = shutil.which("luau-compile")
        if not compiler:
            self.skipTest(
                "luau-compile is not on PATH. Ubuntu CI still fails on broken "
                "TOML/JSON fixtures; nix flake check runs luau-compile from nixpkgs. "
                "There is no Noctalia runtime in CI."
            )
        for name in LUAU_FILES:
            result = subprocess.run(
                [compiler, "--binary", str(PLUGIN / name)],
                capture_output=True,
                timeout=15,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))


if __name__ == "__main__":
    unittest.main()
