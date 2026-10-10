//go:build !windows

package wasapi

import "github.com/ol1n/ol1nplay/engine/sink"

// Backend exists on other platforms only so that code referring to the
// concrete type compiles; New always fails and nothing is registered.
type Backend struct{}

// New returns ErrWindowsOnly.
func New() (*Backend, error) { return nil, ErrWindowsOnly }

// Name implements sink.Backend.
func (b *Backend) Name() string { return "wasapi" }

// Devices implements sink.Backend.
func (b *Backend) Devices() ([]sink.Device, error) { return nil, ErrWindowsOnly }

// Caps implements sink.Backend.
func (b *Backend) Caps(string) (sink.Caps, error) { return sink.Caps{}, ErrWindowsOnly }

// Open implements sink.Backend.
func (b *Backend) Open(string, sink.Format, int) (sink.Stream, error) { return nil, ErrWindowsOnly }

// SetAffinityCore is a no-op here.
func (b *Backend) SetAffinityCore(int) {}
