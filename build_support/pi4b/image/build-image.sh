#!/bin/bash
# Build a ready-to-flash Raspberry Pi 4B image with P4wnP1 pre-installed.
#
# WHY THIS REPLACES THE OLD PIPELINE
# ===================================
# Upstream's image pipeline (build_support/rpi0w-nexmon-p4wnp1-aloa.sh) is a
# fork of kali-arm-build-scripts: debootstrap a Kali armel rootfs from
# scratch, cross-compile a whole custom kernel (Re4son's patched
# rpi-4.14.80-re4son-p4wnp1 branch, needed for the patched dwc2 + brcmfmac
# drivers), manually assemble partitions/genimg. Per the project's own build
# notes (build_support/p4wnp1_aloa_build_notes.md): "Re4son stopped porting
# the modification to newer Kernels" and "official Kali support disappeared"
# - i.e. that whole pipeline has been unmaintainable for years, independent
# of this port.
#
# None of the reasons that pipeline existed apply anymore (see PORTING.md):
#   - No patched dwc2 driver needed (service/dwc2_connect_watcher.go now polls
#     stock /sys/class/udc/*/state).
#   - No custom kernel or hand-built nexmon needed at all for BASE_DISTRO=kali
#     (see step 9) - Kali has shipped officially maintained, DKMS-based
#     nexmon packages (brcmfmac-nexmon-dkms + firmware-nexmon) covering Pi4
#     since 2025.1, confirmed against kali.org/blog/raspberry-pi-wi-fi-glow-up.
#
# BASE_DISTRO
# ===========
# kali (default)  - Kali's own official unified Raspberry Pi arm64 image.
#                    Recommended: matches the tooling this whole toolkit
#                    already assumes (wifi/bt/recon utilities, etc.), and its
#                    apt-packaged nexmon means step 9 skips a from-source
#                    firmware build entirely.
# raspios         - vanilla Raspberry Pi OS Lite arm64. Falls back to
#                    build_support/pi4b/nexmon/build-nexmon.sh (from-source
#                    nexmon) since Raspberry Pi OS doesn't package it.
#
# Both are Debian-based, both default to NetworkManager (confirmed for Kali
# too, not just Bookworm), so the rest of this script (steps 6-8) is
# distro-agnostic.
#
# NOT EXECUTED IN THIS SESSION: this needs loopback mount + chroot (or
# systemd-nspawn) with root/CAP_SYS_ADMIN, a qemu-user-static binfmt
# registration if building on a non-arm64 host, and a multi-GB download -
# none of which make sense to run inside this sandbox (no Pi4B to flash the
# result onto, and the sandbox likely lacks loop-device privileges). Read it
# as a reviewed, ready-to-run recipe: run it on a Linux box (or the Pi4B
# itself) with sudo and internet access.
#
# Usage:
#   sudo BASE_DISTRO=kali ./build_support/pi4b/image/build-image.sh [output-dir]
#   sudo BASE_DISTRO=raspios RPI_OS_IMAGE_XZ_URL=https://... ./build_support/pi4b/image/build-image.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/build_support/pi4b/image/out}"
WORK_DIR="$OUT_DIR/work"
mkdir -p "$OUT_DIR" "$WORK_DIR"

BASE_DISTRO="${BASE_DISTRO:-kali}"

case "$BASE_DISTRO" in
kali)
	# Kali publishes one unified arm64 image across Pi 2/3/4/400/5 (device
	# tree auto-detects the model at boot, same mechanism Raspberry Pi OS
	# uses). Pin a dated version rather than tracking "current" for
	# reproducible builds; bump deliberately.
	# https://www.kali.org/get-kali/#kali-arm
	KALI_VERSION="${KALI_VERSION:-2026.2}"
	IMAGE_XZ_URL="${IMAGE_XZ_URL:-https://kali.download/arm-images/kali-${KALI_VERSION}/kali-linux-${KALI_VERSION}-raspberry-pi-arm64.img.xz}"
	;;
