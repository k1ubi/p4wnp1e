// +build linux

package service

import (
	"fmt"
	"io/ioutil"
	"strings"
	"time"

	"github.com/mame82/P4wnP1_aloa/common_web"
)

/*
Pi4B PORT NOTE
==============
Upstream used a genetlink-based watcher (mgenetlink/mnetlink, family "p4wnp1",
group "dwc2") fed by a custom, out-of-tree patch to the dwc2 kernel driver. That
patch only ever existed for one specific Pi Zero W kernel branch
(re4son-raspberrypi-linux, rpi-4.14.80-re4son-p4wnp1) and was never carried
forward (see build_support/p4wnp1_aloa_build_notes.md - "Re4son stopped porting
the modification to newer Kernels"). It also meant this file only ever compiled
with "// +build arm", so it silently didn't exist on any other GOARCH - which
means service.go (which references Dwc2ConnectWatcher unconditionally) never
actually built for arm64 upstream.

There is no equivalent patch for the Pi 4B kernel, and hand-maintaining an
out-of-tree dwc2 patch per kernel version is exactly the kind of bitrot that
killed upstream's official image builds. Mainline dwc2, through the generic
Linux UDC core (drivers/usb/gadget/udc-core.c), already exposes what we need
with zero patching:

    /sys/class/udc/<udc-name>/state

One of: "not attached", "attached", "powered", "default", "addressed",
"configured", "suspended". Present on every Pi (Zero/3/4/5/CM4) on a stock
kernel, because it's part of the generic gadget framework, not a board driver.

This replacement polls that file instead of receiving a netlink event. It's
looser on latency (bounded by dwc2PollInterval) but needs no kernel patch and
works on Pi4B (arm64) as well as Pi Zero W (arm) unchanged.
*/

const (
	dwc2PollInterval = 300 * time.Millisecond
	// "configured" == host has enumerated the gadget and selected a
	// configuration, i.e. the point at which HID/RNDIS/etc functions are
	// actually usable. Earlier states are transient parts of enumeration.
	dwc2StateConfigured = "configured"
)

type Dwc2ConnectWatcher struct {
	rootSvc *Service

	isRunning bool
	stopCh    chan struct{}
	connected bool
}

func (d *Dwc2ConnectWatcher) update(newStateConnected bool) {
	if d.connected == newStateConnected {
		return
	}
	d.connected = newStateConnected

	if d.connected {
		fmt.Println("Connected to USB host")
		d.rootSvc.SubSysEvent.Emit(ConstructEventTrigger(common_web.TRIGGER_EVT_TYPE_USB_GADGET_CONNECTED))
	} else {
		fmt.Println("Disconnected from USB host")
		d.rootSvc.SubSysEvent.Emit(ConstructEventTrigger(common_web.TRIGGER_EVT_TYPE_USB_GADGET_DISCONNECTED))
	}
}

// readUDCState reads /sys/class/udc/<udcName>/state. getUDCName() already
// exists in SubSysUSB.go and picks the (only) UDC driver bound to configfs -
// exactly the one P4wnP1's gadget is bound to.
func readUDCState() (state string, err error) {
	udcName, err := getUDCName()
	if err != nil {
		return "", err
	}

	raw, err := ioutil.ReadFile("/sys/class/udc/" + udcName + "/state")
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(raw)), nil
}

func (d *Dwc2ConnectWatcher) evt_loop() {
	ticker := time.NewTicker(dwc2PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-d.stopCh:
			fmt.Println("dwc2 connect watcher poll loop ended")
			return
		case <-ticker.C:
			state, err := readUDCState()
			if err != nil {
				// UDC not present (gadget not deployed yet, or dwc2 not bound
				// as a peripheral-mode UDC at all) - not fatal, just "disconnected".
				d.update(false)
				continue
			}
			d.update(state == dwc2StateConfigured)
		}
	}
}

func (d *Dwc2ConnectWatcher) IsConnected() bool {
	return d.connected
}

func (d *Dwc2ConnectWatcher) Start() (err error) {
	if d.isRunning {
		return nil
	}
	d.isRunning = true
	d.stopCh = make(chan struct{})

	// Prime initial state immediately, instead of waiting up to
	// dwc2PollInterval for the first tick, so a client already connected at
	// service start gets an accurate IsConnected() right away.
	if state, err := readUDCState(); err == nil {
		d.connected = state == dwc2StateConfigured
	}

	go d.evt_loop()
	return nil
}

func (d *Dwc2ConnectWatcher) Stop() error {
	if !d.isRunning {
		return nil
	}
	d.isRunning = false
	close(d.stopCh)
	return nil
}

func NewDwc2ConnectWatcher(rootSvc *Service) (d *Dwc2ConnectWatcher) {
	d = &Dwc2ConnectWatcher{
		rootSvc: rootSvc,
	}
	return d
}
