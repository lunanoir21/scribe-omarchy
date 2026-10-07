import QtQuick

// The "reading" animation drawn over the selected region. `kind` picks one of the six looks;
// only the picked one is instantiated, and nothing runs while `running` is false.
Item {
    id: fx

    property string kind: "line"        // line | rows | shine | pixels | ring | focus
    property bool running: true
    property color accent: "#8ab4f8"
    clip: true

    readonly property real cw: Math.max(1, width)
    readonly property real ch: Math.max(1, height)

    // ── 1 · line ────────────────────────────────────────
    Item {
        anchors.fill: parent
        visible: fx.kind === "line"
        Rectangle {
            width: parent.width
            height: 36
            y: sweepLine.y - height
            color: "#ffffff"
            opacity: 0.10
        }
        Rectangle {
            id: sweepLine
            width: parent.width
            height: 2
            color: "#ffffff"
            SequentialAnimation on y {
                running: fx.running && fx.kind === "line"
                loops: Animation.Infinite
                NumberAnimation {
                    from: 0
                    to: fx.ch
                    duration: 800
                    easing.type: Easing.InOutQuad
                }
                PauseAnimation {
                    duration: 100
                }
            }
        }
    }

    // ── 2 · rows ────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: fx.kind === "rows"
        sourceComponent: Item {
            readonly property int rowH: 28
            readonly property int n: Math.max(1, Math.min(40, Math.floor(fx.ch / rowH)))
            readonly property int stagger: Math.max(10, Math.min(140, Math.floor(900 / n)))
            readonly property int cycle: n * stagger + 1300
            Repeater {
                model: parent.n
                delegate: Rectangle {
                    id: bar
                    required property int index
                    x: 8
                    y: 4 + index * 28
                    height: 24
                    radius: 3
                    color: "#ffffff"
                    width: 0
                    opacity: 0
                    SequentialAnimation {
                        running: fx.running
                        loops: Animation.Infinite
                        PropertyAction {
                            target: bar
                            property: "opacity"
                            value: 0.2
                        }
                        PropertyAction {
                            target: bar
                            property: "width"
                            value: 0
                        }
                        PauseAnimation {
                            duration: bar.index * bar.parent.stagger
                        }
                        NumberAnimation {
                            target: bar
                            property: "width"
                            to: fx.cw - 16
                            duration: 500
                            easing.type: Easing.OutCubic
                        }
                        PauseAnimation {
                            duration: 300
                        }
                        NumberAnimation {
                            target: bar
                            property: "opacity"
                            to: 0
                            duration: 300
                        }
                        PauseAnimation {
                            duration: Math.max(0, bar.parent.cycle - bar.index * bar.parent.stagger - 1100)
                        }
                    }
                }
            }
        }
    }

    // ── 3 · shine ───────────────────────────────────────
    // A slanted band of light crosses the region and eases out, like glare on glass. One item, one animation.
    Item {
        anchors.fill: parent
        visible: fx.kind === "shine"
        Item {
            id: band
            width: 70
            height: fx.ch * 1.8
            y: -fx.ch * 0.4
            rotation: 20
            transformOrigin: Item.Center
            Rectangle {
                anchors.fill: parent
                color: "#ffffff"
                opacity: 0.11
            }
            Rectangle {
                anchors.right: parent.right
                width: 2
                height: parent.height
                color: "#ffffff"
            }
            SequentialAnimation on x {
                running: fx.running && fx.kind === "shine"
                loops: Animation.Infinite
                NumberAnimation {
                    from: -120
                    to: fx.cw + 120
                    duration: 1100
                    easing.type: Easing.InOutCubic
                }
                PauseAnimation {
                    duration: 400
                }
            }
        }
    }

    // ── 4 · pixels ──────────────────────────────────────
    // One canvas that only redraws when the wave moves a whole step, and only draws the cells inside the band.
    Loader {
        anchors.fill: parent
        active: fx.kind === "pixels"
        sourceComponent: Canvas {
            id: pix
            anchors.fill: parent
            renderTarget: Canvas.FramebufferObject
            renderStrategy: Canvas.Cooperative
            readonly property real cell: Math.max(14, Math.sqrt(fx.cw * fx.ch / 600))
            readonly property int cols: Math.ceil(fx.cw / cell)
            readonly property int rws: Math.ceil(fx.ch / cell)
            property real head: -4
            property int step: Math.floor(head * 1.5)
            NumberAnimation on head {
                running: fx.running && fx.kind === "pixels"
                loops: Animation.Infinite
                from: -4
                to: pix.cols + pix.rws + 4
                duration: 1600
            }
            onStepChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var h = Math.floor(head * 1.5) / 1.5;
                ctx.fillStyle = "#ffffff";
                for (var d = Math.max(0, Math.ceil(h - 4)); d <= h + 4; d++) {
                    var a = Math.max(0, 1 - Math.abs(d - h) / 4) * 0.28;
                    if (a <= 0.005)
                        continue;
                    ctx.globalAlpha = a;
                    for (var r = 0; r < rws; r++) {
                        var c = d - r;
                        if (c < 0 || c >= cols)
                            continue;
                        ctx.fillRect(c * cell, r * cell, cell - 1, cell - 1);
                    }
                }
            }
        }
    }

    // ── 5 · ring ────────────────────────────────────────
    Loader {
        anchors.fill: parent
        active: fx.kind === "ring"
        sourceComponent: Canvas {
            id: ring
            anchors.fill: parent
            property real p: 0
            NumberAnimation on p {
                running: fx.running && fx.kind === "ring"
                loops: Animation.Infinite
                from: 0
                to: 1
                duration: 1600
            }
            property int pStep: Math.floor(p * 90)
            onPStepChanged: requestPaint()
            renderTarget: Canvas.FramebufferObject
            renderStrategy: Canvas.Cooperative
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
                var ctx = getContext("2d");
                ctx.reset();
                var w = width - 3, h = height - 3, per = 2 * (w + h);
                if (w <= 0 || h <= 0)
                    return;
                function pt(d) {
                    d = ((d % per) + per) % per;
                    if (d < w)
                        return [1.5 + d, 1.5];
                    d -= w;
                    if (d < h)
                        return [1.5 + w, 1.5 + d];
                    d -= h;
                    if (d < w)
                        return [1.5 + w - d, 1.5 + h];
                    d -= w;
                    return [1.5, 1.5 + h - d];
                }
                ctx.lineWidth = 2;
                ctx.lineCap = "round";
                ctx.strokeStyle = "#ffffff";
                var seg = per * 0.16, steps = 28, start = p * per;
                for (var i = 0; i < steps; i++) {
                    var a = pt(start - seg * (i / steps)), b = pt(start - seg * ((i + 1) / steps));
                    ctx.globalAlpha = 1 - i / steps;
                    ctx.beginPath();
                    ctx.moveTo(a[0], a[1]);
                    ctx.lineTo(b[0], b[1]);
                    ctx.stroke();
                }
            }
        }
    }

    // ── 6 · focus ───────────────────────────────────────
    Item {
        id: fcs
        anchors.fill: parent
        visible: fx.kind === "focus"
        property real inset: -8
        property real alpha: 0
        ParallelAnimation {
            running: fx.running && fx.kind === "focus"
            loops: Animation.Infinite
            SequentialAnimation {
                NumberAnimation {
                    target: fcs
                    property: "inset"
                    from: -8
                    to: 10
                    duration: 900
                    easing.type: Easing.OutCubic
                }
                PauseAnimation {
                    duration: 500
                }
            }
            SequentialAnimation {
                NumberAnimation {
                    target: fcs
                    property: "alpha"
                    from: 0
                    to: 1
                    duration: 220
                }
                PauseAnimation {
                    duration: 1000
                }
                NumberAnimation {
                    target: fcs
                    property: "alpha"
                    to: 0
                    duration: 180
                }
            }
        }
        Repeater {
            model: 4
            delegate: Item {
                required property int index
                readonly property bool atRight: index % 2 === 1
                readonly property bool atBottom: index >= 2
                width: 18
                height: 18
                x: atRight ? fx.cw - fcs.inset - width : fcs.inset
                y: atBottom ? fx.ch - fcs.inset - height : fcs.inset
                opacity: fcs.alpha
                Rectangle {
                    width: 18
                    height: 2
                    color: "#ffffff"
                    y: parent.atBottom ? 16 : 0
                }
                Rectangle {
                    width: 2
                    height: 18
                    color: "#ffffff"
                    x: parent.atRight ? 16 : 0
                }
            }
        }
    }
}