raspios)
	IMAGE_XZ_URL="${RPI_OS_IMAGE_XZ_URL:?BASE_DISTRO=raspios needs RPI_OS_IMAGE_XZ_URL set to a raspios_lite_arm64 .img.xz URL from https://downloads.raspberrypi.com/raspios_lite_arm64/images/}"
	;;
*)
	echo "Unknown BASE_DISTRO '$BASE_DISTRO' (expected kali or raspios)" >&2
	exit 1
	;;
esac

if [ "$(id -u)" -ne 0 ]; then
	echo "This script needs root (loop mount + chroot). Re-run with sudo." >&2
	exit 1
fi

echo "=== 1. Fetch base image ($BASE_DISTRO) ==="
IMG_XZ="$WORK_DIR/base.img.xz"
IMG="$WORK_DIR/base.img"
if [ ! -f "$IMG" ]; then
	[ -f "$IMG_XZ" ] || curl -L -o "$IMG_XZ" "$IMAGE_XZ_URL"
	unxz -k -f -c "$IMG_XZ" > "$IMG"
fi

echo "=== 2. Grow the image file and its root partition ==="
# Stock images ship a rootfs sized to their own content; P4wnP1 + its
# dependencies (+ Kali's own tool footprint, if BASE_DISTRO=kali) need
# headroom. First-boot auto-expand to fill the whole SD card still happens on
# top of this via raspberrypi-sys-mods/Kali's equivalent, same as any stock
# image - no need to reimplement that, unlike upstream's genimg.
truncate -s +2G "$IMG"
LOOPDEV="$(losetup --show -fP "$IMG")"
trap 'losetup -d "$LOOPDEV" 2>/dev/null || true' EXIT
partprobe "$LOOPDEV" 2>/dev/null || true
parted -s "$LOOPDEV" resizepart 2 100%
e2fsck -f -y "${LOOPDEV}p2" || true
resize2fs "${LOOPDEV}p2"

echo "=== 3. Mount rootfs + boot partition ==="
ROOTFS="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS"
mount "${LOOPDEV}p2" "$ROOTFS"

# Boot partition mounts at /boot/firmware on current Raspberry Pi OS
# (Bookworm+) and is expected to on current Kali too (same upstream
# raspberrypi-sys-mods/bootloader lineage) - but rather than hardcode that
# assumption, detect which layout this particular rootfs actually expects.
if [ -d "$ROOTFS/boot/firmware" ]; then
	BOOT_MOUNT="$ROOTFS/boot/firmware"
else
	BOOT_MOUNT="$ROOTFS/boot"
fi
mount "${LOOPDEV}p1" "$BOOT_MOUNT"

