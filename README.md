# noctalia-elgato-control

Noctalia v5 plugin source for **Elgato Control** — native Linux HID for Stream Deck (15-key family, including Mk.2) and Stream Deck +, plus Pedal, Wave:3, and Key Lights.

Forked and ported from [amitcpatel/omarchy-elgato-control](https://github.com/amitcpatel/omarchy-elgato-control) (Omarchy / QML) to the Noctalia v5 Luau plugin API.

```bash
noctalia msg plugins source add elgato git https://github.com/luxus/noctalia-elgato-control
noctalia msg plugins enable luxus/elgato-control
```

Plugin files live in [`elgato-control/`](elgato-control/). See that README for hardware, udev, NixOS, and CLI details.

Not affiliated with Elgato.
