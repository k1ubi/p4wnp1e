# changelog

## Raspberry Pi 4B port (pi4b-port)

- added: full port to Raspberry Pi 4B (arm64) - see `PORTING.md` for the
  complete writeup, `build_support/pi4b/` for build/image/nexmon tooling
- fix: backend (`P4wnP1_service`/`P4wnP1_cli`) didn't compile for any
  architecture except armv6 - build tags were `linux,arm`, broadened to
  `linux` (5 files: `service.go`, `bluetooth.go`, `datastore/store.go`,
  `P4wnP1_service.go`, `testhid.go`)
- fix: USB connect/disconnect watcher (`dwc2_connect_watcher.go`) required an
  out-of-tree dwc2 kernel patch that no longer exists on any current kernel;
  replaced with polling the standard `/sys/class/udc/*/state` file
- fix: GPIO subsystem (`periph.io/x/periph` v3.3.0) hard-errors on every Pi4
  board revision code; migrated to `periph.io/x/{conn,host}/v3`
- fix: status LED hardcoded `/sys/class/leds/led0`, which doesn't exist on
  Pi4B (its device tree names it `ACT`) - errors were silently discarded, so
  this failed with zero indication; now probes both
- fix: the WiFi "Nexmon" toggle (`WiFiSettings.nexmon`, `--nonexmon`, the
  WebUI toggle) was fully wired through the API but was a dead
  `//ToDo` stub - never actually did anything at runtime; implemented for
  both the firmware-swap-and-reload mechanism (Raspberry Pi OS +
  `build_support/pi4b/nexmon`) and Kali's DKMS nexmon (creates/destroys a
  `wlan0mon` monitor interface)
- fix: `dhcpcd` binary dependency (`service/dhcp.go`'s DHCP client mode, e.g.
  WiFi STA joining a network) missing from the image's package list on both
  Bookworm and Kali, which default to NetworkManager and don't install it -
  added, with its systemd service disabled so it doesn't fight P4wnP1's
  on-demand invocation
- fix: `haveged` was being enabled unnecessarily on Pi4B, which has a real
  hardware RNG (`bcm2711-rng200`) that Pi0W lacked; no longer enabled,
  matching Kali's own current Pi4/5 build
- fix: `build-image.sh` wrote `config.txt`/`cmdline.txt` and the
  NetworkManager conf *before* running `apt-get install` in the chroot;
  reordered to write them last, since a boot-firmware package's postinst
  regenerating those files during install would otherwise silently clobber
  the edits
- removed: `mgenetlink` (793 lines combined with `mnetlink` before this),
  confirmed genuinely unused anywhere in the tree or its dependencies after
  the dwc2 watcher rewrite - checked by removing it and running a full
  `go build ./...` + `go mod tidy`, not just grepping this repo's own
  `.go` files (which is exactly what missed that `mnetlink`, unlike
  `mgenetlink`, is still a real transitive dependency of `service/bluetooth.go`
  via the external `mblue-toolz` library - restored immediately once that
  build failure surfaced it)
- added: minimal CI (`.github/workflows/build.yml`) - cross-compiles the
  backend for arm64, runs `go vet`, syntax-checks every shell script, on
  every push/PR to `pi4b-port`

## v0.1.1-beta

- fix #81: 100 percent CPU load in WiFI STA mode
- fix: Italian layout `it`
- fix: UK layout `gb`
- fix: French layout `fr`
- fix #38: file permission
- added Finnish `fi` and Swedish `sv` layout (same)
- added German(Switzerland) layout `ch`
- added French(Belgian) layout `be`
