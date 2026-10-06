pragma Singleton
import QtQuick

// Monochrome on purpose: no accent colour. Emphasis is inversion (light on dark
// becomes dark on light) and weight, never hue.
QtObject {
    readonly property color bg: "#0a0a0a"
    readonly property color surface: "#111111"
    readonly property color raised: "#181818"
    readonly property color line: "#2b2b2b"
    readonly property color lineStrong: "#5a5a5a"
    readonly property color text: "#ececec"
    readonly property color dim: "#8c8c8c"
    readonly property color faint: "#5a5a5a"
    readonly property color ink: "#0a0a0a"

    readonly property string mono: "JetBrains Mono"
    readonly property int radius: 8

    // Same curve as Hyprland's `myBezier`.
    readonly property var curve: [0.05, 0.9, 0.1, 1.05, 1, 1]
}
