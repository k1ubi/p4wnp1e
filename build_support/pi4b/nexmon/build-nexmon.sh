#!/bin/bash
# Build a nexmon monitor-mode/injection-capable firmware for the Pi4B's WiFi
# chip, to be installed as an alternate /lib/firmware/brcm/brcmfmac43455-sdio.bin
# and toggled on/off exactly like the Pi0W images did (P4wnP1_cli wifi set ap
# --nonexmon / with nexmon, see service/wifi.go and dist/scripts/servicestart.sh).
#
# ONLY NEEDED FOR BASE_DISTRO=raspios. If you're building on Kali (the
# default in build_support/pi4b/image/build-image.sh), skip this script
# entirely: Kali has shipped officially maintained DKMS-based nexmon packages
# since 2025.1 (brcmfmac-nexmon-dkms + firmware-nexmon, confirmed against
# kali.org/blog/raspberry-pi-wi-fi-glow-up), which cover Pi4B's bcm43455c0
# out of the box via `apt install` - no from-source firmware build, and no
# DKMS-vs-kernel-version maintenance burden on you. This script exists for
# people who specifically want a vanilla Raspberry Pi OS image instead.
#
# WHAT CHANGED FROM THE PI0W BUILD (build_support/rpi0w-nexmon-p4wnp1-aloa.sh)
# ==============================================================================
# Pi0W's WiFi chip is a Broadcom BCM43430A1 (patches/bcm43430a1/7_45_41_46 in
# nexmon). Pi4B's WiFi chip is a different chip entirely: BCM43455C0
# (same chip family as Pi3B+/CM4/Zero2W). Upstream nexmon
# (https://github.com/seemoo-lab/nexmon) DOES carry proper patch directories
# for bcm43455c0 - confirmed by listing the repo tree directly rather than
# assuming:
#
#   patches/bcm43455c0/7_45_206/nexmon/{monitormode,injection,sendframe,ioctl,console,patch}.c
#   patches/bcm43455c0/7_45_241/...
#   firmwares/bcm43455c0/7_45_206/brcmfmac43455-sdio.bin  (stock firmware to patch)
#
# So standard monitor mode + raw frame injection is portable to Pi4B using
# nexmon in the ordinary way - no chip-specific reverse engineering needed
# for that part.
#
# WHAT DID NOT COME ALONG: mame82's "wifi_covert_channel" feature
# =================================================================
# The upstream Pi0W build clones a *fork* of nexmon -
# https://github.com/mame82/nexmon_wifi_covert_channel (branch p4wnp1) - which
# adds a bespoke, hand-written covert C2 channel on top of the standard
# bcm43430a1/7_45_41_46 patch (see dist/scripts/wifi_covert_channel.sh,
# dist/legacy/{hidstager.py,wifi_server.py,wifi_agent.ps1} for the userspace
# side of that feature). That's original ARM-Thumb firmware-patch code mame82
# wrote against BCM43430A1's specific ROM layout/offsets. It was never ported
# to any other chip, by mame82 or anyone else, and there is no equivalent in
# upstream nexmon for bcm43455c0.
#
# Porting that specific feature would mean reverse-engineering the bcm43455c0
# ROM and re-implementing the covert channel's firmware-side logic from
# scratch (finding free RAM, hooking the right ioctl/console paths, etc.) -
# real firmware reverse-engineering work, not a mechanical "change the chip
# name" port. That's out of scope here; see PORTING.md's "Explicitly not
# ported" section. Standard nexmon monitor-mode/injection (KARMA-style attacks,
# deauth, raw 802.11 capture) is what this script gets you; the covert channel
# is not.
#
# This script is meant to run *inside* the Pi4B image-build chroot (see
# build_support/pi4b/image/build-image.sh), where `uname -r` and the kernel
# headers match the actual target kernel. It has not been executed in this
# session (no Pi4B hardware attached, and firmware-patch builds need to be
# built against the exact target kernel's brcmfmac source, which only exists
# meaningfully inside that chroot) - treat it as a reviewed, ready-to-run
# recipe, not as something already validated end-to-end. Cross-check the
# firmware version directory (7_45_206 below) still exists upstream and still
# matches your target kernel's stock brcmfmac43455-sdio.bin before relying on
# it; nexmon requires the *stock* firmware being patched to match the patch's
# assumed base bytes.

set -euo pipefail

NEXMON_FW_VERSION="${NEXMON_FW_VERSION:-7_45_206}"
WORKDIR="${WORKDIR:-$(pwd)/nexmon-build}"

echo "=== Building nexmon (bcm43455c0, firmware ${NEXMON_FW_VERSION}) for Pi4B ==="

mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -d nexmon ]; then
	git clone https://github.com/seemoo-lab/nexmon.git --depth 1
fi
cd nexmon

# nexmon's own setup: builds host-side tools (nexutil, makecsv, etc.) and
# fetches the ARM cross toolchain used to build the firmware patch itself.
source setup_env.sh
make

cd patches/bcm43455c0/"${NEXMON_FW_VERSION}"/nexmon
make clean || true
make

OUT="$WORKDIR/nexmon/patches/bcm43455c0/${NEXMON_FW_VERSION}/nexmon/brcmfmac43455-sdio.bin"
if [ ! -f "$OUT" ]; then
	echo "Build did not produce $OUT - check the make output above." >&2
	exit 1
fi

DEST="${DEST:-/lib/firmware/brcm}"
mkdir -p "$DEST"
install -m 0644 "$OUT" "$DEST/brcmfmac43455-sdio.nexmon.bin"

# Keep the stock firmware around too, so switching back
# (`P4wnP1_cli wifi set ap --nonexmon`) is a straight file copy, same
# convention as the Pi0W image (brcmfmac43430-sdio.rpi.bin there).
STOCK_FW="/lib/firmware/brcm/brcmfmac43455-sdio.bin"
if [ -f "$STOCK_FW" ] && [ ! -f "$DEST/brcmfmac43455-sdio.rpi.bin" ]; then
	cp "$STOCK_FW" "$DEST/brcmfmac43455-sdio.rpi.bin"
fi

echo
echo "Installed nexmon firmware to $DEST/brcmfmac43455-sdio.nexmon.bin"
echo "Stock firmware backed up to  $DEST/brcmfmac43455-sdio.rpi.bin"
echo "service/wifi.go's nexmon toggle (see NexmonEnable/-- nonexmon in cmd_wifi.go)"
echo "expects to cp one of these over $STOCK_FW and reload brcmfmac - verify the"
echo "exact swap logic still matches file names on your target kernel before relying on it."
