import QtQuick

// Small on/off switch, white when on.
Rectangle {
    id: sw
    property bool checked: false
    signal toggled(bool value)

    width: 36
    height: 20
    radius: 10
    color: checked ? ScribeTheme.text : "#2b2b2b"
    border.width: 1
    border.color: checked ? ScribeTheme.text : "#4a4a4a"
    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on border.color { ColorAnimation { duration: 140 } }

    Rectangle {
        id: knob
        width: 14; height: 14; radius: 7
        y: 3
        x: sw.checked ? sw.width - width - 3 : 3
        color: sw.checked ? ScribeTheme.ink : "#9a9a9a"
        scale: ma.pressed ? 1.2 : 1
        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutBack; easing.overshoot: 1.4 } }
        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on scale { NumberAnimation { duration: 80 } }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled(!sw.checked)
    }
}
