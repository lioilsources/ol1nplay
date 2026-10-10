// Package mediakeys delivers the keyboard's media keys (play/pause, next,
// previous, stop) to the engine. On Windows they are global hot keys
// (RegisterHotKey); elsewhere nothing is registered.
package mediakeys

// Event is one media key press.
type Event int

// Media key events.
const (
	PlayPause Event = iota + 1
	Next
	Prev
	Stop
)

func (e Event) String() string {
	switch e {
	case PlayPause:
		return "play/pause"
	case Next:
		return "next"
	case Prev:
		return "prev"
	case Stop:
		return "stop"
	}
	return "unknown"
}
