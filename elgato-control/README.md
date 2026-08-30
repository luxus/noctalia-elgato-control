# Elgato Control for Noctalia v5

Unofficial native Linux controls for Elgato Stream Deck hardware, ported from
[omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
to the Noctalia v5 Luau plugin API.

This is not affiliated with Elgato.

Supported host: **lea**, a NixOS workstation on `x86_64-linux`. There is no
Darwin, macOS, aarch64, emily, zoe, or vanessa support.

## What changed from the Omarchy plugin

- QML bar / panel / service rewritten as `widget.luau`, `panel.luau`, `service.luau`
- Manifest is `plugin.toml` (`luxus/elgato-control`, `plugin_api = 24`)
- HID daemon still Python + hidapi, now with the 15-key Stream Deck family
- Actions target Noctalia IPC (`noctalia msg …`) with niri / Hyprland / generic fallbacks

## Supported hardware

| Device | PID | Notes |
| --- | --- | --- |
| Stream Deck (2017) | `0x0060` | 15 keys, BMP, mirrored columns |
| Stream Deck (2019) | `0x006D` | 15 keys, JPEG 72×72 rotated 180° |
| Stream Deck Mk.2 | `0x0080` | 15 keys, JPEG 72×72 rotated 180° |
| Stream Deck Mk.2 Scissor | `0x00A5` | same protocol as Mk.2 |
| Stream Deck 15-key module | `0x00B9` | same protocol as Mk.2 |
| Stream Deck + | `0x0084` | 8 keys, 4 dials, 800×100 LCD |
| Stream Deck Pedal | `0x0086` | 3 pedals |
| Key Light / Key Light Neo | mDNS `_elg._tcp` | grouped power, brightness, temperature |
| Wave:3 | PipeWire / ALSA | gain, mute, headphones, presets |

Original 15-key and Stream Deck + can be connected at the same time. Each has
its own key map (`classicKeys` vs `keys`).

## Install

```bash
noctalia msg plugins source add elgato git https://github.com/luxus/noctalia-elgato-control
noctalia msg plugins enable luxus/elgato-control
```

Local checkout:

```bash
noctalia msg plugins source add elgato-dev path ~/src/noctalia-elgato-control
```

### udev / NixOS

The plugin talks to Stream Deck hidraw nodes. On NixOS, import this flake's
module (udev rules only):

```nix
{
  inputs.elgato-control.url = "github:luxus/noctalia-elgato-control";

  outputs = { nixpkgs, elgato-control, ... }: {
    nixosConfigurations.lea = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        elgato-control.nixosModules.default
      ];
    };
  };
}
```

Or copy `udev/99-elgato-streamdeck.rules` into `/etc/udev/rules.d/` (or set
`services.udev.extraRules` to the same text), then reload and replug:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

`TAG+="uaccess"` covers a seated session. `GROUP="input"` is also set; being in
the `input` group is a useful fallback.

### hidapi on NixOS

Python ctypes does not search the Nix store unless the library is on the loader
path. This plugin does **not** require nix-ld.

`service.luau` exports the plugin setting **hidapi library path** as
`ELGATO_HIDAPI` when the daemon starts. You can also set `ELGATO_HIDAPI` (or
`HIDAPI_PATH`) yourself to the absolute `libhidapi-hidraw.so.0` path.

Typical NixOS locations, in the order the CLI tries them after those overrides:

- `libhidapi-hidraw.so.0` (via `LD_LIBRARY_PATH` if you set one)
- `/run/current-system/sw/lib/libhidapi-hidraw.so.0` (if `hidapi` is in `environment.systemPackages`)
- `/usr/lib/x86_64-linux-gnu/libhidapi-hidraw.so.0` (Debian/Ubuntu)

The flake package wraps the CLI with nixpkgs `hidapi`:

```bash
nix run . -- status --json
```

Find a store path without installing system-wide:

```bash
nix build nixpkgs#hidapi --print-out-paths
# then: <result>/lib/libhidapi-hidraw.so.0
```

### Dependencies

- Python 3 (stdlib + ctypes only)
- `libhidapi-hidraw`
- ImageMagick (`magick` or `convert`)
- Optional: `avahi-browse`, `wpctl`, `amixer`, `wtype`, `playerctl`, `grim`

## Profile

`~/.config/elgato-control/profile.json`

Existing Omarchy / Elgato Control profiles are migrated. Missing
`classicKeys` are filled from the eight Plus keys plus workspace / volume /
launcher defaults.

Commands below are from the **repository root**. The `status --json` object is
the plugin contract (pretty-printed JSON without `--json` is the same object).

```bash
elgato-control/bin/elgato-control init
elgato-control/bin/elgato-control status --json
elgato-control/bin/elgato-control set-key --device classic 12 lock
elgato-control/bin/elgato-control set-key --device plus 1 terminal
```

## Tests

No Stream Deck, Key Light, Wave:3, or Noctalia shell is required. Tests stub HID
and exercise protocol encode/decode, hidapi path resolution, profile migrate,
CLI argv, and the `status --json` schema.

```bash
# from the repository root
python3 elgato-control/tests/test_streamdeck.py
python3 -m unittest discover -s elgato-control/tests -v
nix flake check   # x86_64-linux only: same tests, luau-compile, wrapped CLI
```

GitHub Actions runs those Python tests on `ubuntu-latest` (x86_64). Luau is
syntax-checked when `luau-compile` is on PATH, including `nix flake check` via
nixpkgs. If Luau is missing, CI still fails on broken TOML/JSON fixtures. There
are no Darwin jobs.

## Credits

- HID daemon, Key Light safety, Wave controls, and visual editor model:
  Amit Patel, MIT, [omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
- Original 2017 BMP/page protocol: [python-elgato-streamdeck](https://github.com/abcminiuser/python-elgato-streamdeck)
- Elgato mark from the MIT-licensed `@elgato/icons` package
