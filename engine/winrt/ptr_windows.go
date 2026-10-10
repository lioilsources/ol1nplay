//go:build windows

package winrt

import "unsafe"

func uintptrOf(p *uint32) uintptr { return uintptr(unsafe.Pointer(p)) }
