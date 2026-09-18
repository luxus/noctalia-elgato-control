# Changelog

## Unreleased

Daemon / HID / NixOS: open Classic 15-key **and** Stream Deck + at the same time
(keys on both; Plus dials + LCD artwork + brightness). Wave:3 **and** Wave XLR
via PipeWire/ALSA (`wpctl` when XLR has no ALSA gain). Key Lights unchanged if
present. hidapi lookup includes libusb + Nix profile paths. udev rules are
`70-elgato-streamdeck.rules` installed with `services.udev.packages` so
`TAG+="uaccess"` actually applies. Plus LCD HID is report `0x02` / command
`0x0B` (8-byte full window). `0x0C` partial was tried on main and flickered
on lea; it stays as an unused fallback helper only.

Panel apply path: inspector catalog is uncapped and no longer walks XDG icon
trees; status/profile are read from disk so `runAsync` slots stay free for
`set-key` / `set-dial` / `set-pedal`; `set-key` requires `--device classic|plus`;
service `processMatches` needle is the daemon, not every CLI. ImageMagick is
found via the same NixOS bin extras as `search_path()`. App-mapped keys resolve
`.desktop` `Icon=` through gtk-icon-theme then a bounded (non-glob) cache.
Wave / Key Light tabs stay live controls from daemon status. A second daemon
refuses the hidraw flock instead of opening Classic and Plus out from under
the owner; a failed `hid_open_path` is recorded in `status.error` even when
the other deck stays open. Plus is not re-opened when hidapi flips extra
interfaces (that dual-write is the Classic-OK / Plus-blink loop).

Wave XLR never uses ALSA `Mic Capture Volume` even when `wpctl inspect` reports an ALSA card id; mute/volume stay on PipeWire.

NixOS udev: `MODE:="0660"` without `GROUP="input"` so a niri seat can open Classic and Plus.

## 1.1.0

Visual editor and action-mapping release for lea (NixOS, `x86_64-linux`, Noctalia v5 `plugin_api` 24). Tag this as `v1.1.0`. Do not treat 1.0.0 as a working editor.

### What 1.0.0 actually did

- The plugin **loaded** and the HID daemon could connect.
- The **panel was black**. The Luau tree used `ui.box` as a flex parent; in Noctalia v5 `ui.box` is a leaf color swatch. Unknown layout children are skipped, so the surface rendered empty.
- **Editing buttons was not possible.** The inspector was a `ui.select` truncated to the first 40 catalog rows. `selectedIndex` 0 overwrote keys with the wrong action when the mapped one was not in that slice.
- **Some keys fired, most did not map correctly.** `lock` called `noctalia msg lock` (invalid in v5; the command is `session lock`). Desktop files were only read from `/usr/share/applications` and `~/.local/share/applications`, so NixOS apps under `XDG_DATA_DIRS` / `/run/current-system/sw/share/applications` never appeared. `niri` / `noctalia` / `wtype` were looked up on a thin PATH and launched by basename.

### What this version fixes

- Panel rebuilt on the official v5 layout API (`ui.column` / `ui.row` / `ui.scroll`). Missing `panel` / `ui` / `runAsync` APIs `error()` instead of drawing a blank surface.
- Omarchy-style visual editor: device tabs, click a physical key / dial / pedal, filterable action list, live `set-key` / `set-dial` / `set-pedal`. Plus LCD + dials, Pedal, Wave, and Key Lights only when that hardware is present. Classic 15-key and Plus profiles stay editable while disconnected.
- Action catalog is no longer capped. Current mapping is pinned at the top of the inspector.
- Key actions use argv `noctalia.runAsync` (`plugin_api` 24). Lock is `noctalia msg session lock`. niri workspace / close-window and `noctalia msg` launcher / volume / media / screenshot paths are resolved through NixOS bin dirs. Desktop files follow `XDG_DATA_HOME` / `XDG_DATA_DIRS` plus NixOS share paths.
- Tests for the editor state machine (select key → set action → profile write), action catalog, NixOS desktop paths, and the existing HID protocol suite.
- README a person can follow on lea. Version `1.1.0` in `plugin.toml` and `catalog.toml`.

### Unchanged

- Python + hidapi daemon and Stream Deck protocol. Not rewritten.
- lea / `x86_64-linux` only. No Darwin.

## 1.0.0

First tagged plugin on this repo. HID daemon, Nix flake, and Linux CI. Panel/editor as shipped did not work on lea.
