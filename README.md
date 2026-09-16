# noctalia-elgato-control

Noctalia v5 plugin for Elgato Stream Deck hardware on **lea** (NixOS, `x86_64-linux`). Visual key / dial / pedal editor, capability-driven panel, Python HID daemon.

Ported from [amitcpatel/omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control) (Omarchy QML) to Noctalia v5 Luau (`plugin_api` 24). Plugin id: `luxus/elgato-control`. Current release line: **v1.1.0**.

Not affiliated with Elgato. Darwin / macOS / other machines are out of scope.

## Install on lea

```bash
noctalia msg plugins source add elgato git https://github.com/luxus/noctalia-elgato-control
noctalia msg plugins enable luxus/elgato-control
```

Add the bar widget in Noctalia settings. Click it (or the Elgato shortcut) to open the panel.

1.0.0 loaded and could talk to the deck, but the panel was black and you could not edit keys. Use **1.1.0** (or newer). After enabling, open the panel once and confirm you see a key grid, not an empty surface.

### udev

The plugin talks to Stream Deck hidraw nodes on **lea** (`x86_64-linux`, niri). Import this flake’s NixOS module (`services.udev.packages`, not `extraRules` — `uaccess` must load before `73-seat-late.rules`).

Rules are `SUBSYSTEM=="hidraw"` + `MODE:="0660"` + `TAG+="uaccess"`. They do **not** require group `input` (niri users are often not in that group).

[luxusAi #143](https://github.com/luxus/luxusAi/pull/143) inlined older `GROUP="input"` extraRules onto lea. That copy is 99-local (too late for uaccess). Prefer this module; do not add `GROUP="input"` here to match lea.

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

Or copy `elgato-control/udev/70-elgato-streamdeck.rules` into `/etc/udev/rules.d/` (keep the `70-` prefix so `uaccess` runs before systemd `73-seat-late.rules`), then:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Unplug and replug **both** Classic and Plus. Confirm both hidraw nodes are readable by the niri user.

### hidapi

If ctypes cannot find hidapi, set the plugin setting **hidapi library path** to the absolute `libhidapi-hidraw.so.0` path (or export `ELGATO_HIDAPI`). Typical NixOS location: `/run/current-system/sw/lib/libhidapi-hidraw.so.0` when `hidapi` is in `environment.systemPackages`.

## Visual editor

1. Click the bar widget. You should see **Elgato Control**, device tabs, a key preview, and an **Action inspector**.
2. Tabs appear from hardware: Stream Deck (15-key), Stream Deck + (LCD/dials when a Plus is present), Pedal, Wave:3 / Wave XLR, Key Lights. Classic and Plus stay open together (`classicKeys` vs `keys`). If nothing is plugged in you still get classic + Plus so you can edit the profile.
3. Click a key, dial, or pedal on the preview.
4. Filter the action list if you want, then click an action. It is written immediately (`set-key` / `set-dial` / `set-pedal`). There is no JSON-only editor in the panel.
5. Press the physical key. It should run that mapping (niri workspace / close window, `noctalia msg` launcher / lock / volume / media / screenshot, or a `.desktop` app from NixOS `XDG_DATA_DIRS`).

Wave and Key Lights tabs are live controls (gain, mute, power, brightness, temperature), not key maps.

## CLI

From a checkout:

```bash
elgato-control/bin/elgato-control init
elgato-control/bin/elgato-control status --json
elgato-control/bin/elgato-control catalog
elgato-control/bin/elgato-control set-key --device classic 1 lock
elgato-control/bin/elgato-control set-key --device plus 1 terminal
elgato-control/bin/elgato-control set-dial 1 press volume_mute
elgato-control/bin/elgato-control set-pedal 1 mic_mute
```

`--device` is required. Classic is 1–15 (`classicKeys`). Plus is 1–8 (`keys`) plus four dials. Omitting `--device` no longer writes Plus keys 1–8.

Profile: `~/.config/elgato-control/profile.json`. `status --json` is the plugin contract.

## Tests

```bash
python3 -m unittest discover -s elgato-control/tests -v
nix flake check   # x86_64-linux: same tests, luau-compile, editor.luau checks, wrapped CLI
```

No Stream Deck or Noctalia shell is required in CI. Hardware verification is on lea.

See [`elgato-control/README.md`](elgato-control/README.md) for device PIDs, hidapi notes, and protocol tests. See [`CHANGELOG.md`](CHANGELOG.md) for 1.0.0 vs 1.1.0 and Unreleased panel apply-path notes.
