# lea dual-deck diagnosis (v1.1.0) — no product fix yet

**Scope:** diagnose only. Ada reviews. Do not merge a HID/Luau product fix from this pass.

**Hardware lock (Kai via Helm):** Stream Deck Classic (15-key) **and** Stream Deck + are plugged in **at the same time**. "XLR dings" are the Wave:3 / Wave XLR PipeWire path. Key Lights if present. Everything in the README supported-hardware table must work — not Classic-only.

**Not the product:** [OpenDeck](https://github.com/nekename/OpenDeck). Skimmed for HID tips only. No port, no rewrite.

**Compared to:** [amitcpatel/omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control) `0.3.1` (Plus + Pedal verified; **no classic 15-key**). This plugin added classic PIDs, `classicKeys`, niri/Noctalia actions, and NixOS hidapi/udev. Dual-deck is therefore **our** contract, not upstream's.

**Host:** lea, NixOS `x86_64-linux`, niri, Noctalia v5 `plugin_api` 24. No Darwin.

**Tests this pass:** `python3 -m unittest discover -s elgato-control/tests -v` → **65 OK, 1 skipped** (`luau-compile` absent). See [docs/REVIEW.md](docs/REVIEW.md) for what the suite does not cover.

**Issues opened (do not close from this docs PR):**

| Pri | Issue | Theme |
| --- | --- | --- |
| P0 | [#4](https://github.com/luxus/noctalia-elgato-control/issues/4) | Dual-deck daemon is not a single hidraw owner (hidapi + `processMatches` + silent open) |
| P0 | [#5](https://github.com/luxus/noctalia-elgato-control/issues/5) | udev hidraw requires group `input`; niri seat may miss `uaccess` |
| P0 | [#6](https://github.com/luxus/noctalia-elgato-control/issues/6) | Wave XLR (XLR dings) not detected; ALSA gain is Wave:3-only |
| P1 | [#7](https://github.com/luxus/noctalia-elgato-control/issues/7) | Plus LCD / dual-deck key tiles blank without magick on plugin PATH |
| P1 | [#8](https://github.com/luxus/noctalia-elgato-control/issues/8) | Panel mappings: catalog cap, refresh vs daemon, `set-key` device default |
| P1 | [#9](https://github.com/luxus/noctalia-elgato-control/issues/9) | Key Light HTTP/mDNS stalls the HID loop for both decks |
| P2 | [#10](https://github.com/luxus/noctalia-elgato-control/issues/10) | unittest misses dual-deck, Wave XLR, udev, daemon lifecycle, panel VM |

---

## Why 1.1.0 can still look dead "front and back"

1.1.0 rebuilt the Luau panel (`ui.column` / `ui.row` / `ui.scroll`) and the visual editor. It **did not** change daemon lifecycle, hidapi injection into the plugin process, udev completeness, dual-deck HID open, Plus LCD artwork PATH, or Wave XLR detection.

On lea that means:

| Surface | What Kai sees | Likely cause in this tree |
| --- | --- | --- |
| **Front** (Noctalia panel) | Black / empty / mappings not sticking | Panel paints, but status is `running: false` / both decks `null` because the daemon never stays up; or `catalog`/`set-key` fail while the grid still renders "none" |
| **Back** (physical Classic + Plus) | Keys, dials, LCD do nothing | hidraw never opened, **two** daemons / OpenDeck holding exclusive HID, or ImageMagick not on the plugin PATH so tiles/LCD stay blank even when reports parse |

The dual-deck data model (`classic` + `plus` status objects, `classicKeys` vs `keys`) is **wired**. It is **not proven** on hardware, and several lifecycle bugs would take **both** decks down together.

---

## 1. HID protocols — what we send vs upstream vs Elgato

### Dual-deck split (this repo, not upstream)

Upstream `DEVICE_SPECS` is Plus `0x0084` + Pedal `0x0086` only
([omarchy `bin/elgato-control` L7–10](https://github.com/amitcpatel/omarchy-elgato-control/blob/main/bin/elgato-control)).

We add classic 15-key PIDs and keep Plus/Pedal:

```7:83:elgato-control/bin/elgato-control
VID = 0x0FD9
PLUS, PEDAL = 0x0084, 0x0086
ORIGINAL = 0x0060
CLASSIC_JPEG_PIDS = (0x006D, 0x0080, 0x00A5, 0x00B9)
# ...
DEVICE_SPECS = {
    ORIGINAL: { "kind": "classic", "image": "bmp", "origin_flip": True, "report": 8191, ... },
    0x006D: _classic_jpeg("Stream Deck"),
    0x0080: _classic_jpeg("Stream Deck Mk.2"),
    0x00A5: _classic_jpeg("Stream Deck Mk.2"),
    0x00B9: _classic_jpeg("Stream Deck"),
    PLUS: { "kind": "plus", "keys": 8, "key_px": 120, "lcd": (800, 100), ... },
    PEDAL: { "kind": "pedal", ... },
}
```

`connect()` keys status by `status_key` (`classic` / `plus` / `pedal`), so **one Classic + one Plus** can both appear:

```1121:1146:elgato-control/bin/elgato-control
    def connect(self):
        found = self.hid.paths()
        # ...
        self.status["plus"] = summary.get("plus")
        self.status["classic"] = summary.get("classic")
        self.status["pedal"] = summary.get("pedal")
        self.status["wave"] = detect_wave()
```

`keys_for()` reads `classicKeys` vs `keys`. `dispatch()` routes by `device["kind"]`. That is the dual-deck contract. Two Classics would collide on `status_key` (P2; not lea's lock).

**Silent open failure (P0 for dual-deck):** `hid_open_path` returning NULL is ignored. If Classic opens and Plus does not (or the reverse), status lies. If **neither** opens (udev, hidapi, or another process owns hidraw), both decks look dead:

```1127:1133:elgato-control/bin/elgato-control
        for info in found:
            if info["path"] not in self.devices:
                handle = self.hid.open(info["path"])
                if handle:
                    device = dict(info, handle=handle)
                    self.devices[info["path"]] = device
                    self.decorate(device)
```

No error is written when `handle` is 0. Upstream has the same pattern, but they only ever opened Plus+Pedal.

### Classic 15-key (BMP 2017 vs JPEG Mk.2)

| Piece | We send / parse | Verdict vs python-elgato-streamdeck |
| --- | --- | --- |
| Mk.2 JPEG pages `0x02 0x07` | `send_key_image` L1067–1073, 72×72 rotate 180 | Matches v2 header |
| 2017 BMP pages `0x02 0x01` | L1054–1066, `len(data)//2` chunks, 8191 reports, mirrored columns | Matches Original |
| Brightness | Original `0x05 0x55 0xAA 0xD1 0x01`; JPEG `0x03 0x08` | Matches |
| Key reports | Original bytes `[1:]` + `origin_index`; JPEG offset 4 after `[1, 0, 15, 0]` | Unit-tested; **not** live-tested on lea |

### Plus keys / dials / LCD

Checked against [Elgato Stream Deck + HID](https://docs.elgato.com/streamdeck/hid/stream-deck-plus/) (not OpenDeck):

| Event / command | Official | This daemon | Upstream Omarchy |
| --- | --- | --- | --- |
| Key press | `01 00` + 8 state bytes at +0x04 | `parse_plus` L1250–1257 | Same |
| Dial press | `01 03`, type `00`, 4 bytes | L1264–1272 | Same |
| Dial rotate | `01 03`, type `01`, signed ticks | L1273–1279 | Same |
| Touch TAP | `01 02`, type `01`, X/Y UINT16 | TAP → nearest dial press (L1258–1263). PRESS/FLICK ignored | TAP **not** mapped (known limitation) |
| Key JPEG | `02 07` 120×120, no rotate | Same header as Mk.2, `key_px` 120 | Same |
| **Window LCD 800×100** | **`02 0B`** full window | L1111–1115 `[0x02, 0x0B, 0, last, len, page]` | **Same 0x0B** |
| Partial LCD | `02 0C` rectangle | Not used | Not used |

**OpenDeck skim (tips only):** community stacks often speak **`0x0C` partial window** (python-elgato-streamdeck `StreamDeckPlus.set_touchscreen_image` uses `0x0C` with x/y/w/h). Elgato's own Plus page lists **both** `0x0B` (full window) and `0x0C` (partial). Our `0x0B` header layout matches Elgato. Do **not** rewrite onto OpenDeck. If lea's Plus LCD stays black after magick/PATH is fixed, capture `status.recentReports` and compare a `0x0B` vs `0x0C` write — as a **follow-up**, not a port.

Plus input report descriptor is 512 bytes. We `hid_read` 1024 (L247–249), which is safer than the 14-byte Plus reads that drop **dial turns** on some hidapi backends. Still **no** dual-device read test.

### Pedal

Same as upstream: 3-byte and padded 7-byte reports, edge-triggered press/release. Pedal is in the README table; not in Kai's lock but must not regress.

---

## 2. Python daemon lifecycle, hidapi on NixOS, udev

### Plugin daemon ≠ flake-wrapped CLI

`flake.nix` wraps **`nix run`** / the package with `ELGATO_HIDAPI=${hidapi}/lib/libhidapi-hidraw.so.0` and ImageMagick on `PATH`. The **enabled plugin** does not use that wrapper. `service.luau` execs the shebang script in the materialized plugin dir:

```16:27:elgato-control/service.luau
local function daemonCommand()
  local hid = noctalia.getConfig("hidapi_path")
  local prefix = ""
  if type(hid) == "string" and hid ~= "" then
    prefix = "ELGATO_HIDAPI=" .. quote(hid) .. " "
  end
  return prefix .. quote(helper) .. " daemon"
end

local function startDaemon()
  noctalia.runStream(daemonCommand(), function(_line) end)
end
```

`hidapi_path` default is `""` (`plugin.toml`). ctypes then tries `libhidapi-hidraw.so.0` and `/run/current-system/sw/lib/libhidapi-hidraw.so.0` (`hidapi_candidates` L175–187). That second path exists **only** if `hidapi` is in `environment.systemPackages`. NixOS does not put store libraries on the dynamic loader path otherwise. Constructor failure (`Hid()` L190–201) exits the daemon immediately. `runStream` dies. Panel `status --json` stays `{running: false, plus: null, classic: null, ...}`.

Upstream Omarchy only loads `"libhidapi-hidraw.so.0"` (Debian/Omarchy layout). They never had this NixOS gap.

### `processMatches` + exclusive HID (P0 dual-deck)

```64:71:elgato-control/service.luau
function update()
  noctalia.setUpdateInterval(2000)
  readStatus()
  noctalia.processMatches(function(matched)
    if not matched then
      startDaemon()
    end
  end, "elgato-control")
end
```

`processMatches` is true if **any** command line contains `elgato-control` ([runtime API](https://docs.noctalia.dev/noctalia/plugins/development/runtime-api/)). That includes:

- the daemon
- panel `runAsync({ helper, "status"|"profile"|"catalog"|"set-key"|... })` every 1.5s while the panel is open
- leftover OpenDeck is **not** matched (good), so OpenDeck can keep hidraw while we think we are healthy

Failure modes on lea:

1. **False negative:** daemon is `python3 .../elgato-control daemon` but `processMatches` races before it appears → **second** `runStream` daemon. Two processes, same two hidraw nodes. Upstream DEVELOPMENT_STATUS: *do not run two daemons against the same hidraw endpoints*. **Both Classic and Plus stop working.**
2. **False positive:** panel CLI is running, daemon is dead → we never restart the daemon. Keys dead, panel still "works" as a disconnected editor.
3. **OpenDeck / StreamController still running:** `hid_open_path` fails silently (L1130). Dual-deck status stays null. Kai: OpenDeck is also bad — treat a leftover OpenDeck process as a **blocker**, not an alternative.

`onExit` is empty. There is no SIGTERM of the child on plugin disable beyond whatever `runStream` teardown the host does.

### udev completeness

```1:3:elgato-control/udev/99-elgato-streamdeck.rules
# Elgato Stream Deck family (VID 0fd9) — hidraw access for the plugin daemon.
KERNEL=="hidraw*", ATTRS{idVendor}=="0fd9", TAG+="uaccess", MODE="0660", GROUP="input"
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", TAG+="uaccess", MODE="0660"
```

VID-wide is correct for Classic+Plus+Pedal+Wave HID interfaces on one machine.

Gaps vs Julusian/OpenAction community rules (the ones that actually work on seated Linux):

- No `SUBSYSTEM=="hidraw"` (only `KERNEL=="hidraw*"`).
- `MODE="0660"` (set-if-unset) + `GROUP="input"` — NixOS users are often **not** in `input`. If `uaccess` does not apply to the niri seat, hidraw is 0660 root:input and the daemon cannot open **either** deck.
- Community uses `MODE:="660"` (force) + `TAG+="uaccess"` without requiring `input`.
- Tests only `assertIn("uaccess")` / VID (`test_static.py` L56–60). No dry-run of `udevadm test`.

The flake NixOS module only `readFile`s this rule. Importing the module is necessary but **not sufficient** without a replug and a seated session.

### ImageMagick / key art / LCD PATH

`rendered_key_image` and `update_lcd` use `shutil.which("magick")` (process `PATH`), **not** `search_path()` extras (`/run/current-system/sw/bin`). The plugin daemon's PATH is Noctalia's. If `magick` is not there:

- Classic/Plus **key tiles stay stock/black**
- Plus **LCD** sets `status.error = "LCD rendering requires ImageMagick"` (L1100–1102) and returns
- Keys can still **fire** if HID opened

This repo also **dropped** upstream `assets/keys/*.jpg`. Artwork is 100% magick + DejaVu-Sans. Upstream ships eight JPEGs so Plus keys still get *something* without magick.

---

## 3. noctalia msg IPC: panel → service → daemon → key → action

```
widget/shortcut onClick
  → noctalia.togglePanel("luxus/elgato-control:panel")
panel.onOpen → runAsync argv: status / profile / catalog
service.onEnable → runAsync argv: init → runStream: daemon
daemon.loop
  → hid_read Classic / Plus / Pedal
  → parse_* → act(action)
  → command_for → noctalia msg … | niri msg action … | wpctl | gtk-launch
  → write ~/.local/state/elgato-control/status.json
```

`runAsync` argv form is `plugin_api` 24 (Noctalia ≥ v5.0.0-beta.9). 1.0.0 already declared 24, so lea could load the plugin; this is not a new gate unless lea was downgraded.

IPC names in `command_for` (L773–846) match current docs: `session lock`, `panel-toggle launcher`, `volume-up` / `volume-mute`, `screenshot-region`. Lock is no longer the invalid `noctalia msg lock` from 1.0.0.

Gaps that still drop key-fires:

- `command_for` returns `None` → `act` sets `"Unknown action: …"` (L1183–1184). `wtype`, `gtk-launch`, `niri`, `noctalia` must be on the **daemon** PATH (`which()` does add NixOS bin dirs; good).
- `NIRI_SOCKET` must be in the daemon environment for workspace/close. `runStream` inherits Noctalia's env; should be OK if Noctalia is started from the niri session.
- Dual-deck mapping: panel `editor.saveArgv` always passes `--device classic|plus` (L170–180). CLI `set-key` **without** `--device` treats index 1–8 as **Plus** (L1397–1398). Editing Classic key 1 from the CLI without `--device` silently writes the Plus profile.

Panel `refresh()` every 1.5s launches two/three CLI processes (`panel.luau` L76–108, L612–617). That is how `processMatches("elgato-control")` gets confused.

---

## 4. Luau panel / widget / editor

1.1.0 fixes that still look correct on paper:

- No `ui.box` as a flex parent (that was the 1.0.0 black panel).
- Closures on `onClick` are valid at `plugin_api` ≥ 9.
- `require("./editor.luau")` is API 22.
- Disconnected tabs still include classic **and** plus (`editor.deviceTabs`).
- Dual-deck tabs when **both** status objects are present (`test_editor.luau`).

Remaining front-end reasons Kai still cannot edit / fire:

1. **Status never shows connected** → tabs still classic+plus (disconnected fallback), inspector writes profile, **daemon never reloads tiles**, physical keys still default/unmapped from the device's point of view if decorate never ran.
2. **`filterCatalog(..., 80)`** (`editor.luau` L196–198, `panel.luau` L385) — 1.1.0 removed the 40-row `ui.select` cap, then recapped at 80 buttons. NixOS `XDG_DATA_DIRS` catalogs are large; mapped actions are pinned, but finding an app past 80 still fails.
3. **`catalog` CLI** calls `action_icon` → `resolve_icon` → `glob("**/name")` across every icon theme (`bin/elgato-control` L559–583, L606–613). Can approach `runAsync` 60s timeout. Inspector then shows "No matching actions." Grid can still render.
4. **No Noctalia VM in CI.** `error()` on missing `ui.*` would log, not paint. We cannot prove the 860×680 exclusive-focus panel paints on niri from this agent.

Widget/shortcut IDs (`luxus/elgato-control:panel`) match the manifest.

Brightness **plugin setting** is never applied to the daemon (profile `brightness` is). P2.

---

## 5. Wave XLR ("XLR dings") and Key Lights

### Wave

`detect_wave()` (L856–898) requires the substring **`"Elgato Wave"`** in `wpctl status`. Then ALSA `Mic Capture Volume` / `Mic Capture Switch` / `PCM Playback Volume`.

| Device | USB PID | PipeWire name | ALSA gain |
| --- | --- | --- | --- |
| Wave:3 | `0x0070` | often `Elgato Wave:3 …` | Yes — `Mic Capture Volume` |
| Wave XLR | `0x007d` | often `Wave XLR` / `Elgato_Wave_XLR_*` **without** the exact `"Elgato Wave"` phrase | **No** — gain/48V/mute live on vendor USB (`wIndex=0x3303`), not ALSA |

So on lea:

- If wpctl prints `Wave XLR Analog Stereo`, **`status.wave` is null** — no Wave tab, no `wave_*` actions, dials mapped to `mic_*` hit `@DEFAULT_AUDIO_SOURCE@` instead of the XLR.
- If it does match, `perform_wave_action` still calls `amixer cset 'Mic Capture Volume'` (L954–961) which **does not exist** on Wave XLR. Gain buttons error. Headphone ALSA *may* work.

Do **not** port OpenWave/OpenDeck. The fix later is: match `Wave XLR` / `Elgato_Wave_` in wpctl, use `wpctl set-mute` / default-source for mute, and **document** that hardware gain/48V is out of band (or a tiny vendor probe — not this diagnose PR).

`mic_mute` on Stream Deck keys uses the detected `sourceId` when `status.wave` is set (`command_for` L775–828). Dual-deck keys that mute "the mic" are only correct if Wave detection is.

### Key Lights

Same mDNS `_elg._tcp` / HTTP `:9123` path as upstream. `avahi-browse` via `shutil.which` (no NixOS extras). `refresh_lights` every 5s is synchronous and can stall HID reads when a light is unreachable (upstream known limitation). Dual-deck makes that stall hurt **both** Classic and Plus.

---

## 6. Gaps vs upstream that break e2e on lea

| Gap | Upstream Omarchy | This plugin | lea impact |
| --- | --- | --- | --- |
| Classic 15-key | Not supported | Added | Required; untested on hardware |
| Dual Classic+Plus | Impossible (no classic) | Intended | **Lock;** silent open / two daemons kill both |
| hidapi load | `libhidapi-hidraw.so.0` only | Extra NixOS paths + setting | Setting default empty; plugin ≠ flake wrap |
| Service process | Quickshell `Process` argv + 2s restart | `runStream` shell string + `processMatches` | Multiple exclusive HID owners |
| Key JPEGs | Shipped `assets/keys/*.jpg` | Missing; magick-only | Blank Classic/Plus tiles + blank LCD |
| Actions | `omarchy` / `hyprctl` / `uwsm-app` | `noctalia msg` / `niri` / `gtk-launch` | Names look right; daemon PATH still matters |
| Wave | Wave:3 ALSA | Same ALSA assumptions | **Wave XLR dings fail** |
| Panel | QML Process, capability-driven Plus-first | Luau; disconnected shows classic+plus | 1.1.0 layout OK; status still daemon-gated |
| Tests | Parsers + QML PlainText | Broader unit tests, **no live HID, no dual-deck mock connect, no Wave XLR names, no udev, no panel VM** | Green CI, dead lea |

---

## Recommended fix order (product PRs, not this one)

1. **P0 — One daemon, two hidraws.** Argv-safe spawn (or keep `runStream` but needle `elgato-control daemon` **and** refuse a second start). Log hidapi load and every `hid_open_path` failure into `status.error`. Inject `ELGATO_HIDAPI` from flake/nixpkgs even when the setting is empty. Kill leftover OpenDeck/StreamController in the lea runbook, not in code.
2. **P0 — udev on niri.** `KERNEL=="hidraw*", SUBSYSTEM=="hidraw"`, `MODE:="0660"`, `TAG+="uaccess"`, do not require `input`. Document replug. Confirm **both** `/dev/hidraw*` are user-readable.
3. **P0 — Dual-deck smoke on lea.** `status --json` must show `classic` **and** `plus` non-null. Press Classic key 1 and Plus key 1; confirm `lastAction` + separate profile fields. Add a unit test that `connect()` summary keeps both keys.
4. **P0 — Wave XLR detection.** Match `Wave XLR` / `Elgato_Wave_`; do not call `Mic Capture Volume` on XLR. Mute/default via wpctl. Gain/48V explicitly unsupported until a later vendor probe.
5. **P1 — Plus LCD + key art.** Put magick on the daemon PATH (same extras as `search_path()`). Restore or generate fallback tiles so Classic 15 + Plus 8 are not blank without DejaVu. Keep Elgato `0x0B` window writes; only try `0x0C` if lea LCD is still blank after magick.
6. **P1 — Panel apply path.** After `set-key --device …`, wait for profile mtime + `status.lastAction`. Drop or raise the 80-action cap. Timeout/fail `catalog` without blocking `profile`.
7. **P1 — Key Lights.** `avahi-browse` on PATH; do not block HID for 1.2s × N lights inside the read loop.
8. **P2 — Tests that would have caught this.** Dual-deck `paths()` fixture; Wave XLR wpctl fixture; LCD header vs Elgato `0x0B`; udev `SUBSYSTEM=="hidraw"`; `processMatches` needle; no live deck required.

---

## What `unittest` misses (ran 2026-09-16)

Command: `python3 -m unittest discover -s elgato-control/tests -v`

**65 tests, OK, 1 skipped** (`test_luau_syntax_when_compiler_is_available`).

Not covered:

- Two hid devices in one `Daemon.connect` / `dispatch` loop
- `hid_open_path` failure recording
- Live hidapi/hidraw/udev
- Wave XLR / `Wave XLR` wpctl lines
- Plus LCD `0x0B` vs `0x0C` on hardware; magick missing
- `service.luau` `runStream` / `processMatches` behavior
- `panel.luau` `panel.render` on Noctalia/niri (black panel)
- Exclusive HID vs a second daemon or OpenDeck
- `set-key` without `--device` dual-deck footgun
- Key Light HTTP (mocked only for host validation)
- `luau-compile` / `luau editor-check` on this host (flake check only)

Hardware verification remains on lea. This document is the backlog for Ada.
