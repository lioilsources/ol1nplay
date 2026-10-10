//go:build !windows

package mediakeys

// Start is a no-op outside Windows: nothing is registered and the stop
// function does nothing.
func Start(chan<- Event) (stop func(), err error) {
	return func() {}, nil
}
