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
#   - No patched brcmfmac driver needed (nexmon firmware is a *firmware blob*
#     swap, not a kernel driver patch - see build_support/pi4b/nexmon/).
#   - No custom kernel needed at all - stock Raspberry Pi OS Bookworm arm64
#     already has dwc2 configfs gadget support and Pi4B (bcm2711) support.
#
# So this script starts from the *official* Raspberry Pi OS Lite (arm64)
# image and layers P4wnP1 on top via a chroot, the same way pi-gen itself
# works, instead of building a whole OS from scratch.
#
# NOT EXECUTED IN THIS SESSION: this needs loopback mount + chroot (or
# systemd-nspawn) with root/CAP_SYS_ADMIN, a qemu-user-static binfmt
# registration if building on a non-arm64 host, and a few hundred MB of
# download - none of which make sense to run inside this sandbox (no Pi4B to
# flash the result onto, and the sandbox likely lacks loop-device
# privileges). Read it as a reviewed, ready-to-run recipe: run it on a Linux
# box (or the Pi4B itself) with sudo and internet access.
#
# Usage:
#   sudo ./build_support/pi4b/image/build-image.sh [output-dir]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_DIR="${1:-$REPO_ROOT/build_support/pi4b/image/out}"
WORK_DIR="$OUT_DIR/work"
mkdir -p "$OUT_DIR" "$WORK_DIR"

# Pin to a specific dated Raspberry Pi OS release rather than "latest" so
# builds are reproducible; bump this deliberately when you want a newer base.
# https://downloads.raspberrypi.com/raspios_lite_arm64/images/
RPI_OS_IMAGE_XZ_URL="${RPI_OS_IMAGE_XZ_URL:?Set RPI_OS_IMAGE_XZ_URL to a raspios_lite_arm64 .img.xz URL from https://downloads.raspberrypi.com/raspios_lite_arm64/images/ (pick the latest dated folder) before running this script}"

if [ "$(id -u)" -ne 0 ]; then
	echo "This script needs root (loop mount + chroot). Re-run with sudo." >&2
	exit 1
fi

echo "=== 1. Fetch base image ==="
IMG_XZ="$WORK_DIR/raspios_lite_arm64.img.xz"
IMG="$WORK_DIR/raspios_lite_arm64.img"
if [ ! -f "$IMG" ]; then
	[ -f "$IMG_XZ" ] || curl -L -o "$IMG_XZ" "$RPI_OS_IMAGE_XZ_URL"
	unxz -k -f "$IMG_XZ"
fi

echo "=== 2. Grow the image file and its root partition ==="
# Stock RPi OS images ship a rootfs sized to their own content; P4wnP1 + its
# dependencies need headroom. (First-boot auto-expand to fill the SD card
# still happens on top of this via raspberrypi-sys-mods, same as any stock
# image - we don't need to reimplement that, unlike upstream's genimg.)
truncate -s +1G "$IMG"
LOOPDEV="$(losetup --show -fP "$IMG")"
trap 'losetup -d "$LOOPDEV" 2>/dev/null || true' EXIT
parted -s "$LOOPDEV" resizepart 2 100%
e2fsck -f -y "${LOOPDEV}p2" || true
resize2fs "${LOOPDEV}p2"

echo "=== 3. Mount rootfs + boot partition ==="
ROOTFS="$WORK_DIR/rootfs"
mkdir -p "$ROOTFS"
mount "${LOOPDEV}p2" "$ROOTFS"
mount "${LOOPDEV}p1" "$ROOTFS/boot/firmware"

cleanup() {
	umount "$ROOTFS/boot/firmware" 2>/dev/null || true
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
cp -R "$REPO_ROOT/dist/legacy" "$ROOTFS/usr/local/P4wnP1/"
cp "$REPO_ROOT/build/webapp.js" "$ROOTFS/usr/local/P4wnP1/www/"
cp "$REPO_ROOT/build/webapp.js.map" "$ROOTFS/usr/local/P4wnP1/www/"
cp "$REPO_ROOT/dist/P4wnP1.service" "$ROOTFS/etc/systemd/system/P4wnP1.service"

echo "=== 7. Boot config (dwc2 peripheral mode) ==="
cat "$REPO_ROOT/build_support/pi4b/boot/config.txt.snippet" >> "$ROOTFS/boot/firmware/config.txt"
CMDLINE_FILE="$ROOTFS/boot/firmware/cmdline.txt"
if ! grep -q 'modules-load=dwc2' "$CMDLINE_FILE"; then
	sed -i 's/rootwait/rootwait modules-load=dwc2/' "$CMDLINE_FILE"
fi

echo "=== 8. NetworkManager: don't manage P4wnP1's interfaces ==="
mkdir -p "$ROOTFS/etc/NetworkManager/conf.d"
cp "$REPO_ROOT/build_support/pi4b/network/10-p4wnp1-unmanaged.conf" \
   "$ROOTFS/etc/NetworkManager/conf.d/10-p4wnp1-unmanaged.conf"

echo "=== 9. Package dependencies + service enablement (inside chroot) ==="
chroot "$ROOTFS" /usr/bin/env bash -eux <<'CHROOT_EOF'
apt-get update
# Same functional package set as the Makefile's commented-out `dep`/
# `installkali` apt-get lines, translated to current Debian/Bookworm names.
apt-get install -y --no-install-recommends \
	hostapd wpasupplicant dnsmasq iw \
	bluez bluez-tools \
	bridge-utils \
	screen tmux \
	genisoimage \
	haveged avahi-daemon \
	usbutils rfkill \
	python3 python3-pip

# hostapd/dnsmasq ship disabled-by-default on Debian; P4wnP1 launches them
# itself as subprocesses (service/wifi.go, SubSysNetworkManager.go), so mask
# the system units to avoid two copies fighting over the same config/port.
systemctl mask hostapd.service || true
systemctl mask dnsmasq.service || true

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
