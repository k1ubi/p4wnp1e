# P4wnP1 A.L.O.A. — Raspberry Pi 4B port

This branch (`pi4b-port`) ports [RoganDawes/P4wnP1_aloa](https://github.com/RoganDawes/P4wnP1_aloa)
(itself a continuation of mame82's original P4wnP1 A.L.O.A.) from its sole
original target — Raspberry Pi Zero W (BCM2835, ARMv6, single core) — to the
Raspberry Pi 4 Model B (BCM2711, Cortex-A72 arm64).

`build_support/pi4b/image/build-image.sh` supports two base images
(`BASE_DISTRO=kali`, the default, or `BASE_DISTRO=raspios`) - see "Base image:
Kali vs. Raspberry Pi OS" below for why Kali is the recommended default.
Everything else in this document (dwc2/gadget, GPIO, LED, build tags, etc.)
applies identically to both; they're both Debian-based and both default to
NetworkManager.

Everything below was arrived at by actually reading the upstream source
(not guessing from the project's reputation) and, where possible, by actually
building the arm64 binaries in this repo and inspecting the real dependency
source for board-support gaps. Section "Verified vs. not yet verified" at the
bottom is the honest accounting of what that does and doesn't cover.

## Why this is a real port, not a recompile

P4wnP1's entire value proposition — HID keyboard/mouse injection, USB
RNDIS/CDC-ECM "network takeover", USB mass storage, all switchable at
runtime — rests on Linux's USB **gadget/OTG** mode, which needs the SoC's USB
controller running in *peripheral* (device) mode, not host mode. Pi Zero W's
single micro-USB port runs through a `dwc2` controller that supports this.
Pi 4B's four black USB-A ports are host-only (VL805, PCIe-attached xHCI) —
but the USB-C port **is** wired to the SoC's own internal `dwc2` core, the
same IP block Pi0W uses. This was the first thing worth confirming rather
than assuming, since there's a lot of stale "Pi4's USB-C is power-only"
folklore out there; it's wrong for gadget purposes. Confirmed against
Raspberry Pi's own forums (see Sources in build_support/pi4b/boot/).

Net effect: this port is possible on **stock Pi4B hardware, no soldering, no
custom kernel** — `dtoverlay=dwc2,dr_mode=peripheral` on the USB-C port is
all it takes, and it's a bonus that the four USB-A ports stay available in
host mode simultaneously (Pi0W had no spare host port at all).

## What actually needed to change

Reading the source, the vast majority of the codebase (`hid/`, `mnetlink/`,
`mgenetlink/`, `netlink/`, `common/`, `common_web/`, `cli_client/`, all of
`web_client/`, most of `service/*.go` including the entire configfs USB
gadget implementation in `SubSysUSB.go`) is **generic Linux code with no
Pi0-specific assumptions at all**. The actual porting work concentrated on a
small number of real, verified issues:

### 1. Build tags that made arm64 literally not compile

`cmd/P4wnP1_service/P4wnP1_service.go`, `cmd/testhid/testhid.go`,
`service/bluetooth.go`, `service/datastore/store.go`, and `service/service.go`
were all tagged `// +build linux,arm`. Since `arm64` doesn't match the `arm`
constraint, **upstream's backend never compiled for any architecture except
armv6/v7** — confirmed by trying it (`build constraints exclude all Go files`
before the fix). Broadened to `// +build linux`; nothing inside those files
was actually arch-specific.

### 2. `service/dwc2_connect_watcher.go` — the one real out-of-tree kernel dependency

Upstream's USB-connect/disconnect event notification depended on a **custom
patch to the dwc2 kernel driver** that emits generic-netlink multicast
messages, maintained on one specific Pi Zero W kernel branch
(`re4son-raspberrypi-linux`, `rpi-4.14.80-re4son-p4wnp1`). Per the project's
own build notes (`build_support/p4wnp1_aloa_build_notes.md`): that branch
stopped being ported forward years ago, and official Kali image support for
P4wnP1 "disappeared" as a result. There's no equivalent patch for any Pi4B
kernel, and hand-maintaining one per kernel bump is exactly the kind of
bitrot that killed the original image builds.

Replaced with a portable implementation that polls the standard
`/sys/class/udc/<udc>/state` file mainline `dwc2`/the generic Linux gadget
framework already expose on every Pi (0/3/4/5/CM4), with zero kernel
patching. Same public API, drop-in replacement — `service.go` didn't need to
change.

### 3. `periph.io/x/periph` v3.3.0 doesn't know Pi4 exists

`service/SubSysGpio.go` and `service/pgpio/` use `periph.io` for all GPIO
(button triggers, `service/pgpio`'s edge detection). Read the actual vendored
v3.3.0 source: its board-revision-code switch in `host/rpi/rpi.go` has cases
for every Pi up to the 3B+, and:

```go
default:
    return true, fmt.Errorf("rpi: unknown hardware version: 0x%x", i)
```

for anything else — including every Pi4B revision code. This means GPIO
subsystem init would hard-fail on real Pi4B hardware. Migrated to the
successor split modules, `periph.io/x/conn/v3` + `periph.io/x/host/v3`
(confirmed by cloning `periph/host` upstream and finding explicit `board4B`
handling, `bcm2711` revision-code constants, etc.) — same API surface
(`host.Init()`, `gpioreg`, `pinreg`, `gpio.PinIO`), just a new import path and
`driverreg.State` instead of `periph.State`.

### 4. Hardcoded `/sys/class/leds/led0` — Pi4B's ACT LED is named differently

`service/led.go` and `service/SubSysLED.go` both hardcode
`/sys/class/leds/led0/{trigger,brightness}` for the status-blink feature.
Checked Raspberry Pi's own device tree source
(`bcm283x-rpi-led-deprecated.dtsi`, included by `bcm2711-rpi-4-b.dts`): Pi4B's
ACT LED DT label is `"ACT"`, i.e. `/sys/class/leds/ACT`, not `led0`. Since the
original code discards `ioutil.WriteFile` errors, this would have failed
**silently** — no crash, the LED just never blinks, with no log line pointing
at why. Now probes `led0` then `ACT` at load time and uses whichever exists,
so it works on both Pi0W-family boards and Pi4B without needing to know which
board it's on.

### 5. WiFi chip change: BCM43430A1 → BCM43455C0, and the nexmon "covert channel" gap

Pi0W's WiFi chip (BCM43430A1) and Pi4B's (BCM43455C0) are different chips
with different firmware. Standard nexmon monitor-mode/frame-injection support
**is** available for bcm43455c0 upstream (confirmed by listing
`seemoo-lab/nexmon`'s repo tree directly — `patches/bcm43455c0/7_45_206/...`
etc. exist with the same monitormode/injection/sendframe patch files as the
bcm43430a1 target). `build_support/pi4b/nexmon/build-nexmon.sh` retargets the
firmware build accordingly.

What does **not** carry over: mame82's `nexmon_wifi_covert_channel` fork
added a bespoke, hand-written covert C2 channel on top of the standard
bcm43430a1 patch (`dist/scripts/wifi_covert_channel.sh`,
`dist/legacy/{hidstager.py,wifi_server.py,wifi_agent.ps1}`). That's original
ARM-Thumb firmware patch code written against BCM43430A1's specific ROM
layout and free-RAM offsets. It was never ported to any other chip by anyone,
and doing so for bcm43455c0 means reverse-engineering that chip's ROM and
re-implementing the covert channel's firmware-side logic from scratch — real
firmware RE work, not a mechanical port. **Explicitly out of scope in this
session.** Standard nexmon monitor mode / injection (KARMA-style attacks,
deauth, raw 802.11 capture) works; the covert channel legacy scripts do not,
and aren't included in the Pi4B install list.

While in `service/wifi.go`, also found (and fixed, since it's directly
adjacent and small) that the nexmon on/off toggle — fully wired through
`proto/grpc.proto`'s `WiFiSettings.nexmon`, `cli_client/cmd_wifi.go
--nonexmon`, and the WebUI's "Nexmon" toggle — was a
`//ToDo: Dis/Enable nexmon if needed` stub in upstream that never actually
swapped firmware at runtime. Implemented it: detects whether the board has
`brcmfmac43430-sdio` (Pi0W-family) or `brcmfmac43455-sdio` (Pi4B-family)
firmware installed, swaps the requested variant into place, reloads the
kernel module. Works for either board family from one binary.

### 6. Bluetooth — verified generic, no change needed

`service/bluetooth.go` talks to BlueZ purely over D-Bus
(`bluetooth.FindFirstAvailableController()`, mame82's `mblue-toolz`
bindings) — no Pi0-specific code path. The only Pi0-specific thing in the
*old* Kali image build was packaging the right `.hcd` Bluetooth firmware
file, because Kali didn't ship it; Raspberry Pi OS Bookworm already ships
correct firmware/`pi-bluetooth` support for Pi4B's Bluetooth chip out of the
box, so this is a non-issue on the new base image.

### 7. Toolchain simplification (WebUI needs no rebuild at all)

Upstream's build container clones a Kali rolling image, installs a pinned
old Go release because GopherJS needed it, and hand-clones three separate
Go-source repos into `GOPATH` because GopherJS predates Go modules. None of
that is needed for a hardware port:

- The backend (`P4wnP1_service`/`P4wnP1_cli`) has **no cgo dependency
  anywhere in the tree** (checked: `grep -rl 'import "C"'` across everything
  returns nothing), so a stock `golang:1.23-bookworm` image cross-compiles it
  for arm64 in one step — verified locally: `GOOS=linux GOARCH=arm64
  CGO_ENABLED=0 go build` succeeds for both binaries, producing static ELF
  aarch64 executables.
- The WebUI (`build/webapp.js`) is GopherJS-compiled **plain JavaScript** —
  architecture-independent, and already checked into the repo prebuilt. It
  ships as-is. It only needs recompiling if `proto/grpc.proto` or the
  `web_client/*.go` GopherJS sources change, which is a feature-development
  concern, not a hardware-port concern.

See `build_support/pi4b/Dockerfile` / `build_support/pi4b/build.sh`.

### 8. Network stack: NetworkManager (Bookworm) vs dhcpcd (old Raspbian/Kali)

Upstream's Makefile just ran `systemctl disable networking.service` and
otherwise left dhcpcd alone. Bookworm defaults to NetworkManager, which would
otherwise fight P4wnP1 for ownership of `wlan0`/`usb0`/`usb1`/`usbeth`/`bnep*`
(P4wnP1 runs `hostapd`/`wpa_supplicant`/its own `dnsmasq` directly as
subprocesses on those interfaces). `build_support/pi4b/network/10-p4wnp1-unmanaged.conf`
tells NetworkManager to leave exactly those interfaces alone, without
disabling it wholesale — so a physical `eth0` or an unrelated WiFi adapter
still gets normal DHCP/NM convenience, which the old blanket-disable approach
didn't preserve.

### `dhcpcd` — a real gap, found by reading Kali's own build recipe

Kali's official build-scripts repo (`gitlab.com/kalilinux/build-scripts/kali-arm`)
still carries a live `raspberry-pi-zero-w-p4wnp1-aloa.sh`, plus the generic
`raspberry-pi.sh` used for the actual Pi4/5 arm64 images. Reading both against
this port's code turned up one real, concrete gap: `service/dhcp.go`'s DHCP
*client* mode (WiFi STA joining an existing network, etc.) execs
`/sbin/dhcpcd` directly — hardcoded path, merged-usr resolves it to
`/usr/sbin/dhcpcd`. Neither Bookworm nor current Kali installs `dhcpcd` by
default (both default to NetworkManager for everything P4wnP1 doesn't
already own), so without it DHCP client mode would fail outright the first
time anyone tried it. `dhcpcd5` (Debian/Kali's transitional package name,
pulling in the real `dhcpcd` package) is now in `build-image.sh`'s install
list, with its systemd service disabled straight after — same reasoning
Kali's own script uses: P4wnP1 invokes the binary directly, on demand, per
interface, so the packaged systemd unit (which tries to manage every
interface on boot) only gets in the way.

Also corrected against that same script: **not** enabling `haveged`. Pi4B has
a real hardware RNG (`bcm2711-rng200`) feeding the kernel entropy pool
directly; Pi0W didn't, which is why upstream enabled haveged in the first
place. Kali's current Pi4/5 build explicitly disables haveged for exactly
this reason — matched here instead of carrying over the Pi0W-era default.

Everything else in that script (`brcmfmac-nexmon-dkms`/`firmware-nexmon`,
`pi-bluetooth`, `hciuart`/`bluetooth` service enablement, `BCM4345C0.hcd`,
`/boot/firmware` layout) already matched what this port had independently
arrived at or is already baked into Kali's published image — good
convergent-evidence check, not new information.

## Base image: Kali vs. Raspberry Pi OS

First pass of this port defaulted to vanilla Raspberry Pi OS Lite arm64,
mainly because upstream's own build notes describe official Kali image
support for P4wnP1 as having "disappeared" years ago, and the goal was to
stop depending on anything unmaintained. Worth being upfront that this was a
judgment call re-examined once it came up directly, not something re-derived
from scratch — the reasoning holds up, but the conclusion changed:

Kali now ships an actively maintained, **officially packaged** nexmon for
Raspberry Pi boards. Since **Kali 2025.1** (confirmed via
[kali.org/blog/raspberry-pi-wi-fi-glow-up](https://www.kali.org/blog/raspberry-pi-wi-fi-glow-up/)):

```sh
sudo apt install brcmfmac-nexmon-dkms firmware-nexmon
```

- `brcmfmac-nexmon-dkms` — DKMS-based `brcmfmac` driver with nexmon patches,
  auto-rebuilt against kernel updates (no more "the custom kernel branch
  stopped being ported forward" problem that killed the *original* P4wnP1
  Kali support).
- `firmware-nexmon` — nexmon-patched firmware for supported Broadcom chips.
- Officially tested on Pi 5, Pi 4 (both 32- and 64-bit), Pi 3B(+), Zero W,
  Zero 2 W. Kali's own blog post explicitly calls out Pi 4 as their
  best-performing supported board.
- Monitor mode becomes `airmon-ng start wlan0` → creates a `wlan0mon`
  interface. Kali also confirmed (checked separately) to default to
  NetworkManager on its Pi images too, same as Bookworm, so
  `build_support/pi4b/network/10-p4wnp1-unmanaged.conf` applies unchanged.

Given this toolkit's whole workflow is already Kali-based, and this removes
the single most fragile, unverified piece of the port (a hand-built,
from-source nexmon firmware patch with no CI, no maintainer, matched by hand
to a specific kernel headers version) in favor of something Kali's own team
keeps working across kernel bumps — `BASE_DISTRO=kali` is now the default in
`build-image.sh`. `BASE_DISTRO=raspios` (using
`build_support/pi4b/nexmon/build-nexmon.sh`'s from-source build) is kept for
anyone who specifically wants a non-Kali image.

**Update: `wlan0mon` is now wired into the Nexmon toggle for both mechanisms.**
Kali's DKMS nexmon is architecturally different from how P4wnP1 originally
used nexmon on Pi0W - the Pi0W firmware was a single image that P4wnP1
swapped in/out and reloaded the whole `brcmfmac` module for
(`service/wifi.go`'s `setNexmonFirmware()`, this port's earlier fix for the
previously-stubbed toggle). Kali's DKMS package instead installs one
always-on nexmon-patched firmware system-wide and exposes monitor mode as an
*additional* `wlan0mon` interface via `airmon-ng`/`iw` (`iw dev wlan0
interface add wlan0mon type monitor`), coexisting with the normal `wlan0`
P4wnP1 already manages for AP/STA - no swap-and-reload needed or possible.

`service/wifi.go`'s `setNexmon()` now unifies both: enabling tries
`createMonitorInterface()` first (cheap, non-disruptive - succeeds
immediately if nexmon firmware/driver is already active system-wide, which is
always true on `BASE_DISTRO=kali`). Only if that fails (the loaded firmware
doesn't advertise monitor-mode support - the `BASE_DISTRO=raspios` case, stock
firmware not yet swapped) does it fall back to `setNexmonFirmware(true)` +
retry the monitor-vif creation with a short backoff while `brcmfmac`
reloads and `wlan0` reappears. Disabling always drops `wlan0mon` if present,
and additionally reverts to stock firmware where that mechanism applies
(silently a no-op on Kali, where there's no separate stock/nexmon firmware
pair to revert). `DeploySettings` calls `setNexmon(newWifiSettings.Nexmon)`
instead of `setNexmonFirmware` directly now, so the existing CLI
(`--nonexmon`) and WebUI "Nexmon" toggle drive this transparently on either
base image, from one binary, without needing to know which mechanism is
actually backing it on a given board.

Not yet wired up: actually consuming `wlan0mon` for anything (KARMA-style
passive sniffing, deauth, etc.) inside P4wnP1's own feature set - today the
toggle only guarantees the interface exists/doesn't, same as running
`airmon-ng start/stop wlan0` by hand would. Using it from a HIDScript or
TriggerAction is a separate feature request.

## Explicitly not ported (and why)

| Feature | Status | Why |
|---|---|---|
| `nexmon_wifi_covert_channel` custom C2 firmware | **Not ported** | Chip-specific hand-written ARM-Thumb firmware patch against BCM43430A1's ROM; no bcm43455c0 equivalent exists anywhere; reimplementing it is firmware reverse-engineering, not porting. `dist/legacy/{hidstager.py,wifi_server.py,wifi_agent.ps1}` and `dist/scripts/wifi_covert_channel.sh` are left in the tree for reference but not installed by `build-image.sh`. |
| Standard nexmon monitor mode / injection (KARMA, deauth) | **Ported** | Upstream nexmon has a real bcm43455c0 target; see `build_support/pi4b/nexmon/build-nexmon.sh`. |
| Custom re4son kernel (patched dwc2 + brcmfmac) | **Not needed** | Both patches were only needed to work around gaps that stock mainline kernel + this port's code changes now cover (sysfs UDC state, firmware-blob swap instead of driver patch). Stock Raspberry Pi OS Bookworm kernel is the target. |

## Quickstart

```sh
# 1. Cross-compile the backend for arm64 (no special container needed)
./build_support/pi4b/build.sh

# 2. (optional) build nexmon monitor-mode firmware for BCM43455C0 - run this
#    step inside the image chroot / on the Pi itself, matching kernel headers
./build_support/pi4b/nexmon/build-nexmon.sh

# 3. Assemble a flashable image on top of stock Raspberry Pi OS Lite arm64
sudo RPI_OS_IMAGE_XZ_URL=https://downloads.raspberrypi.com/raspios_lite_arm64/images/<pick-latest>/....img.xz \
     ./build_support/pi4b/image/build-image.sh
```

## Verified vs. not yet verified

This session had a real arm64 Go toolchain (this dev box is arm64 Linux) but
**no physical Pi4B to flash and boot**. Being precise about the difference:

**Verified by actually building/reading source, in this session:**
- `go build ./cmd/P4wnP1_service/` and `./cmd/P4wnP1_cli/` succeed natively
  for `linux/arm64` with Go 1.26, after the build-tag and dependency fixes
  above — zero remaining compile errors, `go vet` shows only pre-existing
  upstream lint issues (unreachable code, printf format nits), nothing new.
- `periph.io/x/periph` v3.3.0's lack of Pi4 support, by reading its actual
  vendored source.
- `periph.io/x/host/v3`'s Pi4 (`board4B`, `bcm2711`) support, by cloning and
  reading the upstream repo source directly.
- Pi4B's ACT LED sysfs label, by reading Raspberry Pi's own device tree
  source for `bcm2711-rpi-4-b.dts`.
- bcm43455c0 nexmon patch availability, by listing `seemoo-lab/nexmon`'s repo
  tree directly.
- No cgo dependency anywhere in the tree, and a real `CGO_ENABLED=0
  GOARCH=arm64` cross-build succeeding.

**Not verified (needs real Pi4B hardware, which this session didn't have):**
- Actually booting the assembled image, dwc2 binding to a UDC in peripheral
  mode on the USB-C port, and a host OS actually enumerating the composite
  gadget (HID/RNDIS/mass storage).
- `periph.io/x/host/v3` GPIO actually toggling real pins / trigger actions
  firing off real button presses on the 40-pin header.
- The ACT LED sysfs-name fix actually lighting up the right LED.
- nexmon-patched bcm43455c0 firmware actually loading and monitor
  mode/injection actually working over the air.
- Bluetooth actually pairing/streaming (BlueZ D-Bus code is unchanged and
  should work per the same reasoning as Pi0W, but "should" isn't "verified").
- `build_support/pi4b/image/build-image.sh` end-to-end (loop-mount + chroot
  needs privileges this sandbox doesn't have and there was no benefit to
  attempting a multi-hundred-MB download with nothing to flash it onto) - it
  is syntax-checked (`bash -n`) and reviewed line-by-line, not execution-tested.

If you have real Pi4B hardware, the highest-value next step is running
`build-image.sh`, flashing the result, and working through that "not
verified" list in order — starting with USB gadget enumeration, since
everything else depends on the composite gadget actually coming up.