cleanup() {
	umount "$BOOT_MOUNT" 2>/dev/null || true
	umount "$ROOTFS/dev/pts" 2>/dev/null || true
	umount "$ROOTFS/dev" 2>/dev/null || true
	umount "$ROOTFS/proc" 2>/dev/null || true
	umount "$ROOTFS/sys" 2>/dev/null || true
	umount "$ROOTFS" 2>/dev/null || true
	losetup -d "$LOOPDEV" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== 4. Prepare chroot ==="
if [ "$(uname -m)" != "aarch64" ]; then
	command -v qemu-aarch64-static >/dev/null || {
		echo "Building on a non-arm64 host needs qemu-user-static (apt-get install qemu-user-static binfmt-support)" >&2
		exit 1
	}
	cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
fi
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "=== 5. Cross-build P4wnP1 backend for arm64 ==="
( cd "$REPO_ROOT" && ./build_support/pi4b/build.sh )

echo "=== 6. Install P4wnP1 into the rootfs ==="
mkdir -p "$ROOTFS/usr/local/P4wnP1"
install -m 0755 "$REPO_ROOT/build/P4wnP1_service" "$ROOTFS/usr/local/bin/P4wnP1_service"
install -m 0755 "$REPO_ROOT/build/P4wnP1_cli" "$ROOTFS/usr/local/bin/P4wnP1_cli"
cp -R "$REPO_ROOT/dist/keymaps" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/scripts" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/HIDScripts" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/www" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/db" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/helper" "$ROOTFS/usr/local/P4wnP1/"
cp -R "$REPO_ROOT/dist/ums" "$ROOTFS/usr/local/P4wnP1/"
# dist/legacy (hidstager.py/wifi_server.py/wifi_agent.ps1) is the userspace
# side of the WiFi covert-channel feature, which needs firmware that doesn't
# exist for Pi4B's chip (see PORTING.md "Explicitly not ported") - left out
# of the image on purpose rather than installed-but-nonfunctional.
cp "$REPO_ROOT/build/webapp.js" "$ROOTFS/usr/local/P4wnP1/www/"
cp "$REPO_ROOT/build/webapp.js.map" "$ROOTFS/usr/local/P4wnP1/www/"
cp "$REPO_ROOT/dist/P4wnP1.service" "$ROOTFS/etc/systemd/system/P4wnP1.service"

echo "=== 7. Boot config (dwc2 peripheral mode) ==="
cat "$REPO_ROOT/build_support/pi4b/boot/config.txt.snippet" >> "$BOOT_MOUNT/config.txt"
CMDLINE_FILE="$BOOT_MOUNT/cmdline.txt"
if ! grep -q 'modules-load=dwc2' "$CMDLINE_FILE"; then
	sed -i 's/rootwait/rootwait modules-load=dwc2/' "$CMDLINE_FILE"
fi

echo "=== 8. NetworkManager: don't manage P4wnP1's interfaces ==="
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cp "$REPO_ROOT/build_support/pi4b/network/10-p4wnp1-unmanaged.conf" \
   "$ROOTFS/etc/NetworkManager/conf.d/10-p4wnp1-unmanaged.conf"

echo "=== 9. Package dependencies + service enablement (inside chroot) ==="
NEXMON_PACKAGES=""
if [ "$BASE_DISTRO" = "kali" ]; then
	# Officially maintained by Kali since 2025.1 - DKMS driver + patched
	# firmware for supported Broadcom chips including Pi4B's bcm43455c0.
	# Replaces build_support/pi4b/nexmon/build-nexmon.sh's from-source build
	# entirely on this base. Monitor mode is then just:
	#   airmon-ng start wlan0   (creates wlan0mon, coexists with wlan0)
	NEXMON_PACKAGES="brcmfmac-nexmon-dkms firmware-nexmon"
fi

chroot "$ROOTFS" /usr/bin/env bash -eux <<CHROOT_EOF
apt-get update
# Same functional package set as the Makefile's commented-out \`dep\`/
# \`installkali\` apt-get lines, translated to current package names.
apt-get install -y --no-install-recommends \
	hostapd wpasupplicant dnsmasq iw \
	bluez bluez-tools \
	bridge-utils \
	screen tmux \
	genisoimage \
	haveged avahi-daemon \
	usbutils rfkill \
	python3 python3-pip \
	$NEXMON_PACKAGES

# hostapd/dnsmasq ship disabled-by-default; P4wnP1 launches them itself as
# subprocesses (service/wifi.go, SubSysNetworkManager.go), so mask the
# system units to avoid two copies fighting over the same config/port.
systemctl mask hostapd.service || true
systemctl mask dnsmasq.service || true

# Bluetooth on Pi boards is UART-attached; both Kali's docs
# (kali.org/docs/arm/raspberry-pi-4) and stock Raspberry Pi OS need this
# explicitly enabled before BlueZ sees a controller at all - without it,
# service/bluetooth.go's FindFirstAvailableController() just times out.
systemctl enable hciuart.service || true
systemctl enable bluetooth.service || true

systemctl daemon-reload
systemctl enable haveged
systemctl enable avahi-daemon
systemctl enable P4wnP1.service

# libcomposite is loaded on demand by P4wnP1_service itself
# (service/SubSysUSB.go's CheckLibComposite), nothing to enable here.
CHROOT_EOF

echo "=== Done. Image assembled at $IMG ==="
echo "Compress + flash, e.g.:"
echo "  xz -T0 -k \"$IMG\""
echo "  rpi-imager --cli \"$IMG.xz\" /dev/sdX     # or: dd if=\"$IMG\" of=/dev/sdX bs=4M status=progress"
