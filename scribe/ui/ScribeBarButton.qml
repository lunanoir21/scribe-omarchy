import QtQuick

// Toolbar button: hover lightens, press squeezes, a ripple spreads from the click
// point, and `done` pops a check mark in next to the label.
Rectangle {
    id: b

    property string label: ""
    property bool done: false
    property bool compact: false
    signal activated()

    height: compact ? 26 : 32
    width: row.implicitWidth + (compact ? 24 : 32)
    radius: height / 2
    clip: true
    scale: ma.pressed ? 0.94 : 1
    color: ma.pressed ? "#3a3a3a" : (ma.containsMouse ? "#2b2b2b" : "transparent")

    Behavior on color { ColorAnimation { duration: 100 } }
    Behavior on scale { NumberAnimation { duration: 80; easing.type: Easing.OutQuad } }
    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    // ripple
    Rectangle {
        id: rip
        property real cx: 0
        property real cy: 0
        x: cx - width / 2
        y: cy - height / 2
        width: 0
        height: width
        radius: width / 2
        color: "#ffffff"
        opacity: 0
    }
    ParallelAnimation {
        id: ripAnim
        NumberAnimation { target: rip; property: "width"; from: 0; to: b.width * 2.4; duration: 420; easing.type: Easing.OutCubic }
        NumberAnimation { target: rip; property: "opacity"; from: 0.32; to: 0; duration: 420; easing.type: Easing.OutQuad }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 8

        Text {
            visible: b.done
            anchors.verticalCenter: parent.verticalCenter
            text: "✓"
            font.family: ScribeTheme.mono
            font.pixelSize: 13
            font.weight: Font.Bold
            color: ScribeTheme.text
            scale: b.done ? 1 : 0.3
            Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 2.2 } }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: b.label
            font.family: ScribeTheme.mono
            font.pixelSize: b.compact ? 12 : 13
            font.weight: Font.Medium
            color: ScribeTheme.text
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => {
            rip.cx = mouse.x;
            rip.cy = mouse.y;
            ripAnim.restart();
        }
        onClicked: b.activated()
    }
}
