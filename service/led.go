package service

import(
	"os"
	"log"
	"io/ioutil"
	"time"
	"sync/atomic"

	pb "github.com/mame82/P4wnP1_aloa/proto"
)

const (
	LED_TRIGGER_MANUAL = "none"
	LED_ON = "0"
	LED_OFF = "1"
	LED_DELAY_ON = 200 * time.Millisecond
	LED_DELAY_OFF = 200 * time.Millisecond
	LED_DELAY_PAUSE = 500 * time.Millisecond
)

// Pi4B PORT NOTE: upstream hardcoded /sys/class/leds/led0, which is Pi Zero
// W's (and older boards') sysfs name for the green ACT LED. Pi4B's device
// tree labels it "ACT" instead (confirmed against raspberrypi/linux's
// bcm283x-rpi-led-deprecated.dtsi: `led_act: led-act { label = "ACT"; ...}`,
// included by bcm2711-rpi-4-b.dts) - so it shows up as /sys/class/leds/ACT,
// not led0. Some Raspberry Pi OS releases add a udev compat symlink from ACT
// to led0 and some don't; rather than depend on that, try both names in
// priority order and use whichever actually exists on this board.
var ledCandidateNames = []string{"led0", "ACT"}

func ledPaths() (triggerPath, brightnessPath string) {
	for _, name := range ledCandidateNames {
		base := "/sys/class/leds/" + name
		if _, err := os.Stat(base); err == nil {
			return base + "/trigger", base + "/brightness"
		}
	}
	// Fall back to the historical default; NewLed()'s writes will just fail
	// (and be logged) if no known ACT LED class device exists on this board.
	return "/sys/class/leds/led0/trigger", "/sys/class/leds/led0/brightness"
}

var LED_TRIGGER_PATH, LED_BRIGHTNESS_PATH = ledPaths()


type LedState struct {
	blink_count *uint32
}
/*
var (
	blink_count uint32 = 0
)
*/
func NewLed(led_on bool) (ledState *LedState, err error) {
	blinkCount := uint32(0)
	ledState = &LedState{ &blinkCount }

	//set trigger of LED to manual
	log.Println("Setting LED to manual trigger ...")
	ioutil.WriteFile(LED_TRIGGER_PATH, []byte(LED_TRIGGER_MANUAL), os.ModePerm)
	if led_on {
		log.Println("Setting LED to ON ...")
		ioutil.WriteFile(LED_BRIGHTNESS_PATH, []byte(LED_ON), os.ModePerm)
	} else {
		log.Println("Setting LED to OFF ...")
		ioutil.WriteFile(LED_BRIGHTNESS_PATH, []byte(LED_OFF), os.ModePerm)
	}

	go ledState.led_loop() // watcher loop

	ledState.SetLed(GetDefaultLEDSettings()) //set default setting
	return ledState,nil
}

func (leds *LedState) led_loop() {
	
	for {
		for i := uint32(0); i < atomic.LoadUint32(leds.blink_count); i++ {
			ioutil.WriteFile(LED_BRIGHTNESS_PATH, []byte(LED_ON), os.ModePerm)
			time.Sleep(LED_DELAY_ON)
			
			//Don't turn off led if blink_count >= 255 (solid)
			if 255 > atomic.LoadUint32(leds.blink_count) {
				ioutil.WriteFile(LED_BRIGHTNESS_PATH, []byte(LED_OFF), os.ModePerm)
				time.Sleep(LED_DELAY_OFF)
			}
		}
		time.Sleep(LED_DELAY_PAUSE)
	}
}

func (leds *LedState) SetLed(s *pb.LEDSettings) (error) {
	//log.Printf("setLED called with %+v", s)
	
	atomic.StoreUint32(leds.blink_count, s.BlinkCount)
	
	return nil
}

func (leds *LedState) GetLed() (res *pb.LEDSettings, err error) {
	return &pb.LEDSettings{BlinkCount: atomic.LoadUint32(leds.blink_count)}, nil
}

