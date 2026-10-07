import QtQuick
import Quickshell
import Quickshell.Wayland

// One full-screen window for the whole flow, so nothing is created or torn down
// between steps:  select (drag a region) -> reading (sweep) -> result.
// Result behaves like Google Lens: the original text stays as it is, you drag over
// it to select, a small toolbar floats above the selection and copies on click.
PanelWindow {
    id: win

    property string shot: ""
    property string phase: "select"     // select | reading | result
    property var words: []              // [{ t, x, y, w, h, par, line }] relative to `rect`, logical px
    property string status: "ok"        // ok | low | empty | nolang
    property int confidence: 0
    property bool autoSelect: false     // copy everything as soon as the read finishes
    property bool joinLines: true
    property bool closeAfterCopy: true
    property color highlight: "#8ab4f8"
    property rect rect: Qt.rect(0, 0, 0, 0)
    property string devSel: ""         // dev only: pre-select "lo,hi" after the read
    property var devDrag: null         // dev only: show a region as if it were being dragged

    // settings panel
    property var cfg: ({})
    property var installed: []
    property string installing: ""
    property int installPct: 0
    property string installMsg: ""
    property string pmName: ""
    property string osName: ""
    property string choiceCode: ""
    property string choiceCmd: ""
    property string terminalCode: ""
    property bool settingsOpen: false
    // picking a scan animation in the settings replays it over the region on screen for a moment
    property bool previewScan: false
    property string lastScanAnim: ""
    onCfgChanged: {
        var a = (cfg && cfg.scanAnim) || "line";
        if (lastScanAnim !== "" && a !== lastScanAnim && phase === "result" && settingsOpen) {
            previewScan = true;
            previewScanTimer.restart();
        }
        lastScanAnim = a;
    }
    Timer { id: previewScanTimer; interval: 2600; onTriggered: win.previewScan = false }
    property var tr: null                // ScribeTranslator: translation, dictionary, smart actions
    signal translateRequested(string text)
    signal chooseLang(string code)
    signal cancelChoice()
    signal copyCommand()
    signal runTerminal(string code)
    signal setCfg(string key, var value)
    signal installLang(string code)
    signal settingsOpened()

    signal picked(real x, real y, real w, real h, real scale)
    signal cancelled()
    signal copyText(string text, int count)

    anchors { top: true; left: true; right: true; bottom: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    visible: img.status === Image.Ready

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    WlrLayershell.namespace: "scribe-lens"

    // ── region drag state ────────────────────────────────
    property real sx: 0
    property real sy: 0
    property real ex: 0
    property real ey: 0
    property real mx: -1
    property real my: -1
    property bool dragging: false
    property bool has: false

    readonly property real rx: phase === "select" ? Math.min(sx, ex) : rect.x
    readonly property real ry: phase === "select" ? Math.min(sy, ey) : rect.y
    readonly property real rw: phase === "select" ? Math.abs(ex - sx) : rect.width
    readonly property real rh: phase === "select" ? Math.abs(ey - sy) : rect.height

    // ── text selection state ─────────────────────────────
    property int anchorIdx: -1
    property int selLo: -1
    property int selHi: -1
    property int hoverIdx: -1
    property bool wordDrag: false
    property bool copied: false
    property var selRects: []           // merged per-line highlight boxes, relative to `rect`
    property rect selBox: Qt.rect(0, 0, 0, 0)   // bounding box in screen px
    property string hint: ""

    function setSel(lo, hi) {
        selLo = lo;
        selHi = hi;
        copied = false;
        var rs = [], cur = null;
        if (lo >= 0) {
            for (var i = lo; i <= hi; i++) {
                var w = words[i];
                if (cur && cur.line === w.line) {
                    cur.r = Math.max(cur.r, w.x + w.w);
                    cur.t = Math.min(cur.t, w.y);
                    cur.b = Math.max(cur.b, w.y + w.h);
                } else {
                    if (cur) rs.push(cur);
                    cur = { line: w.line, l: w.x, t: w.y, r: w.x + w.w, b: w.y + w.h };
                }
            }
            if (cur) rs.push(cur);
        }
        selRects = rs;
        if (rs.length) {
            var l = 1e9, t = 1e9, r = -1e9, b = -1e9;
            for (var k = 0; k < rs.length; k++) {
                l = Math.min(l, rs[k].l); t = Math.min(t, rs[k].t);
                r = Math.max(r, rs[k].r); b = Math.max(b, rs[k].b);
            }
            selBox = Qt.rect(rect.x + l, rect.y + t, r - l, b - t);
        }
    }

    // one box per text line, for the brief "text found" flash
    readonly property var lineBoxes: {
        var out = [], cur = null;
        for (var i = 0; i < words.length; i++) {
            var w = words[i];
            if (cur && cur.line === w.line) {
                cur.r = Math.max(cur.r, w.x + w.w);
                cur.t = Math.min(cur.t, w.y);
                cur.b = Math.max(cur.b, w.y + w.h);
            } else {
                if (cur) out.push(cur);
                cur = { line: w.line, l: w.x, t: w.y, r: w.x + w.w, b: w.y + w.h };
            }
        }
        if (cur) out.push(cur);
        return out;
    }

    function selectAll() { setSel(0, words.length - 1); }

    // dev only (reached through ScribeHost's flag-file guarded IPC helpers)
    function devEnableCard() { settingsOpen = true; settingsPanel.showEnableCard(); }
    function devHoverWord(i) {
        if (!tr || i < 0 || i >= words.length) return;
        var w = words[i];
        tr.setHover(tr.trimNonLetters(w.t), "orig", Qt.rect(rect.x + w.x, rect.y + w.y, w.w, w.h));
    }

    // the word under the pointer opens the dictionary bubble (not while dragging a selection, and
    // not while the translation is painted over the text)
    onHoverIdxChanged: {
        if (!tr || !tr.cfg.dictionary || phase !== "result") return;
        if (hoverIdx >= 0 && hoverIdx < words.length && !wordDrag && !tview.coverShown) {
            var w = words[hoverIdx];
            tr.setHover(tr.trimNonLetters(w.t), "orig", Qt.rect(rect.x + w.x, rect.y + w.y, w.w, w.h));
        } else {
            tr.leaveWord();
        }
    }

    // the Translate button under the region: reopen a closed translation, or ask for a new one
    function openTranslation() {
        if (!tr || !tr.enabled) return;
        if (tr.status === "ready" && tr.hasTranslation) { tview.dismissed = false; return; }
        translateSelection();
    }

    function translateSelection() {
        if (words.length === 0 || !tr || !tr.enabled) return;
        var lo = selLo >= 0 ? selLo : 0, hi = selLo >= 0 ? selHi : words.length - 1;
        tview.dismissed = false;
        translateRequested(tr.paragraphs(words, lo, hi));
    }

    function textFor(lo, hi) {
        var out = "", prev = null;
        for (var i = lo; i <= hi; i++) {
            var w = words[i];
            if (prev)
                out += (w.line === prev.line) ? " " : ((w.par === prev.par && joinLines) ? " " : "\n");
            out += w.t;
            prev = w;
        }
        return out;
    }

    function doCopy() {
        if (words.length === 0)
            return;
        if (selLo < 0)
            selectAll();
        var n = selHi - selLo + 1;
        copyText(textFor(selLo, selHi), n);
        copied = true;
        if (closeAfterCopy)
            closeTimer.restart();
    }

    function hit(px, py) {
        if (hoverIdx >= 0 && hoverIdx < words.length) {
            var h = words[hoverIdx];
            if (px >= h.x - 3 && px <= h.x + h.w + 3 && py >= h.y - 2 && py <= h.y + h.h + 2)
                return hoverIdx;
        }
        for (var i = 0; i < words.length; i++) {
            var w = words[i];
            if (px >= w.x - 3 && px <= w.x + w.w + 3 && py >= w.y - 2 && py <= w.y + w.h + 2)
                return i;
        }
        return -1;
    }

    // while dragging, snap to the closest word so gaps between words don't break the range
    function nearest(px, py) {
        var best = -1, bd = 1e9;
        for (var i = 0; i < words.length; i++) {
            var w = words[i];
            var dx = Math.max(w.x - px, 0, px - (w.x + w.w));
            var dy = Math.max(w.y - py, 0, py - (w.y + w.h));
            var d = dx * dx + dy * dy;
            if (d < bd) { bd = d; best = i; }
        }
        return bd < 2500 ? best : -1;
    }

    Timer { id: closeTimer; interval: 750; onTriggered: win.cancelled() }
    Timer { id: hintTimer; interval: 2600; onTriggered: win.hint = "" }

    function applyDevDrag() {
        if (devDrag && phase === "select") {
            sx = devDrag.x; sy = devDrag.y;
            ex = devDrag.x + devDrag.w; ey = devDrag.y + devDrag.h;
            mx = ex; my = ey;
            has = true;
        }
    }
    onDevDragChanged: applyDevDrag()
    Component.onCompleted: applyDevDrag()

    onPhaseChanged: {
        if (phase !== "result")
            return;
        setSel(-1, -1);
        flash.restart();
        if (status === "ok") {
            if (autoSelect) {
                selectAll();
                doCopy();
            } else {
                hint = ScribeStrings.s.dragHint;
                hintTimer.restart();
            }
        } else if (status === "low") {
            hint = ScribeStrings.s.lowConf(confidence);
        } else if (status === "empty") {
            hint = ScribeStrings.s.noText;
        } else {
            hint = ScribeStrings.s.noLang;
        }
        if (devSel !== "" && words.length > 0) {
            var p = devSel.split(",");
            setSel(Math.min(parseInt(p[0]), words.length - 1), Math.min(parseInt(p[1]), words.length - 1));
        }
    }

    FocusScope {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: { if (win.settingsOpen) win.settingsOpen = false; else win.cancelled(); }
        Keys.onPressed: ev => {
            if (win.phase !== "result" || win.words.length === 0)
                return;
            if (ev.key === Qt.Key_A && (ev.modifiers & Qt.ControlModifier)) {
                win.selectAll();
                ev.accepted = true;
            } else if ((ev.key === Qt.Key_C && (ev.modifiers & Qt.ControlModifier)) || ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) {
                win.doCopy();
                ev.accepted = true;
            }
        }

        Image {
            id: img
            anchors.fill: parent
            source: win.shot !== "" ? "file://" + win.shot : ""
            fillMode: Image.Stretch
            asynchronous: true
            cache: false
        }

        // dim everything except the selected region
        Rectangle { visible: !win.has; anchors.fill: parent; color: "#000000"; opacity: 0.55 }
        Rectangle { visible: win.has; x: 0; y: 0; width: parent.width; height: win.ry; color: "#000000"; opacity: 0.55 }
        Rectangle { visible: win.has; x: 0; y: win.ry + win.rh; width: parent.width; height: parent.height - (win.ry + win.rh); color: "#000000"; opacity: 0.55 }
        Rectangle { visible: win.has; x: 0; y: win.ry; width: win.rx; height: win.rh; color: "#000000"; opacity: 0.55 }
        Rectangle { visible: win.has; x: win.rx + win.rw; y: win.ry; width: parent.width - (win.rx + win.rw); height: win.rh; color: "#000000"; opacity: 0.55 }

        // crosshair before the first drag
        Rectangle { visible: win.phase === "select" && !win.has && win.mx >= 0; x: win.mx; y: 0; width: 1; height: parent.height; color: "#ffffff"; opacity: 0.35 }
        Rectangle { visible: win.phase === "select" && !win.has && win.my >= 0; x: 0; y: win.my; width: parent.width; height: 1; color: "#ffffff"; opacity: 0.35 }

        // frame
        Item {
            visible: win.has
            x: win.rx; y: win.ry; width: win.rw; height: win.rh
            Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: "#ffffff"; opacity: win.phase === "select" ? 0.9 : 0.35 }
            Repeater {
                model: win.phase === "select" ? 0 : 4
                delegate: Item {
                    required property int index
                    readonly property bool atRight: index % 2 === 1
                    readonly property bool atBottom: index >= 2
                    x: atRight ? parent.width - 14 : 0
                    y: atBottom ? parent.height - 14 : 0
                    width: 14; height: 14
                    Rectangle { y: parent.atBottom ? 12 : 0; width: 14; height: 2; color: "#ffffff" }
                    Rectangle { x: parent.atRight ? 12 : 0; width: 2; height: 14; color: "#ffffff" }
                }
            }
        }

        // size tag while dragging
        Rectangle {
            visible: win.phase === "select" && win.has && win.rw > 2
            x: win.rx
            y: win.ry + win.rh + 6 + height > parent.height ? win.ry - height - 6 : win.ry + win.rh + 6
            width: sizeText.implicitWidth + 14; height: 22; radius: 4
            color: ScribeTheme.text
            Text {
                id: sizeText
                anchors.centerIn: parent
                text: Math.round(win.rw) + " × " + Math.round(win.rh)
                font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.ink
            }
        }

        Text {
            visible: win.phase === "select" && !win.has
            anchors.horizontalCenter: parent.horizontalCenter
            y: 44
            text: ScribeStrings.s.dragRegion
            font.family: ScribeTheme.mono; font.pixelSize: 12
            color: ScribeTheme.text
            opacity: 0.85
        }

        // reading: the animation picked in the settings
        ScribeScanFx {
            z: 5
            visible: win.phase === "reading" || win.previewScan
            x: win.rx; y: win.ry; width: win.rw; height: win.rh
            kind: (win.cfg && win.cfg.scanAnim) || "line"
            accent: win.highlight
            running: win.phase === "reading" || win.previewScan
        }
        Rectangle {
            visible: win.phase === "reading"
            x: win.rx + 8
            y: win.rh > 44 ? win.ry + win.rh - height - 8 : win.ry + win.rh + 6
            width: readLbl.implicitWidth + 16; height: 20; radius: 4
            color: ScribeTheme.text
            Text {
                id: readLbl
                anchors.centerIn: parent
                text: ScribeStrings.s.reading
                font.family: ScribeTheme.mono; font.pixelSize: 10; font.letterSpacing: 1.2; font.weight: Font.DemiBold
                color: ScribeTheme.ink
            }
        }

        // ── result ───────────────────────────────────────
        Item {
            id: wordLayer
            visible: win.phase === "result"
            x: win.rect.x; y: win.rect.y; width: win.rect.width; height: win.rect.height

            // brief flash of every detected word so it is clear text was found
            Item {
                id: flashLayer
                opacity: 0
                Repeater {
                    model: win.phase === "result" ? win.lineBoxes : []
                    delegate: Rectangle {
                        required property var modelData
                        x: modelData.l - 2; y: modelData.t - 1
                        width: modelData.r - modelData.l + 4; height: modelData.b - modelData.t + 2
                        radius: 3
                        color: Qt.rgba(win.highlight.r, win.highlight.g, win.highlight.b, 0.22)
                    }
                }
            }
            SequentialAnimation {
                id: flash
                NumberAnimation { target: flashLayer; property: "opacity"; from: 0; to: 1; duration: 140 }
                PauseAnimation { duration: 260 }
                NumberAnimation { target: flashLayer; property: "opacity"; to: 0; duration: 520; easing.type: Easing.OutCubic }
            }

            // hovered word
            Rectangle {
                visible: win.hoverIdx >= 0 && win.selLo < 0 && win.hoverIdx < win.words.length
                x: win.hoverIdx >= 0 && win.hoverIdx < win.words.length ? win.words[win.hoverIdx].x - 2 : 0
                y: win.hoverIdx >= 0 && win.hoverIdx < win.words.length ? win.words[win.hoverIdx].y - 1 : 0
                width: win.hoverIdx >= 0 && win.hoverIdx < win.words.length ? win.words[win.hoverIdx].w + 4 : 0
                height: win.hoverIdx >= 0 && win.hoverIdx < win.words.length ? win.words[win.hoverIdx].h + 2 : 0
                radius: 3
                color: Qt.rgba(1, 1, 1, 0.14)
            }

            // the selection: one merged box per line, like selected text
            Repeater {
                model: win.selRects
                delegate: Rectangle {
                    required property var modelData
                    x: modelData.l - 2; y: modelData.t - 1
                    width: modelData.r - modelData.l + 4; height: modelData.b - modelData.t + 2
                    radius: 3
                    color: Qt.rgba(win.highlight.r, win.highlight.g, win.highlight.b, 0.42)
                    Behavior on width { NumberAnimation { duration: 60 } }
                    Behavior on height { NumberAnimation { duration: 60 } }
                }
            }
        }

        // floating toolbar above the selection
        Rectangle {
            id: bar
            z: 10
            visible: win.phase === "result" && win.selLo >= 0 && !win.wordDrag
            readonly property bool above: win.selBox.y - height - 10 >= 8
            x: Math.max(10, Math.min(win.selBox.x + win.selBox.width / 2 - width / 2, parent.width - width - 10))
            y: above ? win.selBox.y - height - 10 : win.selBox.y + win.selBox.height + 10
            height: 40
            width: barRow.implicitWidth + 8
            radius: 20
            color: "#1b1b1b"
            border.width: 1
            border.color: "#3d3d3d"

            opacity: visible ? 1 : 0
            onVisibleChanged: if (visible) barIn.restart()
            ParallelAnimation {
                id: barIn
                NumberAnimation { target: bar; property: "opacity"; from: 0; to: 1; duration: 140 }
                NumberAnimation { target: bar; property: "scale"; from: 0.92; to: 1; duration: 200; easing.type: Easing.OutBack; easing.overshoot: 1.6 }
            }

            Row {
                id: barRow
                x: 4; y: 4
                spacing: 0

                ScribeBarButton {
                    label: win.copied ? ScribeStrings.s.copied : ScribeStrings.s.copy
                    done: win.copied
                    onActivated: win.doCopy()
                }

                Rectangle { width: 1; height: 20; y: 6; color: "#3d3d3d"; visible: !win.copied }

                ScribeBarButton {
                    visible: !win.copied
                    label: ScribeStrings.s.selectAll
                    onActivated: win.selectAll()
                }

                Rectangle { width: 1; height: 20; y: 6; color: "#3d3d3d"; visible: !win.copied && win.tr !== null && win.tr.enabled }

                ScribeBarButton {
                    visible: !win.copied && win.tr !== null && win.tr.enabled
                    label: ScribeStrings.s.translate
                    onActivated: win.translateSelection()
                }
            }
        }

        // status hint under the region (no card)
        Rectangle {
            id: hintPill
            visible: win.phase === "result" && win.hint !== "" && !bar.visible && !tview.cardShown && !tview.dockShown && !tview.stateShown
            x: Math.max(12, Math.min(win.rect.x, parent.width - width - 12))
            y: win.rect.y + win.rect.height + 12 + height > parent.height ? Math.max(12, win.rect.y - height - 12) : win.rect.y + win.rect.height + 12
            height: 30
            width: hintRow.implicitWidth + 24
            radius: 15
            color: "#1b1b1b"
            border.width: 1
            border.color: "#3d3d3d"
            Row {
                id: hintRow
                anchors.centerIn: parent
                spacing: 10
                Text { text: win.hint; font.family: ScribeTheme.mono; font.pixelSize: 12; color: ScribeTheme.text }
                Rectangle { width: 1; height: 12; color: "#3d3d3d"; anchors.verticalCenter: parent.verticalCenter }
                Text { text: "Esc"; font.family: ScribeTheme.mono; font.pixelSize: 11; color: ScribeTheme.dim }
            }
        }

        // Translate button: nothing is translated, and the model is not loaded, until it is pressed
        Rectangle {
            id: trPill
            z: 12
            visible: win.phase === "result" && win.tr !== null && win.tr.enabled && win.words.length > 0 && !bar.visible
                     && (win.tr.status === "idle" || tview.dismissed)
            height: 34
            width: trBtn.width + 8
            radius: 17
            color: "#1b1b1b"
            border.width: 1
            border.color: "#3d3d3d"
            x: hintPill.visible ? hintPill.x + hintPill.width + 8 : Math.max(12, Math.min(win.rect.x, parent.width - width - 12))
            y: hintPill.visible ? hintPill.y - 2
               : (win.rect.y + win.rect.height + 12 + height > parent.height ? Math.max(12, win.rect.y - height - 12) : win.rect.y + win.rect.height + 12)
            ScribeBarButton {
                id: trBtn
                x: 4; y: 4
                compact: true
                label: ScribeStrings.s.translate
                onActivated: win.openTranslation()
            }
        }

        // ── translation: card or in-place text, smart actions, dictionary ──
        ScribeTranslateView {
            id: tview
            z: 15
            anchors.fill: parent
            visible: win.phase === "result" && win.tr !== null
            tr: win.tr
            rect: win.rect
            words: win.words
            hintShown: hintPill.visible || trPill.visible
            onCloseOverlay: win.cancelled()
            onCopyText: t => win.copyText(t, 0)
            onEntityCopied: { win.copied = true; if (win.closeAfterCopy) closeTimer.restart(); }
        }

        // ── settings: gear + panel ───────────────────────
        Rectangle {
            id: gear
            z: 20
            visible: win.phase === "result"
            x: parent.width - width - 16
            y: parent.height - height - 16
            width: 42; height: 42; radius: 21
            color: gearMa.pressed ? "#3a3a3a" : ((gearMa.containsMouse || win.settingsOpen) ? "#2b2b2b" : "#1b1b1b")
            border.width: 1
            border.color: win.settingsOpen ? ScribeTheme.lineStrong : "#3d3d3d"
            scale: gearMa.pressed ? 0.92 : 1
            Behavior on color { ColorAnimation { duration: 120 } }
            Behavior on scale { NumberAnimation { duration: 80 } }

            opacity: 0
            onVisibleChanged: if (visible) gearIn.restart()
            NumberAnimation { id: gearIn; target: gear; property: "opacity"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }

            Canvas {
                id: gearIcon
                width: 20; height: 20
                anchors.centerIn: parent
                rotation: win.settingsOpen ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }
                onPaint: {
                    var c = getContext("2d");
                    c.clearRect(0, 0, width, height);
                    c.translate(10, 10);
                    c.fillStyle = "#ececec";
                    c.strokeStyle = "#ececec";
                    for (var i = 0; i < 8; i++) {
                        c.save();
                        c.rotate(i * Math.PI / 4);
                        c.fillRect(-1.7, -9.6, 3.4, 4.2);
                        c.restore();
                    }
                    c.lineWidth = 2.4;
                    c.beginPath();
                    c.arc(0, 0, 6.1, 0, Math.PI * 2);
                    c.stroke();
                    c.beginPath();
                    c.arc(0, 0, 1.9, 0, Math.PI * 2);
                    c.fill();
                }
            }
            MouseArea {
                id: gearMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    win.settingsOpen = !win.settingsOpen;
                    if (win.settingsOpen) win.settingsOpened();
                }
            }
        }

        ScribeSettings {
            id: settingsPanel
            z: 20
            x: parent.width - width - 16
            y: Math.max(8, parent.height - height - 70)
            opacity: win.settingsOpen ? 1 : 0
            visible: opacity > 0.01
            scale: win.settingsOpen ? 1 : 0.95
            transformOrigin: Item.BottomRight
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.3 } }

            tr: win.tr
            maxHeight: parent.height - 100
            cfg: win.cfg
            installed: win.installed
            installing: win.installing
            installPct: win.installPct
            installMsg: win.installMsg
            pmName: win.pmName
            osName: win.osName
            choiceCode: win.choiceCode
            choiceCmd: win.choiceCmd
            terminalCode: win.terminalCode
            onChooseLang: code => win.chooseLang(code)
            onCancelChoice: win.cancelChoice()
            onCopyCommand: win.copyCommand()
            onRunTerminal: code => win.runTerminal(code)
            onChangeCfg: (k, v) => win.setCfg(k, v)
            onInstallLang: code => win.installLang(code)
            onCloseRequested: win.settingsOpen = false
        }

        // ── input ─────────────────────────────────────────
        MouseArea {
            anchors.fill: parent
            enabled: win.phase === "select"
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.CrossCursor
            onPressed: mouse => {
                if (mouse.button === Qt.RightButton) { win.has = false; win.dragging = false; return; }
                win.sx = win.ex = mouse.x;
                win.sy = win.ey = mouse.y;
                win.dragging = true;
                win.has = true;
            }
            onPositionChanged: mouse => {
                win.mx = mouse.x; win.my = mouse.y;
                if (win.dragging) { win.ex = mouse.x; win.ey = mouse.y; }
            }
            onReleased: mouse => {
                if (mouse.button !== Qt.LeftButton || !win.dragging) return;
                win.dragging = false;
                if (win.rw > 8 && win.rh > 8)
                    win.picked(win.rx, win.ry, win.rw, win.rh, img.sourceSize.width / win.width);
                else
                    win.has = false;
            }
        }

        MouseArea {
            anchors.fill: parent
            enabled: win.phase === "result"
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: win.hoverIdx >= 0 ? Qt.IBeamCursor : Qt.ArrowCursor
            onPressed: mouse => {
                if (win.settingsOpen) { win.settingsOpen = false; return; }
                if (mouse.button === Qt.RightButton) { win.setSel(-1, -1); return; }
                var lx = mouse.x - win.rect.x, ly = mouse.y - win.rect.y;
                var inside = lx >= 0 && ly >= 0 && lx <= win.rect.width && ly <= win.rect.height;
                var i = inside ? win.hit(lx, ly) : -1;
                if (i >= 0) {
                    win.anchorIdx = i;
                    win.setSel(i, i);
                    win.wordDrag = true;
                } else if (win.selLo >= 0) {
                    win.setSel(-1, -1);          // click on empty space clears the selection
                } else if (!inside) {
                    win.cancelled();             // second click outside closes
                }
            }
            onPositionChanged: mouse => {
                var lx = mouse.x - win.rect.x, ly = mouse.y - win.rect.y;
                win.hoverIdx = win.hit(lx, ly);
                if (win.wordDrag) {
                    var j = win.nearest(lx, ly);
                    if (j >= 0) {
                        var lo = Math.min(win.anchorIdx, j), hi = Math.max(win.anchorIdx, j);
                        if (lo !== win.selLo || hi !== win.selHi)
                            win.setSel(lo, hi);
                    }
                }
            }
            onReleased: mouse => { win.wordDrag = false; }
        }
    }
}
