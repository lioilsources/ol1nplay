// Package deps pins the module graph so that `go mod tidy` keeps every
// dependency the engine will use, even while a package that imports it is
// still being written. Remove an import here once a real package uses it.
package deps

import (
	_ "github.com/fsnotify/fsnotify"
	_ "github.com/gorilla/websocket"
	_ "github.com/grandcat/zeroconf"
	_ "github.com/skip2/go-qrcode"
	_ "golang.org/x/image/draw"
	_ "golang.org/x/sys/cpu"
	_ "modernc.org/sqlite"
)
