# Elgato Control for Noctalia v5

Unofficial native Linux controls for Elgato Stream Deck hardware, ported from
[omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
to the Noctalia v5 Luau plugin API.

This is not affiliated with Elgato.

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

```nix
services.udev.extraRules = ''
  KERNEL=="hidraw*", ATTRS{idVendor}=="0fd9", TAG+="uaccess", MODE="0660"
'';
```

Or copy `udev/99-elgato-streamdeck.rules` to `/etc/udev/rules.d/` and replug.

If ctypes cannot find hidapi (common on NixOS without nix-ld), set
`ELGATO_HIDAPI` to the absolute `libhidapi-hidraw.so.0` path, or the plugin
setting **hidapi library path**.

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

```bash
plugin/elgato-control/bin/elgato-control init
plugin/elgato-control/bin/elgato-control status --json
plugin/elgato-control/bin/elgato-control set-key --device classic 12 lock
plugin/elgato-control/bin/elgato-control set-key --device plus 1 terminal
```

## Tests

```bash
python3 plugin/elgato-control/tests/test_streamdeck.py
```

## Credits

- HID daemon, Key Light safety, Wave controls, and visual editor model:
  Amit Patel, MIT, [omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control)
- Original 2017 BMP/page protocol: [python-elgato-streamdeck](https://github.com/abcminiuser/python-elgato-streamdeck)
- Elgato mark from the MIT-licensed `@elgato/icons` package
