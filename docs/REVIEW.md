# Review backlog — noctalia-elgato-control vs omarchy-elgato-control

Ada: diagnose-only. Product HID/Luau fixes are **not** in this PR. Full evidence: [`../DIAGNOSE.md`](../DIAGNOSE.md).

## Hardware lock

lea has **Stream Deck Classic (15-key) and Stream Deck + at once**, Wave XLR ("XLR dings"), Key Lights if present. README table is SoT. OpenDeck is not the product.

## Tests this pass

```text
$ python3 -m unittest discover -s elgato-control/tests -v
Ran 65 tests in ~17s
OK (skipped=1)   # luau-compile not on PATH
```

Green unit tests do **not** mean dual-deck e2e. See DIAGNOSE § “What unittest misses”.

## Fix order (next product PRs)

| Order | Pri | Issue | Theme | Why lea still fails after 1.1.0 |
| --- | --- | --- | --- | --- |
| 1 | P0 | [#4](https://github.com/luxus/noctalia-elgato-control/issues/4) | Single daemon + hidapi + open errors | Plugin spawn ≠ flake wrap; `processMatches("elgato-control")` can start a second exclusive HID owner and kill **both** decks |
| 2 | P0 | [#5](https://github.com/luxus/noctalia-elgato-control/issues/5) | udev hidraw `uaccess` without `input` group | `MODE="0660", GROUP="input"` on NixOS/niri |
| 3 | P0 | [#4](https://github.com/luxus/noctalia-elgato-control/issues/4) | Dual-deck smoke | `status.classic` **and** `status.plus` must be non-null; maps are already split (`classicKeys` / `keys`) |
| 4 | P0 | [#6](https://github.com/luxus/noctalia-elgato-control/issues/6) | Wave XLR | `"Elgato Wave"` + `Mic Capture Volume` is Wave:3-only; XLR dings never get a real Wave tab |
| 5 | P1 | [#7](https://github.com/luxus/noctalia-elgato-control/issues/7) | Plus LCD + key JPEG PATH | `shutil.which("magick")`; no `assets/keys/*.jpg`; Elgato `0x0B` header is already correct on paper |
| 6 | P1 | [#8](https://github.com/luxus/noctalia-elgato-control/issues/8) | Panel apply / catalog | 80-action cap, catalog glob timeout, CLI `set-key` 1–8 defaults to Plus |
| 7 | P1 | [#9](https://github.com/luxus/noctalia-elgato-control/issues/9) | Key Lights vs HID loop | synchronous mDNS/HTTP inside the 25ms read loop |
| 8 | P2 | [#10](https://github.com/luxus/noctalia-elgato-control/issues/10) | Tests + leftovers | dual-deck connect fixture, Wave XLR names, unused brightness setting, lcd_svg XML no-op |

## OpenDeck

Skim only. Community often uses Plus LCD **`0x0C`**. Elgato documents **`0x0B`** full window (what we and Omarchy send) **and** `0x0C` partial. Do not port OpenDeck. If LCD is still blank after magick/udev/daemon, try `0x0C` as a protocol A/B — later.

## Do not merge this PR as a “fix”

It only adds the diagnosis backlog. Tag product work on [#4](https://github.com/luxus/noctalia-elgato-control/issues/4)–[#10](https://github.com/luxus/noctalia-elgato-control/issues/10). Do not close those issues from this docs PR.
