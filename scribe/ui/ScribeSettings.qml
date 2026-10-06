import QtQuick

// Settings card: which languages to read, install more for this OS, behaviour, colour.
Rectangle {
    id: panel

    property var cfg: ({})
    property var installed: []          // language codes that are installed
    property string installing: ""      // code being installed right now
    property int installPct: 0
    property string installMsg: ""
    property string choiceCode: ""      // language waiting for "how do you want to install it?"
    property string choiceCmd: ""       // package manager command for it (empty if unknown)
    property string terminalCode: ""    // language whose command is running in a terminal right now
    property string pmName: ""          // e.g. "pacman"
    property string osName: ""          // e.g. "CachyOS"

    signal changeCfg(string key, var value)
    signal chooseLang(string code)
    signal cancelChoice()
    signal installLang(string code)      // direct download, no password
    signal copyCommand()
    signal runTerminal(string code)
    signal closeRequested()

    readonly property var codes: ["tur", "eng", "deu", "fra", "spa", "ita", "por", "nld", "pol", "ukr",
                                  "rus", "ara", "jpn", "kor", "chi_sim"]
    readonly property var catalog: codes.map(function (c) { return { code: c, name: ScribeStrings.s.langNames[c] }; })
    readonly property var active: (cfg.langs || "").split("+").filter(function (x) { return x !== ""; })
    readonly property var swatches: ["#8ab4f8", "#ffffff", "#81c995", "#fdd663", "#f28b82"]

    function isInstalled(code) { return installed.indexOf(code) >= 0; }
    function nameOf(code) {
        for (var i = 0; i < catalog.length; i++)
            if (catalog[i].code === code) return catalog[i].name;
        return code;
    }
    function toggleLang(code) {
        var a = active.slice();
        var i = a.indexOf(code);
        if (i >= 0) {
            if (a.length === 1) return;            // always keep one
            a.splice(i, 1);
        } else {
            a.push(code);
        }
        changeCfg("langs", a.join("+"));
    }

    width: 400
    implicitHeight: col.implicitHeight + 36
    radius: 12
    color: "#0c0c0c"
    border.width: 1
    border.color: ScribeTheme.lineStrong
    clip: true

    MouseArea { anchors.fill: parent }      // clicks on blank card areas must not reach the dismiss layer

    Column {
        id: col
        x: 18; y: 18
        width: panel.width - 36
        spacing: 14

        // header
        Item {
            width: parent.width; height: 24
            Text { text: ScribeStrings.s.settings; anchors.verticalCenter: parent.verticalCenter; font.family: ScribeTheme.mono; font.pixelSize: 14; font.weight: Font.DemiBold; color: ScribeTheme.text }
            Rectangle {
                anchors.right: parent.right
                width: 24; height: 24; radius: 12
                color: xMa.containsMouse ? "#2b2b2b" : "transparent"
                Behavior on color { ColorAnimation { duration: 100 } }
                Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 16; color: ScribeTheme.dim }
                MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.closeRequested() }
            }
        }

        // languages
        Text { text: ScribeStrings.s.readingLangs; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

        Rectangle {
            width: parent.width
            height: Math.min(listCol.implicitHeight, 232)
            radius: 8
            color: ScribeTheme.surface
            border.width: 1
            border.color: ScribeTheme.line
            clip: true

            Flickable {
                anchors.fill: parent
                contentHeight: listCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                Column {
                    id: listCol
                    width: parent.width
                    Repeater {
                        model: panel.catalog
                        delegate: Item {
                            id: row
                            required property var modelData
                            required property int index
                            readonly property bool ok: panel.isInstalled(modelData.code)
                            readonly property bool on: panel.active.indexOf(modelData.code) >= 0
                            readonly property bool busy: panel.installing === modelData.code
                            width: listCol.width
                            height: 38

                            Rectangle { visible: row.index > 0; width: parent.width; height: 1; color: ScribeTheme.line }

                            // checkbox
                            Rectangle {
                                x: 12; anchors.verticalCenter: parent.verticalCenter
                                width: 18; height: 18; radius: 4
                                opacity: row.ok ? 1 : 0.35
                                color: row.on && row.ok ? ScribeTheme.text : "transparent"
                                border.width: 1
                                border.color: row.on && row.ok ? ScribeTheme.text : ScribeTheme.lineStrong
                                Behavior on color { ColorAnimation { duration: 120 } }
                                Text {
                                    anchors.centerIn: parent
                                    visible: row.on && row.ok
                                    text: "✓"; font.pixelSize: 12; font.weight: Font.Bold; color: ScribeTheme.ink
                                }
                                MouseArea { anchors.fill: parent; enabled: row.ok; cursorShape: Qt.PointingHandCursor; onClicked: panel.toggleLang(row.modelData.code) }
                            }
                            Text {
                                x: 42; anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.name
                                font.family: ScribeTheme.mono; font.pixelSize: 13
                                color: row.ok ? ScribeTheme.text : ScribeTheme.dim
                            }
                            Text {
                                x: 150; anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.code
                                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.faint
                            }

                            // state on the right
                            Text {
                                visible: row.ok
                                anchors.right: parent.right; anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: ScribeStrings.s.installed; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.faint
                            }
                            Row {
                                visible: row.busy
                                anchors.right: parent.right; anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                Item {
                                    width: 16; height: 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    Canvas {
                                        id: spin
                                        anchors.fill: parent
                                        onPaint: {
                                            var c = getContext("2d");
                                            c.clearRect(0, 0, width, height);
                                            c.strokeStyle = "#ececec";
                                            c.lineWidth = 2;
                                            c.lineCap = "round";
                                            c.beginPath();
                                            c.arc(8, 8, 6, 0, Math.PI * 1.5);
                                            c.stroke();
                                        }
                                    }
                                    RotationAnimator on rotation { target: spin; from: 0; to: 360; duration: 800; loops: Animation.Infinite; running: row.busy }
                                }
                                Text { text: panel.installPct > 0 ? panel.installPct + "%" : "…"; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim; anchors.verticalCenter: parent.verticalCenter }
                            }
                            ScribeBarButton {
                                visible: !row.ok && !row.busy
                                compact: true
                                anchors.right: parent.right; anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                label: ScribeStrings.s.download
                                enabled: panel.installing === "" && panel.terminalCode === ""
                                opacity: enabled ? 1 : 0.4
                                onActivated: panel.chooseLang(row.modelData.code)
                            }
                        }
                    }
                }
            }
        }

        // how to install: direct download (no password) or the package manager (password)
        Rectangle {
            id: choice
            visible: panel.choiceCode !== ""
            width: parent.width
            implicitHeight: choiceCol.implicitHeight + 24
            radius: 8
            color: ScribeTheme.surface
            border.width: 1
            border.color: ScribeTheme.lineStrong
            opacity: visible ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 160 } }

            Column {
                id: choiceCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 10

                Item {
                    width: parent.width; height: 20
                    Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.howInstall(panel.nameOf(panel.choiceCode)); font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.DemiBold; color: ScribeTheme.text }
                    Text { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "×"; font.pixelSize: 16; color: ScribeTheme.dim
                        MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: panel.cancelChoice() } }
                }

                // option 1
                Rectangle {
                    width: parent.width; height: 54; radius: 8
                    color: o1.pressed ? "#2a2a2a" : (o1.containsMouse ? "#1f1f1f" : "transparent")
                    border.width: 1; border.color: o1.containsMouse ? ScribeTheme.lineStrong : ScribeTheme.line
                    scale: o1.pressed ? 0.98 : 1
                    Behavior on color { ColorAnimation { duration: 100 } }
                    Behavior on scale { NumberAnimation { duration: 80 } }
                    Column {
                        anchors.verticalCenter: parent.verticalCenter; x: 12; spacing: 3
                        Text { text: ScribeStrings.s.direct; font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.Medium; color: ScribeTheme.text }
                        Text { text: ScribeStrings.s.directHint; font.family: ScribeTheme.mono; font.pixelSize: 10; color: ScribeTheme.dim }
                    }
                    MouseArea { id: o1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.installLang(panel.choiceCode) }
                }

                // option 2
                Rectangle {
                    visible: panel.choiceCmd !== ""
                    width: parent.width
                    height: o2col.implicitHeight + 24
                    radius: 8
                    color: "transparent"
                    border.width: 1; border.color: ScribeTheme.line
                    Column {
                        id: o2col
                        x: 12; y: 12; width: parent.width - 24; spacing: 8
                        Flow {
                            width: parent.width
                            spacing: 8
                            Text { text: ScribeStrings.s.viaPm; font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.Medium; color: ScribeTheme.text }
                            Text { text: ScribeStrings.s.asksPassword; font.family: ScribeTheme.mono; font.pixelSize: 10; color: ScribeTheme.dim; topPadding: 3 }
                        }
                        Rectangle {
                            width: parent.width; height: cmdText.implicitHeight + 16; radius: 6
                            color: "#080808"; border.width: 1; border.color: ScribeTheme.line
                            Text { id: cmdText; x: 10; y: 8; width: parent.width - 20; wrapMode: Text.WrapAnywhere; text: panel.choiceCmd; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.text }
                        }
                        Row {
                            spacing: 8
                            visible: panel.terminalCode === ""
                            ScribeBarButton { compact: true; label: ScribeStrings.s.copyCommand; onActivated: panel.copyCommand() }
                            ScribeBarButton { compact: true; label: ScribeStrings.s.runTerminal; onActivated: panel.runTerminal(panel.choiceCode) }
                        }
                        Row {
                            spacing: 8
                            visible: panel.terminalCode !== ""
                            Text { text: ScribeStrings.s.terminalOpen; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim }
                        }
                    }
                }
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.Wrap
            text: panel.installMsg !== "" ? panel.installMsg
                : ScribeStrings.s.installInfo(panel.pmName || ScribeStrings.s.pmFallback, panel.osName)
            font.family: ScribeTheme.mono; font.pixelSize: 11; lineHeight: 1.4
            color: panel.installMsg !== "" ? ScribeTheme.text : ScribeTheme.faint
        }

        Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
        Text { text: ScribeStrings.s.behaviour; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

        Repeater {
            model: [
                { key: "closeAfterCopy", label: ScribeStrings.s.closeAfterCopy },
                { key: "autoCopy", label: ScribeStrings.s.autoCopy },
                { key: "joinLines", label: ScribeStrings.s.joinLines }
            ]
            delegate: Item {
                required property var modelData
                width: col.width; height: 28
                Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; font.family: ScribeTheme.mono; font.pixelSize: 13; color: ScribeTheme.text }
                ScribeSwitch {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    checked: !!panel.cfg[modelData.key]
                    onToggled: v => panel.changeCfg(modelData.key, v)
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
        Text { text: ScribeStrings.s.highlight; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

        Row {
            spacing: 10
            Repeater {
                model: panel.swatches
                delegate: Rectangle {
                    required property string modelData
                    readonly property bool sel: (panel.cfg.highlight || "").toLowerCase() === modelData
                    width: 28; height: 28; radius: 14
                    color: modelData
                    border.width: sel ? 2 : 1
                    border.color: sel ? "#ffffff" : "#3d3d3d"
                    scale: sw.pressed ? 0.9 : (sw.containsMouse ? 1.08 : 1)
                    Behavior on scale { NumberAnimation { duration: 90 } }
                    Text { anchors.centerIn: parent; visible: parent.sel; text: "✓"; font.pixelSize: 13; font.weight: Font.Bold; color: "#0a0a0a" }
                    MouseArea { id: sw; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.changeCfg("highlight", parent.modelData) }
                }
            }
        }

        Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
        Text { text: ScribeStrings.s.interfaceLang; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

        Row {
            spacing: 6
            Repeater {
                model: [ { v: "auto", t: ScribeStrings.s.auto }, { v: "tr", t: "Türkçe" }, { v: "en", t: "English" } ]
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: (panel.cfg.ui || "auto") === modelData.v
                    height: 28
                    width: uiTxt.implicitWidth + 28
                    radius: 14
                    color: sel ? ScribeTheme.text : (uiMa.containsMouse ? "#222222" : "transparent")
                    border.width: 1
                    border.color: sel ? ScribeTheme.text : ScribeTheme.line
                    scale: uiMa.pressed ? 0.95 : 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Behavior on scale { NumberAnimation { duration: 80 } }
                    Text { id: uiTxt; anchors.centerIn: parent; text: modelData.t; font.family: ScribeTheme.mono; font.pixelSize: 12; color: parent.sel ? ScribeTheme.ink : ScribeTheme.text }
                    MouseArea { id: uiMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: panel.changeCfg("ui", parent.modelData.v) }
                }
            }
        }
    }
}
