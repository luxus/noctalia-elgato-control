import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "elgato-control"


class PanelEditorDaemonContractTests(unittest.TestCase):
    def test_panel_reads_status_from_disk_and_does_not_poll_cli(self):
        panel = (PLUGIN / "panel.luau").read_text()
        self.assertIn("noctalia.readFile", panel)
        self.assertIn("status.json", panel)
        self.assertIn("profile.json", panel)
        self.assertNotIn('"status", "--json"', panel)
        self.assertIn("set-key", (PLUGIN / "editor.luau").read_text())
        self.assertIn("tree = function", panel)
        self.assertNotIn('error("Elgato Control:', panel)
        self.assertNotIn("filterCatalog(catalog, filter, current, 80)", panel)
        self.assertIn("filterCatalog(catalog, filter, current, 0)", panel)

    def test_panel_maps_classic_plus_dials_and_wave(self):
        editor = (PLUGIN / "editor.luau").read_text()
        panel = (PLUGIN / "panel.luau").read_text()
        self.assertIn('--device", "classic"', editor)
        self.assertIn('--device", "plus"', editor)
        self.assertIn("set-dial", editor)
        self.assertIn("set-pedal", editor)
        self.assertIn("wave", editor)
        self.assertIn("lights", editor)
        self.assertIn("plus-dials", panel)
        self.assertIn("LCD STRIP", panel)
        self.assertIn("WAVE", panel.upper())
        self.assertIn("connectionLabel", panel)

    def test_service_matches_daemon_not_cli_status(self):
        service = (PLUGIN / "service.luau").read_text()
        self.assertIn("processMatches(function(matched)", service)
        self.assertIn('"elgato-control daemon"', service)
        self.assertNotIn(
            'processMatches(function(matched)\n    if not matched then\n      startDaemon()\n    end\n  end, "elgato-control")',
            service,
        )
        self.assertIn("status.classic and status.plus", service)


if __name__ == "__main__":
    unittest.main()
