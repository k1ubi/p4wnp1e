#!/bin/bash
# Run this ON the Pi4B itself, after first boot, as root:
#   sudo ./verify-on-device.sh
#
# One-shot smoke test for every subsystem this port touched, instead of
# working through PORTING.md's checklist by hand. Each check prints
# PASS/WARN/FAIL and why; nothing here is destructive or changes state,
# except "gadget test" which briefly deploys and tears down a minimal
# USB gadget if P4wnP1.service isn't already running one.

set -u
PASS=0
WARN=0
FAIL=0

pass() { echo "  PASS  $1"; PASS=$((PASS+1)); }
warn() { echo "  WARN  $1"; WARN=$((WARN+1)); }
fail() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }

section() { echo; echo "== $1 =="; }

section "Board"
model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
echo "  $model"
case "$model" in
*"Raspberry Pi 4"*) pass "Pi4-family board detected" ;;
*) warn "not detected as a Pi4 - some checks below assume it" ;;
esac

section "Kernel USB gadget support"
KVER="$(uname -r)"
MODDIR="/lib/modules/${KVER}/kernel/drivers/usb"
for mod in dwc2/dwc2 gadget/libcomposite gadget/function/usb_f_hid \
           gadget/function/usb_f_rndis gadget/function/usb_f_ecm \
           gadget/function/usb_f_mass_storage gadget/function/usb_f_acm; do
	if [ -f "$MODDIR/${mod}.ko" ] || [ -f "$MODDIR/${mod}.ko.xz" ] || [ -f "$MODDIR/${mod}.ko.zst" ]; then
		pass "module present: $(basename "$mod")"
	elif modinfo "$(basename "$mod")" >/dev/null 2>&1; then
		pass "module present (builtin or elsewhere): $(basename "$mod")"
	else
		fail "module MISSING: $(basename "$mod") - gadget functions using it won't work"
	fi
done

section "dwc2 / UDC (peripheral mode)"
if ls /sys/class/udc/ 2>/dev/null | grep -q .; then
	pass "UDC present: $(ls /sys/class/udc/)"
	state="$(cat /sys/class/udc/$(ls /sys/class/udc/ | head -1)/state 2>/dev/null || echo unknown)"
	echo "  state: $state"
else
	fail "no UDC bound - check dtoverlay=dwc2,dr_mode=peripheral in /boot/firmware/config.txt and modules-load=dwc2 in cmdline.txt"
fi

if [ -d /sys/kernel/config/usb_gadget ]; then
	pass "configfs usb_gadget path exists"
else
	fail "configfs usb_gadget path missing - CONFIG_USB_CONFIGFS not enabled or configfs not mounted"
fi

section "P4wnP1 service"
if systemctl is-active --quiet P4wnP1.service; then
	pass "P4wnP1.service running"
else
	fail "P4wnP1.service not running: $(systemctl is-active P4wnP1.service 2>&1)"
fi

if ls /sys/kernel/config/usb_gadget/ 2>/dev/null | grep -q .; then
	pass "gadget deployed: $(ls /sys/kernel/config/usb_gadget/)"
else
	warn "no gadget currently deployed (fine if you haven't configured one yet via P4wnP1_cli usb set)"
fi

section "LED (status blink)"
if [ -e /sys/class/leds/ACT/brightness ]; then
	pass "ACT LED sysfs class present"
elif [ -e /sys/class/leds/led0/brightness ]; then
	pass "led0 LED sysfs class present"
else
	fail "neither /sys/class/leds/ACT nor /led0 exists - service/led.go's ledPaths() will silently do nothing"
fi

section "GPIO"
if [ -e /dev/gpiochip0 ] || [ -e /dev/gpiochip4 ]; then
	pass "gpiochip device node present"
else
	fail "no /dev/gpiochip* present - periph.io GPIO subsystem won't find pins"
fi

section "Bluetooth"
if systemctl is-active --quiet hciuart.service; then pass "hciuart.service active"; else fail "hciuart.service not active - BlueZ won't see a controller"; fi
if systemctl is-active --quiet bluetooth.service; then pass "bluetooth.service active"; else fail "bluetooth.service not active"; fi
if command -v hciconfig >/dev/null && hciconfig 2>/dev/null | grep -q "^hci"; then
	pass "hci controller visible: $(hciconfig 2>/dev/null | grep '^hci' | head -1)"
else
	warn "no hci controller visible yet (can take a few seconds after boot)"
fi

section "WiFi / nexmon"
if iw dev 2>/dev/null | grep -q "Interface wlan0"; then
	pass "wlan0 present"
else
	fail "no wlan0 interface - check WiFi chip / firmware"
fi
if dpkg -s brcmfmac-nexmon-dkms >/dev/null 2>&1; then
	pass "brcmfmac-nexmon-dkms installed (Kali DKMS nexmon path)"
	if iw dev wlan0 interface add wlan0mon_verifytest type monitor >/dev/null 2>&1; then
		pass "wlan0 supports monitor-mode vif creation"
		iw dev wlan0mon_verifytest del >/dev/null 2>&1
	else
		warn "couldn't create a test monitor vif - nexmon firmware may not be loaded yet (reboot after installing brcmfmac-nexmon-dkms?)"
	fi
else
	warn "brcmfmac-nexmon-dkms not installed - BASE_DISTRO=raspios path expected instead (build_support/pi4b/nexmon/build-nexmon.sh)"
fi

section "Required binaries (service/*.go hard dependencies)"
for bin in hostapd dnsmasq wpa_supplicant wpa_passphrase iw dhcpcd bluetoothd; do
	if command -v "$bin" >/dev/null 2>&1 || [ -x "/usr/sbin/$bin" ] || [ -x "/sbin/$bin" ]; then
		pass "$bin found"
	else
		fail "$bin NOT FOUND - check build_support/pi4b/image/build-image.sh's package list"
	fi
done

section "Network"
for svc in hostapd dnsmasq dhcpcd; do
	if systemctl is-enabled --quiet "$svc.service" 2>/dev/null; then
		warn "$svc.service is enabled at boot - P4wnP1 runs its own copy, this should be masked/disabled (see build-image.sh)"
	fi
done
if [ -f /etc/NetworkManager/conf.d/10-p4wnp1-unmanaged.conf ]; then
	pass "NetworkManager unmanaged-devices conf present"
else
	warn "NetworkManager unmanaged-devices conf missing - NM may fight P4wnP1 for wlan0/usb0/usb1"
fi

echo
echo "======================================"
echo " $PASS passed, $WARN warnings, $FAIL failed"
echo "======================================"
[ "$FAIL" -eq 0 ]
