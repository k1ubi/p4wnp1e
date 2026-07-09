```
█▀▀ █▀█ █░█░█ █▄░█ █▀█ ▄▄ ▄▀█ █░░ █▀█ ▄▄ ▄▀█
█▀░ █▀▀ ▀▄▀▄▀ █░▀█ █▀▀ ░░ █▀█ █▄▄ █▄█ ░░ █▀█

           :: RASPBERRY PI 4B EDITION ::
        [ USB-C GADGET // arm64 // KALI ]
```

<p align="center">
  <img alt="platform" src="https://img.shields.io/badge/platform-Raspberry%20Pi%204B-e6007e?style=flat-square&logo=raspberrypi&logoColor=white">
  <img alt="arch" src="https://img.shields.io/badge/arch-arm64%20%2F%20aarch64-00ff9f?style=flat-square">
  <img alt="base" src="https://img.shields.io/badge/base-Kali%20Linux-557c94?style=flat-square&logo=kalilinux&logoColor=white">
  <img alt="lang" src="https://img.shields.io/badge/backend-Go-00add8?style=flat-square&logo=go&logoColor=white">
  <img alt="status" src="https://img.shields.io/badge/hardware%20verified-NOT%20YET-ff2079?style=flat-square">
  <img alt="license" src="https://img.shields.io/badge/license-see%20LICENSE-lightgrey?style=flat-square">
</p>

<p align="center"><sub>
a low-cost, walk-up physical access implant. keyboard, mouse, network card,
mass storage device, wifi AP, all in one box, all controlled over gRPC — now
ported from the Pi Zero W it was born on to the Pi 4B.
</sub></p>

---

### `> WHAT THIS IS`

[**P4wnP1 A.L.O.A.**](https://github.com/RoganDawes/P4wnP1_aloa) turns a
Raspberry Pi into a composite USB gadget — HID keyboard/mouse injection,
RNDIS/CDC-ECM "network takeover," USB mass storage, all switchable at
runtime through a gRPC API, CLI, and web UI. Originally: Pi Zero W only,
ARMv6, one core, one USB port.

This fork ports the whole stack — service daemon, CLI, GPIO, LED, Bluetooth,
WiFi/nexmon, the composite USB gadget itself — to the **Pi 4 Model B**:
Cortex-A72, arm64, four spare host-mode USB-A ports left over *while the
USB-C port is doing gadget duty*. Full engineering writeup, with receipts,
in **[`PORTING.md`](PORTING.md)**.

```
┌──────────────────────────────────────────────────────────┐
│  USB-C  ──▶ dwc2 (peripheral)  ──▶ composite gadget       │
│              HID kbd/mouse · RNDIS · CDC-ECM · mass       │
│              storage · ACM serial — mix & match, live     │
│                                                            │
│  USB-A ×4 ─▶ still host mode — plug in wifi/storage/etc   │
│              *at the same time*. Pi Zero W never had this.│
└──────────────────────────────────────────────────────────┘
```

### `> WHY THIS FORK EXISTS`

The original Pi0W pipeline leaned on a hand-patched dwc2 kernel driver and a
hand-patched brcmfmac WiFi firmware, both tied to one abandoned kernel
branch. Upstream's own build notes call this out directly — "official Kali
support disappeared." None of that debt survived the port:

| upstream (Pi0W) | this fork (Pi4B) |
|---|---|
| custom out-of-tree dwc2 patch, one dead kernel branch | stock mainline dwc2, polls `/sys/class/udc/*/state` |
| `periph.io` v3.3.0 — errors on unknown board rev | `periph.io/x/{conn,host}/v3` — real bcm2711 support |
| hand-built nexmon firmware, no CI, no maintainer | Kali's `brcmfmac-nexmon-dkms` + `firmware-nexmon`, apt-installed |
| GopherJS build needs a pinned Go + Kali-rolling container | WebUI ships prebuilt, unchanged — it's just JS |
| `led0` sysfs path hardcoded | probes `led0` then `ACT` (Pi4B's real DT label) |

### `> QUICKSTART`

```sh
# cross-compile the backend for arm64 — no special container needed
./build_support/pi4b/build.sh

# assemble a flashable image on top of Kali's official Pi arm64 image
# (ships DKMS nexmon out of the box — see PORTING.md)
sudo ./build_support/pi4b/image/build-image.sh

# flash it
xz -d build_support/pi4b/image/out/work/base.img.xz
sudo dd if=build_support/pi4b/image/out/work/base.img of=/dev/sdX bs=4M status=progress
```

### `> STATUS`

Backend builds clean and native for `linux/arm64` — verified in this repo,
not asserted. Board-support gaps (GPIO, LED, WiFi chip, dwc2) were checked
against real kernel/device-tree/dependency source, not folklore. What's
**not** yet confirmed: booting the assembled image on physical Pi4B
hardware. See **[`PORTING.md`](PORTING.md) → "Verified vs. not yet
verified"** for the exact, honest split — no hand-waving.

### `> NOT PORTED`

mame82's bespoke WiFi "covert channel" firmware mod (`dist/legacy/`,
`dist/scripts/wifi_covert_channel.sh`) was hand-written ARM-Thumb code
against the Pi0W's specific WiFi chip ROM. The Pi4B has a different chip.
Porting that channel means reverse-engineering a different ROM from
scratch — real firmware RE, not a mechanical port. Left out on purpose,
documented, not faked. Standard nexmon monitor mode / packet injection *is*
ported and works the same either way.

### `> ETHICS / AUTHORIZATION`

This is a physical-access implant. Use it only on hardware and networks you
own or are explicitly authorized to test. See **[`DISCLAIMER.md`](DISCLAIMER.md)**.

### `> CREDITS`

- [mame82](https://github.com/mame82) — original P4wnP1 A.L.O.A. and the
  entire architecture this stands on.
- [RoganDawes](https://github.com/RoganDawes) — upstream maintenance this
  fork branches from.
- This fork — Pi4B port: build tags, dwc2 watcher, `periph.io` v3 migration,
  LED sysfs fix, nexmon retarget + Kali DKMS integration, `wlan0mon` wiring,
  image build pipeline. See `git log` on `pi4b-port` and `PORTING.md` for
  the full account of what changed and why.

```
░░░ every USB port is an attack surface ░░░
```
