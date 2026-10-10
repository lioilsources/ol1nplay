// Package winrt holds small Windows runtime helpers the engine needs
// outside the audio path: version and elevation checks, CPU topology, and
// hiding the console window when launched from the desktop UI. Every
// function has a harmless answer on other platforms.
package winrt

import "runtime"

// ProcessorCount is the number of logical processors.
func ProcessorCount() int { return runtime.NumCPU() }

// LastCore is the index of the highest logical processor: the default
// affinity for the audio callback thread, chosen because core 0 takes most
// interrupt and DPC work.
func LastCore() int {
	n := runtime.NumCPU()
	if n < 1 {
		return 0
	}
	return n - 1
}
