# Elgato Control for Noctalia v5

Unofficial native Linux controls for Elgato Stream Deck hardware, ported from
[omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
to the Noctalia v5 Luau plugin API (`plugin_api` 24). Version **1.1.0**.

This is not affiliated with Elgato.

Supported host: **lea**, a NixOS workstation on `x86_64-linux`. There is no
Darwin, macOS, aarch64, emily, zoe, or vanessa support.

Install, udev, visual editor, and release notes: repository root
[`README.md`](../README.md) and [`CHANGELOG.md`](../CHANGELOG.md).

```bash
noctalia msg plugins source add elgato git https://github.com/luxus/noctalia-elgato-control
noctalia msg plugins enable luxus/elgato-control
```

## What changed from the Omarchy plugin

- QML bar / panel / service rewritten as `widget.luau`, `panel.luau`, `service.luau`
- Visual editor ported to Luau: click a key/dial/pedal, pick an action, live apply
- Manifest is `plugin.toml` (`luxus/elgato-control`, `plugin_api = 24`)
- HID daemon still Python + hidapi, with the 15-key Stream Deck family
- Actions target Noctalia IPC (`noctalia msg …`) with niri fallbacks on lea

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
its own key map (`classicKeys` vs `keys`). Plus LCD/dials, Pedal, Wave, and
Key Lights only show in the panel when that device is present.

## hidapi on NixOS

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

## Profile

`~/.config/elgato-control/profile.json`

Commands below are from the **repository root**. The `status --json` object is
the plugin contract.

```bash
elgato-control/bin/elgato-control init
elgato-control/bin/elgato-control status --json
elgato-control/bin/elgato-control set-key --device classic 12 lock
elgato-control/bin/elgato-control set-key --device plus 1 terminal
```

## Tests

```bash
python3 elgato-control/tests/test_streamdeck.py
python3 -m unittest discover -s elgato-control/tests -v
nix flake check   # x86_64-linux only: same tests, luau-compile, editor checks, wrapped CLI
```

GitHub Actions runs those Python tests on `ubuntu-latest` (`x86_64`). Luau is
syntax-checked when `luau-compile` is on PATH, including `nix flake check` via
nixpkgs. There are no Darwin jobs.

## Credits

- HID daemon, Key Light safety, Wave controls, and visual editor model:
  Amit Patel, MIT, [omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
- Original 2017 BMP/page protocol: [python-elgato-streamdeck](https://github.com/abcminiuser/python-elgato-streamdeck)
- Elgato mark from the MIT-licensed `@elgato/icons` package
