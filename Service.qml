import QtQuick
import Quickshell
import "./scribe/ui" as Scribe

// Omarchy entry point for the "service" kind. Scribe owns its own layer-shell window (one
// full-screen overlay, created when you press the key and destroyed when you close it),
// so the host only has to exist once. Start it with a key:
//   qs ipc call scribe start
Scope {
    Scribe.ScribeHost {}
}
