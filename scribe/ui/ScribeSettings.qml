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
    property var tr: null               // ScribeTranslator (offline pack status and actions)
    property real maxHeight: 700        // the card scrolls when it would be taller than the screen
    property bool confirmEnable: false  // the "before you enable it" card is showing

    // Shows the card and scrolls it into view, so its Enable and Cancel buttons are not below the fold.
    function showEnableCard() {
        confirmEnable = true;
        scrollToCard.restart();
    }

    // the card has its height only after the layout ran, so scroll a moment later
    Timer {
        id: scrollToCard
        interval: 80
        onTriggered: {
            var y = enableCard.mapToItem(col, 0, 0).y;
            flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, y - 24));
        }
    }

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


    // a row of choices, the picked one inverted
    component Choice: Flow {
        id: ch
        property var options: []        // [{ v, t }]
        property string current: ""
        signal picked(string v)
        width: parent ? parent.width : 300
        spacing: 6
        Repeater {
            model: ch.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool sel: ch.current === modelData.v
                height: 28
                width: chTxt.implicitWidth + 28
                radius: 14
                color: sel ? ScribeTheme.text : (chMa.containsMouse ? "#222222" : "transparent")
                border.width: 1
                border.color: sel ? ScribeTheme.text : ScribeTheme.line
                scale: chMa.pressed ? 0.95 : 1
                Behavior on color { ColorAnimation { duration: 120 } }
                Behavior on scale { NumberAnimation { duration: 80 } }
                Text { id: chTxt; anchors.centerIn: parent; text: modelData.t; font.family: ScribeTheme.mono; font.pixelSize: 12; color: parent.sel ? ScribeTheme.ink : ScribeTheme.text }
                MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ch.picked(parent.modelData.v) }
            }
        }
    }

    readonly property var trLangCodes: ["tr", "en", "de", "fr", "es", "it", "pt", "ru", "nl", "pl", "ar", "ja", "ko", "zh"]
    function trLangOptions(withAuto) {
        var o = withAuto ? [{ v: "auto", t: ScribeStrings.s.tlNames.auto }] : [];
        for (var i = 0; i < trLangCodes.length; i++) o.push({ v: trLangCodes[i], t: ScribeStrings.s.tlNames[trLangCodes[i]] });
        return o;
    }

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
    implicitHeight: Math.min(flick.contentHeight, maxHeight)
    radius: 12
    color: "#0c0c0c"
    border.width: 1
    border.color: ScribeTheme.lineStrong
    clip: true

    MouseArea { anchors.fill: parent }      // clicks on blank card areas must not reach the dismiss layer

    Flickable {
    id: flick
    anchors.fill: parent
    contentWidth: width
    contentHeight: col.implicitHeight + 36
    boundsBehavior: Flickable.StopAtBounds
    clip: true

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
                { key: "joinLines", label: ScribeStrings.s.joinLines },
                { key: "smartActions", label: ScribeStrings.s.smartActions }
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
        Text { text: ScribeStrings.s.translation; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

        // master switch: nothing is downloaded, loaded or run for translation while it is off
        Item {
            width: col.width; height: 28
            Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.enableTranslate; font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.DemiBold; color: ScribeTheme.text }
            ScribeSwitch {
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                checked: !!panel.cfg.translate
                onToggled: v => { if (v) panel.showEnableCard(); else { panel.confirmEnable = false; panel.changeCfg("translate", false); } }
            }
        }

        // asked before the first activation: what it downloads, sends and keeps in memory
        Rectangle {
            id: enableCard
            visible: panel.confirmEnable && !panel.cfg.translate
            width: parent.width
            height: enCol.implicitHeight + 24
            radius: 8
            color: "transparent"
            border.width: 1
            border.color: ScribeTheme.text
            Column {
                id: enCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 8
                Row {
                    spacing: 8
                    Rectangle {
                        width: 18; height: 18; radius: 9
                        color: ScribeTheme.text
                        anchors.verticalCenter: parent.verticalCenter
                        Text { anchors.centerIn: parent; text: "!"; font.family: ScribeTheme.mono; font.pixelSize: 12; font.weight: Font.Bold; color: ScribeTheme.ink }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: ScribeStrings.s.enableWarnTitle
                        font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.text
                    }
                }
                Repeater {
                    model: [ScribeStrings.s.enableNet, ScribeStrings.s.enableMem, ScribeStrings.s.enableDisk, ScribeStrings.s.enableAcc, ScribeStrings.s.enableOff]
                    delegate: Text {
                        required property string modelData
                        width: enCol.width; wrapMode: Text.Wrap; lineHeight: 1.4
                        text: modelData
                        font.family: ScribeTheme.mono; font.pixelSize: 11; color: "#cfcfcf"
                    }
                }
                Row {
                    spacing: 8
                    ScribeBarButton { compact: true; label: ScribeStrings.s.enableConfirm; onActivated: { panel.confirmEnable = false; panel.changeCfg("translate", true); } }
                    ScribeBarButton { compact: true; label: ScribeStrings.s.giveUp; onActivated: panel.confirmEnable = false }
                }
            }
        }

        Column {
            id: transBody
            visible: !!panel.cfg.translate
            width: parent.width
            spacing: 14
        Item {
                width: transBody.width; height: 28
                Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.autoTranslate; font.family: ScribeTheme.mono; font.pixelSize: 13; color: ScribeTheme.text }
                ScribeSwitch {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    checked: !!panel.cfg.autoTranslate
                    onToggled: v => panel.changeCfg("autoTranslate", v)
                }
            }

            Text { text: ScribeStrings.s.resultView; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }
            Choice {
                options: [{ v: "card", t: ScribeStrings.s.viewCard }, { v: "inplace", t: ScribeStrings.s.viewInplace }]
                current: panel.cfg.tView || "card"
                onPicked: v => panel.changeCfg("tView", v)
            }

            Text { text: ScribeStrings.s.engine; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }
            Choice {
                options: [{ v: "offline", t: ScribeStrings.s.engineOffline }, { v: "online", t: ScribeStrings.s.engineOnline }]
                current: panel.cfg.tEngine || "offline"
                onPicked: v => panel.changeCfg("tEngine", v)
            }

            Text { text: ScribeStrings.s.targetLang; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }
            Choice {
                options: panel.trLangOptions(false)
                current: panel.cfg.tTarget || "tr"
                onPicked: v => panel.changeCfg("tTarget", v)
            }

            Item {
                width: transBody.width; height: 28
                Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.allowOnline; font.family: ScribeTheme.mono; font.pixelSize: 13; color: ScribeTheme.text }
                ScribeSwitch {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    checked: !!panel.cfg.tOnline
                    onToggled: v => panel.changeCfg("tOnline", v)
                }
            }

            Column {
                width: parent.width
                spacing: 4
                Text { text: ScribeStrings.s.onlineEmail; font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.text }
                Rectangle {
                    width: parent.width; height: 30; radius: 6
                    color: "#080808"; border.width: 1; border.color: mailInput.activeFocus ? ScribeTheme.lineStrong : ScribeTheme.line
                    TextInput {
                        id: mailInput
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.text
                        selectionColor: "#5a5a5a"
                        text: panel.cfg.tEmail || ""
                        onEditingFinished: if (text !== (panel.cfg.tEmail || "")) panel.changeCfg("tEmail", text.trim())
                    }
                }
                Text { width: parent.width; wrapMode: Text.Wrap; text: ScribeStrings.s.onlineEmailHint; font.family: ScribeTheme.mono; font.pixelSize: 10; color: ScribeTheme.faint }
            }

            Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
            Text { text: ScribeStrings.s.features; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

            Repeater {
                model: [
                    { key: "dictionary", label: ScribeStrings.s.dictionary },
                    { key: "editable", label: ScribeStrings.s.editable }
                ]
                delegate: Item {
                    required property var modelData
                    width: transBody.width; height: 28
                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.label; font.family: ScribeTheme.mono; font.pixelSize: 13; color: ScribeTheme.text }
                    ScribeSwitch {
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        checked: !!panel.cfg[modelData.key]
                        onToggled: v => panel.changeCfg(modelData.key, v)
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
            Text { text: ScribeStrings.s.offlineTitle; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }

            Text {
                width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.4
                text: ScribeStrings.s.offlineInfo
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.faint
            }

            Text {
                width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.4
                text: ScribeStrings.s.offlineCaveat
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: "#cfcfcf"
            }

            Rectangle {
                width: parent.width
                height: warnCol.implicitHeight + 24
                radius: 8
                color: "transparent"
                border.width: 1
                border.color: ScribeTheme.lineStrong
                Column {
                    id: warnCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 6
                    Row {
                        spacing: 8
                        Rectangle {
                            width: 18; height: 18; radius: 9
                            color: ScribeTheme.text
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; text: "!"; font.family: ScribeTheme.mono; font.pixelSize: 12; font.weight: Font.Bold; color: ScribeTheme.ink }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: ScribeStrings.s.memWarnTitle
                            font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.text
                        }
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.4
                        text: ScribeStrings.s.memWarn
                        font.family: ScribeTheme.mono; font.pixelSize: 11; color: "#cfcfcf"
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        visible: panel.tr !== null && panel.tr.off !== null && panel.tr.off.daemon && panel.tr.off.rss_mb !== null
                        text: panel.tr && panel.tr.off && panel.tr.off.rss_mb !== null ? ScribeStrings.s.memNow(panel.tr.off.rss_mb) : ""
                        font.family: ScribeTheme.mono; font.pixelSize: 11; font.weight: Font.DemiBold; color: ScribeTheme.text
                    }
                }
            }

            Rectangle {
                visible: panel.tr !== null
                width: parent.width
                height: offCol.implicitHeight + 24
                radius: 8
                color: ScribeTheme.surface
                border.width: 1; border.color: ScribeTheme.line
                Column {
                    id: offCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 8
                    Text {
                        text: !panel.tr || panel.tr.off === null ? ScribeStrings.s.offlineChecking
                            : panel.tr.offlineReady ? ScribeStrings.s.offlineReady
                            : panel.tr.offlinePartial ? ScribeStrings.s.offlinePartial : ScribeStrings.s.offlineMissing
                        font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.DemiBold; color: ScribeTheme.text
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        visible: panel.tr !== null && panel.tr.off !== null && panel.tr.off.pairs.length > 0
                        text: panel.tr && panel.tr.off
                            ? panel.tr.off.pairs.map(function (p) { var a = p.split("-"); return ScribeStrings.s.tlNames[a[0]] + " → " + ScribeStrings.s.tlNames[a[1]]; }).join(", ")
                              + "  ·  " + ScribeStrings.s.diskUse(panel.tr.off.size_mb)
                              + "  ·  " + (panel.tr.off.daemon ? ScribeStrings.s.serviceUp : ScribeStrings.s.serviceIdle)
                            : ""
                        font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim
                    }
                    Rectangle {
                        width: parent.width; height: 4; radius: 2
                        visible: panel.tr !== null && panel.tr.installing
                        color: "#2b2b2b"
                        Rectangle {
                            height: parent.height; radius: 2
                            width: parent.width * Math.max(0.02, (panel.tr ? panel.tr.installPct : 0) / 100)
                            color: ScribeTheme.text
                            Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                        }
                    }
                    Text {
                        width: parent.width; wrapMode: Text.Wrap
                        visible: panel.tr !== null && (panel.tr.installing || panel.tr.installError !== "")
                        text: panel.tr ? (panel.tr.installError !== "" ? panel.tr.installError : panel.tr.installMsg) : ""
                        font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.text
                    }
                    Row {
                        spacing: 8
                        ScribeBarButton {
                            compact: true
                            enabled: panel.tr !== null && !panel.tr.installing
                            opacity: enabled ? 1 : 0.4
                            label: panel.tr && panel.tr.offlineReady ? ScribeStrings.s.reinstallOffline : ScribeStrings.s.installOffline
                            onActivated: panel.tr.installOffline()
                        }
                        ScribeBarButton {
                            compact: true
                            visible: panel.tr !== null && panel.tr.off !== null && panel.tr.off.size_mb > 0
                            enabled: panel.tr !== null && !panel.tr.installing
                            opacity: enabled ? 1 : 0.4
                            label: ScribeStrings.s.removeOffline
                            onActivated: panel.tr.removeOffline()
                        }
                    }
                }
            }

        }

        Rectangle { width: parent.width; height: 1; color: ScribeTheme.line }
        Text { text: ScribeStrings.s.scanAnim; font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim }
        Choice {
            options: ["line", "rows", "shine", "pixels", "ring", "focus"].map(function (k) { return { v: k, t: ScribeStrings.s.scanNames[k] }; })
            current: panel.cfg.scanAnim || "line"
            onPicked: v => panel.changeCfg("scanAnim", v)
        }
        Rectangle {
            width: parent.width; height: 76; radius: 6
            color: "#161616"; border.width: 1; border.color: ScribeTheme.line
            clip: true
            Column {
                x: 14; y: 12; spacing: 6
                Repeater {
                    model: [150, 190, 120]
                    delegate: Rectangle { required property int modelData; width: modelData; height: 10; radius: 2; color: "#ffffff"; opacity: 0.22 }
                }
            }
            ScribeScanFx {
                anchors.fill: parent
                kind: panel.cfg.scanAnim || "line"
                accent: panel.cfg.highlight || "#8ab4f8"
                running: panel.visible && panel.opacity > 0.5
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
}
