import QtQuick

// What the translation looks like on top of the read region. Two views, picked in the settings
// (`tView`): "card" (original | translation side by side, the original can be corrected) and
// "inplace" (the translation is painted over the text itself). Plus the cards for a missing
// offline pack, the online consent and the install progress, the smart-action buttons and the
// dictionary bubble.
//
// Monochrome like the rest of scribe: the active item is inverted (light on dark becomes dark on
// light), nothing uses a hue. Motion reuses the lens' own numbers: 140-260 ms, OutCubic/OutBack.
Item {
    id: view

    property var tr                          // ScribeTranslator
    property rect rect: Qt.rect(0, 0, 0, 0)  // the read region, screen px
    property var words: []                   // [{ t, x, y, w, h }] relative to `rect`
    property bool hintShown: false           // the lens' own hint pill sits under the region
    property bool dismissed: false           // the user closed the card; the lens stays
    property string sessionView: ""          // "card" forced by Edit
    property bool showOriginal: false
    property string flash: ""

    signal closeOverlay()
    signal copyText(string text)
    signal entityCopied()

    readonly property string viewMode: sessionView !== "" ? sessionView : (tr.cfg.tView || "card")
    readonly property bool cardShown: tr.status === "ready" && !dismissed && viewMode === "card"
    readonly property bool dockShown: tr.status === "ready" && !dismissed && viewMode === "inplace"
    readonly property bool coverShown: dockShown && tr.hasTranslation && !showOriginal
    readonly property bool stateShown: tr.status === "nomodel" || tr.status === "consent" || tr.status === "installing"
    readonly property bool chipsAlone: tr.status === "idle" && tr.entities.length > 0 && tr.cfg.smartActions
    readonly property real kx: 1.0

    function langName(c) { return ScribeStrings.s.tlNames[c] || String(c).toUpperCase(); }

    function clampX(x, w) { return Math.max(10, Math.min(view.width - w - 10, x)); }
    // under the region if it fits, else above it, else pinned to the bottom edge
    function placeY(h, extraBelow) {
        var below = rect.y + rect.height + 12 + (extraBelow || 0);
        if (below + h + 10 <= view.height) return below;
        var above = rect.y - h - 12;
        if (above >= 10) return above;
        return Math.max(10, view.height - h - 12);
    }

    function copy(t, note) {
        view.copyText(t);
        flash = note || ScribeStrings.s.copied;
        flashTimer.restart();
    }
    Timer { id: flashTimer; interval: 1400; onTriggered: view.flash = "" }

    function pairLabel() { return langName(tr.needSrc) + " → " + langName(tr.needTgt); }
    readonly property bool pairOk: (tr.needSrc + "-" + tr.needTgt) === "en-tr" || (tr.needSrc + "-" + tr.needTgt) === "tr-en"

    // a new read or a closed lens starts from a clean slate
    Connections {
        target: view.tr
        function onStatusChanged() { if (view.tr.status === "idle") { view.dismissed = false; view.sessionView = ""; view.showOriginal = false; } }
    }

    // ── shared pieces ────────────────────────────────────
    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool primary: false
        signal activated()
        height: 30
        width: txt.implicitWidth + 28
        radius: 15
        color: primary ? (ma.pressed ? "#cfcfcf" : (ma.containsMouse ? "#ffffff" : ScribeTheme.text))
                       : (ma.pressed ? "#3a3a3a" : (ma.containsMouse ? "#2b2b2b" : "transparent"))
        border.width: primary ? 0 : 1
        border.color: "#3d3d3d"
        scale: ma.pressed ? 0.95 : 1
        Behavior on color { ColorAnimation { duration: 100 } }
        Behavior on scale { NumberAnimation { duration: 80 } }
        Text {
            id: txt
            anchors.centerIn: parent
            text: b.label
            font.family: ScribeTheme.mono; font.pixelSize: 12; font.weight: Font.Medium
            color: b.primary ? ScribeTheme.ink : ScribeTheme.text
        }
        MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.activated() }
    }

    component Chip: Rectangle {
        id: c
        property string label: ""
        property bool inverted: false
        height: 26
        width: ct.implicitWidth + 22
        radius: 13
        color: inverted ? ScribeTheme.text : "transparent"
        border.width: inverted ? 0 : 1
        border.color: "#3d3d3d"
        Text {
            id: ct
            anchors.centerIn: parent
            text: c.label
            font.family: ScribeTheme.mono; font.pixelSize: 11; font.weight: Font.Medium
            color: c.inverted ? ScribeTheme.ink : ScribeTheme.text
        }
    }

    component Spinner: Item {
        id: sp
        width: 16; height: 16
        property bool running: true
        Canvas {
            id: arc
            anchors.fill: parent
            onPaint: {
                var c = getContext("2d");
                c.clearRect(0, 0, width, height);
                c.strokeStyle = "#ececec"; c.lineWidth = 2; c.lineCap = "round";
                c.beginPath(); c.arc(8, 8, 6, 0, Math.PI * 1.5); c.stroke();
            }
        }
        RotationAnimator { target: arc; from: 0; to: 360; duration: 800; loops: Animation.Infinite; running: sp.running && sp.visible }
    }

    // links, e-mail, phone and IBAN found in the text
    component Entities: Flow {
        spacing: 6
        visible: view.tr.entities.length > 0 && view.tr.cfg.smartActions
        Repeater {
            model: view.tr.entities
            delegate: Rectangle {
                id: ent
                required property var modelData
                height: 26
                width: er.implicitWidth + 22
                radius: 13
                color: em.pressed ? "#3a3a3a" : (em.containsMouse ? "#2b2b2b" : "transparent")
                border.width: 1
                border.color: "#3d3d3d"
                Behavior on color { ColorAnimation { duration: 100 } }
                Row {
                    id: er
                    anchors.centerIn: parent
                    spacing: 6
                    Text { text: view.tr.entityMark(ent.modelData); font.family: ScribeTheme.mono; font.pixelSize: 11; font.weight: Font.Bold; color: ScribeTheme.dim; anchors.verticalCenter: parent.verticalCenter }
                    Text { text: view.tr.entityLabel(ent.modelData); font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.text; anchors.verticalCenter: parent.verticalCenter }
                }
                MouseArea {
                    id: em
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (view.tr.runEntity(ent.modelData)) {
                            view.closeOverlay();
                        } else {
                            view.flash = ScribeStrings.s.copied;
                            flashTimer.restart();
                            view.entityCopied();
                        }
                    }
                }
            }
        }
    }

    // hover over a text edit → dictionary lookup of the word under the pointer
    function hoverEdit(edit, mx, my, side) {
        var pos = edit.positionAt(mx, my);
        var r = tr.wordRange(edit.text, pos);
        if (!r || r.end - r.start < 2) { tr.leaveWord(); return; }
        var r0 = edit.positionToRectangle(r.start);
        var r1 = edit.positionToRectangle(r.end);
        var sameLine = Math.abs(r0.y - r1.y) < r0.height / 2;
        var x1 = sameLine ? r1.x : edit.width;
        if (my < r0.y || my > r0.y + r0.height || mx < r0.x - 2 || (sameLine && mx > x1 + 2)) { tr.leaveWord(); return; }
        var tl = edit.mapToItem(view, r0.x, r0.y);
        tr.setHover(edit.text.substring(r.start, r.end), side, Qt.rect(tl.x, tl.y, Math.max(8, x1 - r0.x), r0.height));
    }

    // ── chips on their own (translation not asked for yet) ──
    Item {
        id: chipsOnly
        visible: view.chipsAlone
        width: Math.min(640, view.width - 40)
        height: chipsFlow.implicitHeight
        x: view.clampX(view.rect.x, width)
        y: view.placeY(height, view.hintShown ? 40 : 0)
        Entities { id: chipsFlow; width: parent.width }
        Text {
            visible: view.flash !== ""
            anchors.right: parent.right
            anchors.top: chipsFlow.bottom
            anchors.topMargin: 6
            text: "✓ " + view.flash
            font.family: ScribeTheme.mono; font.pixelSize: 11; font.weight: Font.DemiBold; color: ScribeTheme.text
        }
    }

    // ── state cards: missing pack, consent, install ──────
    Rectangle {
        id: sbox
        visible: opacity > 0
        opacity: view.stateShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        width: 380
        height: sCol.implicitHeight + 28
        radius: 14
        color: "#0c0c0c"
        border.width: 1
        border.color: ScribeTheme.lineStrong
        x: view.clampX(view.rect.x, width)
        property real baseY: view.placeY(height)
        y: baseY + (1 - opacity) * 12 * (baseY > view.rect.y ? 1 : -1)
        z: 2
        MouseArea { anchors.fill: parent }

        Column {
            id: sCol
            x: 16; y: 14
            width: parent.width - 32
            spacing: 10
            Text {
                width: parent.width; wrapMode: Text.Wrap
                text: view.tr.status === "installing" ? ScribeStrings.s.installingTitle
                    : view.tr.status === "consent" ? ScribeStrings.s.consentTitle
                    : view.pairOk ? ScribeStrings.s.noModelTitle(view.pairLabel()) : ScribeStrings.s.unsupportedTitle
                font.family: ScribeTheme.mono; font.pixelSize: 13; font.weight: Font.DemiBold; color: ScribeTheme.text
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.35
                visible: view.tr.status !== "installing"
                text: view.tr.status === "consent" ? ScribeStrings.s.consentBody
                    : view.pairOk ? ScribeStrings.s.noModelBody : ScribeStrings.s.unsupportedBody
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim
            }
            Rectangle {
                width: parent.width; height: 4; radius: 2
                visible: view.tr.status === "installing"
                color: "#2b2b2b"
                Rectangle {
                    height: parent.height; radius: 2
                    width: parent.width * Math.max(0.02, view.tr.installPct / 100)
                    color: ScribeTheme.text
                    Behavior on width { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: view.tr.status === "installing"
                text: view.tr.installMsg
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim
            }
            Flow {
                width: parent.width; spacing: 8
                Btn { visible: view.tr.status === "nomodel" && view.pairOk; label: ScribeStrings.s.install; primary: true; onActivated: view.tr.installOffline() }
                Btn { visible: view.tr.status === "nomodel"; label: ScribeStrings.s.useOnline; onActivated: view.tr.useOnline() }
                Btn { visible: view.tr.status === "nomodel"; label: ScribeStrings.s.close; onActivated: view.tr.closeCard() }
                Btn { visible: view.tr.status === "consent"; label: ScribeStrings.s.sendOnce; primary: true; onActivated: view.tr.sendOnce() }
                Btn { visible: view.tr.status === "consent"; label: ScribeStrings.s.allowAlways; onActivated: view.tr.allowAlways() }
                Btn { visible: view.tr.status === "consent"; label: ScribeStrings.s.giveUp; onActivated: view.tr.giveUp() }
                Btn { visible: view.tr.status === "installing"; label: ScribeStrings.s.cancel; onActivated: view.tr.cancelInstall() }
            }
        }
    }

    // ── card: original | translation ─────────────────────
    Rectangle {
        id: card
        visible: opacity > 0
        opacity: view.cardShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        width: Math.min(view.width - 20, Math.max(540, Math.min(view.rect.width + 40, 760)))
        height: cardCol.implicitHeight + 32
        radius: 14
        color: "#0c0c0c"
        border.width: 1
        border.color: ScribeTheme.lineStrong
        x: view.clampX(view.rect.x, width)
        property real baseY: view.placeY(height)
        y: baseY + (1 - opacity) * 12 * (baseY > view.rect.y ? 1 : -1)
        z: 2
        MouseArea { anchors.fill: parent }

        Column {
            id: cardCol
            x: 16; y: 16
            width: parent.width - 32
            spacing: 12

            // header: languages, status, close
            Item {
                width: parent.width; height: 28
                Row {
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter
                    Chip { label: view.langName(view.tr.srcLang) + ((view.tr.cfg.tSource || "auto") === "auto" ? " · " + ScribeStrings.s.detected : "") }
                    Btn {
                        visible: view.tr.hasTranslation
                        label: "⇄"; height: 26
                        onActivated: view.tr.swap()
                    }
                    Chip { label: view.langName(view.tr.tgtLang); inverted: true }
                }
                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: view.flash !== "" ? view.flash
                            : view.tr.translating ? ScribeStrings.s.translating
                            : view.tr.hasTranslation ? (view.tr.engineUsed === "offline" ? ScribeStrings.s.local : ScribeStrings.s.online)
                                                      + " · " + (view.tr.tookMs / 1000).toFixed(1) + " " + ScribeStrings.s.sec
                            : ""
                        font.family: ScribeTheme.mono; font.pixelSize: 11
                        color: view.flash !== "" ? ScribeTheme.text : ScribeTheme.dim
                    }
                    Rectangle {
                        width: 24; height: 24; radius: 12
                        color: xMa.containsMouse ? "#2b2b2b" : "transparent"
                        Behavior on color { ColorAnimation { duration: 100 } }
                        Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 16; color: ScribeTheme.dim }
                        MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: view.dismissed = true }
                    }
                }
            }

            // two columns
            Row {
                id: cols
                width: parent.width
                spacing: 12
                readonly property real colW: (width - (trBox.visible ? spacing : 0)) / (trBox.visible ? 2 : 1)

                Rectangle {
                    id: origBox
                    width: cols.colW
                    height: origInner.implicitHeight + 28
                    radius: 8
                    color: ScribeTheme.surface
                    border.width: 1; border.color: ScribeTheme.line
                    Column {
                        id: origInner
                        x: 14; y: 14
                        width: parent.width - 28
                        spacing: 8
                        Text {
                            text: view.tr.cfg.editable ? ScribeStrings.s.originalEditable : ScribeStrings.s.original
                            font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.dim
                        }
                        Item {
                            width: parent.width
                            height: Math.min(origEdit.contentHeight, 200)
                            Flickable {
                                id: origFlick
                                anchors.fill: parent
                                contentHeight: origEdit.contentHeight
                                clip: true; boundsBehavior: Flickable.StopAtBounds
                                TextEdit {
                                    id: origEdit
                                    width: origFlick.width
                                    wrapMode: TextEdit.Wrap
                                    readOnly: !view.tr.cfg.editable
                                    selectByMouse: true
                                    selectionColor: "#5a5a5a"
                                    selectedTextColor: ScribeTheme.text
                                    color: "#cfcfcf"
                                    font.family: ScribeTheme.mono; font.pixelSize: 13
                                    onTextChanged: { if (text !== view.tr.original) view.tr.edited(text); }
                                    Component.onCompleted: text = view.tr.original
                                    Connections {
                                        target: view.tr
                                        function onOriginalChanged() { if (origEdit.text !== view.tr.original) origEdit.text = view.tr.original; }
                                    }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                z: 5
                                hoverEnabled: true; acceptedButtons: Qt.NoButton
                                onPositionChanged: m => { var p = mapToItem(origEdit, m.x, m.y); view.hoverEdit(origEdit, p.x, p.y, "orig"); }
                                onExited: view.tr.leaveWord()
                            }
                        }
                    }
                }

                Rectangle {
                    id: trBox
                    visible: view.tr.hasTranslation || view.tr.translating || view.tr.trError !== ""
                    width: cols.colW
                    height: trInner.implicitHeight + 28
                    radius: 8
                    color: ScribeTheme.surface
                    border.width: 1; border.color: ScribeTheme.line
                    Column {
                        id: trInner
                        x: 14; y: 14
                        width: parent.width - 28
                        spacing: 8
                        Text {
                            text: view.langName(view.tr.tgtLang).toUpperCase()
                            font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.4; font.weight: Font.DemiBold; color: ScribeTheme.text
                        }
                        Text {
                            width: parent.width; wrapMode: Text.Wrap
                            visible: view.tr.trError !== ""
                            text: view.tr.trError
                            font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.dim
                        }
                        Item {
                            width: parent.width
                            visible: view.tr.trError === ""
                            opacity: view.tr.translating ? 0.4 : 1
                            Behavior on opacity { NumberAnimation { duration: 140 } }
                            height: Math.min(Math.max(trEdit.contentHeight, 20), 200)
                            Flickable {
                                id: trFlick
                                anchors.fill: parent
                                contentHeight: trEdit.contentHeight
                                clip: true; boundsBehavior: Flickable.StopAtBounds
                                TextEdit {
                                    id: trEdit
                                    width: trFlick.width
                                    text: view.tr.translated
                                    wrapMode: TextEdit.Wrap
                                    readOnly: true
                                    selectByMouse: true
                                    selectionColor: "#5a5a5a"
                                    selectedTextColor: ScribeTheme.text
                                    color: ScribeTheme.text
                                    font.family: ScribeTheme.mono; font.pixelSize: 14; font.weight: Font.Medium
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                z: 5
                                hoverEnabled: true; acceptedButtons: Qt.NoButton
                                onPositionChanged: m => { var p = mapToItem(trEdit, m.x, m.y); view.hoverEdit(trEdit, p.x, p.y, "tr"); }
                                onExited: view.tr.leaveWord()
                            }
                        }
                    }
                }
            }

            Entities { width: parent.width }

            // actions
            Item {
                width: parent.width; height: 30
                Row {
                    spacing: 8
                    Btn {
                        visible: !view.tr.hasTranslation && !view.tr.translating
                        label: ScribeStrings.s.translate; primary: true
                        onActivated: view.tr.start()
                    }
                    Btn {
                        visible: view.tr.hasTranslation
                        label: ScribeStrings.s.copyTranslation; primary: true
                        onActivated: view.copy(view.tr.translated, ScribeStrings.s.copied)
                    }
                    Btn { label: ScribeStrings.s.copyOriginal; onActivated: view.copy(view.tr.original, ScribeStrings.s.copied) }
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    visible: view.tr.cfg.dictionary
                    text: ScribeStrings.s.dictHint
                    font.family: ScribeTheme.mono; font.pixelSize: 10; color: ScribeTheme.faint
                }
            }
        }
    }

    // ── in place: the translation over the text ──────────
    Rectangle {
        id: cover
        visible: opacity > 0
        opacity: view.coverShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        x: view.rect.x - 4; y: view.rect.y - 4
        width: view.rect.width + 8; height: view.rect.height + 8
        radius: 4
        color: "#0a0a0a"
        border.width: 1; border.color: "#ffffff"
        z: 1
        MouseArea { anchors.fill: parent }

        // first guess for the type size: the height of the lines that were read
        readonly property real startPx: {
            var ws = view.words;
            if (!ws || ws.length === 0) return 16;
            var sum = 0;
            for (var i = 0; i < ws.length; i++) sum += ws[i].h;
            return Math.max(10, Math.min(34, (sum / ws.length) * 0.95));
        }
        // Text.Fit finds the largest size at which the translation still fits the region
        Text {
            id: fit
            visible: false
            x: 8; y: 6
            width: cover.width - 16; height: cover.height - 12
            text: view.tr.translated
            wrapMode: Text.Wrap
            fontSizeMode: Text.Fit
            minimumPixelSize: 9
            font.family: ScribeTheme.mono
            font.pixelSize: cover.startPx
        }
        TextEdit {
            id: coverEdit
            x: 8; y: 6
            width: cover.width - 16; height: cover.height - 12
            text: view.tr.translated
            readOnly: true; selectByMouse: true
            wrapMode: TextEdit.Wrap
            verticalAlignment: TextEdit.AlignVCenter
            selectionColor: "#5a5a5a"
            selectedTextColor: ScribeTheme.text
            color: ScribeTheme.text
            font.family: ScribeTheme.mono
            font.pixelSize: fit.fontInfo.pixelSize
        }
        MouseArea {
            anchors.fill: parent
            z: 5
            hoverEnabled: true; acceptedButtons: Qt.NoButton
            onPositionChanged: m => { var p = mapToItem(coverEdit, m.x, m.y); view.hoverEdit(coverEdit, p.x, p.y, "tr"); }
            onExited: view.tr.leaveWord()
        }
    }

    // control capsule under the region (in place)
    Item {
        id: dock
        visible: opacity > 0
        opacity: view.dockShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        width: Math.max(dockCol.implicitWidth, 10)
        height: dockCol.implicitHeight
        x: view.clampX(view.rect.x, width)
        property real baseY: view.placeY(height + 4)
        y: baseY + (1 - opacity) * 12 * (baseY > view.rect.y ? 1 : -1)
        z: 2

        Column {
            id: dockCol
            spacing: 8
            Entities { width: Math.min(640, view.width - 40) }
            Rectangle {
                height: 40
                width: dockRow.implicitWidth + 12
                radius: 20
                color: "#1b1b1b"
                border.width: 1; border.color: "#3d3d3d"
                MouseArea { anchors.fill: parent }
                Row {
                    id: dockRow
                    anchors.centerIn: parent
                    spacing: 6

                    // translation | original switch
                    Row {
                        visible: view.tr.hasTranslation
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                            height: 28; width: dA.implicitWidth + 24; radius: 14
                            color: !view.showOriginal ? ScribeTheme.text : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text { id: dA; anchors.centerIn: parent; text: view.langName(view.tr.tgtLang); font.family: ScribeTheme.mono; font.pixelSize: 12; font.weight: Font.Medium; color: !view.showOriginal ? ScribeTheme.ink : ScribeTheme.dim }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: view.showOriginal = false }
                        }
                        Rectangle {
                            height: 28; width: dO.implicitWidth + 24; radius: 14
                            color: view.showOriginal ? ScribeTheme.text : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }
                            Text { id: dO; anchors.centerIn: parent; text: ScribeStrings.s.originalBtn; font.family: ScribeTheme.mono; font.pixelSize: 12; font.weight: Font.Medium; color: view.showOriginal ? ScribeTheme.ink : ScribeTheme.dim }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: view.showOriginal = true }
                        }
                    }
                    Row {
                        visible: view.tr.translating
                        spacing: 8
                        anchors.verticalCenter: parent.verticalCenter
                        leftPadding: 10
                        Spinner { anchors.verticalCenter: parent.verticalCenter }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.translating; font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.text }
                    }
                    Btn {
                        visible: !view.tr.hasTranslation && !view.tr.translating
                        label: ScribeStrings.s.translate; primary: true; height: 28
                        onActivated: view.tr.start()
                    }
                    Btn {
                        height: 28
                        label: view.flash !== "" ? view.flash : ScribeStrings.s.copy
                        onActivated: view.tr.hasTranslation && !view.showOriginal
                                     ? view.copy(view.tr.translated, ScribeStrings.s.copied)
                                     : view.copy(view.tr.original, ScribeStrings.s.copied)
                    }
                    Btn {
                        visible: view.tr.cfg.editable
                        height: 28
                        label: ScribeStrings.s.edit
                        onActivated: view.sessionView = "card"
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24; height: 24; radius: 12
                        color: dxMa.containsMouse ? "#2b2b2b" : "transparent"
                        Text { anchors.centerIn: parent; text: "×"; font.pixelSize: 16; color: ScribeTheme.dim }
                        MouseArea { id: dxMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: view.dismissed = true }
                    }
                }
            }
        }
    }

    // ── dictionary bubble ────────────────────────────────
    Rectangle {
        id: dict
        z: 5
        visible: opacity > 0
        opacity: view.tr.dictShown && view.tr.hoverWord !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 140 } }
        width: Math.min(320, Math.max(140, dCol.implicitWidth + 28))
        height: dCol.implicitHeight + 24
        radius: 12
        color: "#0c0c0c"
        border.width: 1; border.color: ScribeTheme.lineStrong
        x: view.clampX(view.tr.hoverRect.x + view.tr.hoverRect.width / 2 - width / 2, width)
        readonly property bool above: view.tr.hoverRect.y - height - 10 >= 6
        y: above ? view.tr.hoverRect.y - height - 10 : view.tr.hoverRect.y + view.tr.hoverRect.height + 10

        MouseArea {
            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onEntered: view.tr.keepDict()
            onExited: view.tr.leaveWord()
            onClicked: if (view.tr.dictData && view.tr.dictData.ok) view.copy(view.tr.dictData.text, ScribeStrings.s.copied)
        }

        Column {
            id: dCol
            x: 14; y: 12
            width: parent.width - 28
            spacing: 6
            Text { width: parent.width; elide: Text.ElideRight; text: view.tr.hoverWord; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim }
            Row {
                visible: view.tr.dictLoading
                spacing: 8
                Spinner { anchors.verticalCenter: parent.verticalCenter }
                Text { anchors.verticalCenter: parent.verticalCenter; text: ScribeStrings.s.dictSearching; font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.dim }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: !view.tr.dictLoading && view.tr.dictData !== null && view.tr.dictData.ok === true
                text: view.tr.dictData && view.tr.dictData.ok ? view.tr.dictData.text : ""
                font.family: ScribeTheme.mono; font.pixelSize: 18; font.weight: Font.Bold; color: ScribeTheme.text
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: !view.tr.dictLoading && view.tr.dictData !== null && view.tr.dictData.ok === true && view.tr.dictData.same === true
                text: ScribeStrings.s.dictSame
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim
            }
            Flow {
                width: parent.width; spacing: 6
                visible: !view.tr.dictLoading && view.tr.dictData !== null && view.tr.dictData.ok === true && view.tr.dictData.alts.length > 0
                Repeater {
                    model: view.tr.dictData && view.tr.dictData.ok ? view.tr.dictData.alts : []
                    delegate: Rectangle {
                        id: alt
                        required property string modelData
                        height: 22; width: at.implicitWidth + 16; radius: 11
                        color: "transparent"; border.width: 1; border.color: "#3d3d3d"
                        Text { id: at; anchors.centerIn: parent; text: alt.modelData; font.family: ScribeTheme.mono; font.pixelSize: 11; color: "#cfcfcf" }
                    }
                }
            }
            Text {
                width: parent.width; wrapMode: Text.Wrap
                visible: !view.tr.dictLoading && view.tr.dictData !== null && view.tr.dictData.ok !== true
                text: view.tr.dictData ? (view.tr.dictData.code === "online_blocked" ? ScribeStrings.s.dictBlocked
                                         : view.tr.dictData.code === "no_model" ? ScribeStrings.s.dictNoModel
                                         : view.tr.errText(view.tr.dictData.code, "")) : ""
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim
            }
        }
    }
}
