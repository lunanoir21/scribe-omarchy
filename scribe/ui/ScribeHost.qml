import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Integration point: one `ScribeHost {}` in the shell root.
// Bind a key to:  qs ipc call scribe start        (add `-p /path/to/Shell.qml` if you run several shells)
//
// Resource limits, on purpose: every process whose output we collect is bounded at its source
// (scribe.sh read pipes through `head -c 4 MiB`, ocr.py returns at most 4000 words, the other
// helpers print a few lines), the read has a watchdog, and the screenshot is deleted as soon as
// the overlay closes.
Scope {
    id: host

    // idle -> capturing -> selecting -> reading -> result
    property string phase: "idle"
    property var cfg: ({ langs: "tur+eng", autoCopy: false, joinLines: true, minConfidence: 60,
                         highlight: "#8ab4f8", closeAfterCopy: true,
                         translate: false, autoTranslate: false, tView: "card", tEngine: "offline", tTarget: "tr", tSource: "auto",
                         tOnline: false, tEmail: "", smartActions: true, dictionary: true, editable: true })

    ScribeTranslator {
        id: translator
        cfg: host.cfg
        baseDir: host.baseDir
        onCopyRequested: t => host.copy(t)
        onCfgRequested: (k, v) => host.setCfg(k, v)
    }

    property var targetScreen: null
    property string shotPath: ""
    property rect selRect: Qt.rect(0, 0, 0, 0)
    property var words: []
    property string resultStatus: "ok"
    property int resultConf: 0
    property var missing: []            // dependencies reported by `scribe.sh check`

    // interface language: the `ui` setting, or the system language when it is "auto"
    readonly property string uiLang: (cfg.ui === "tr" || cfg.ui === "en") ? cfg.ui
        : (((Quickshell.env("LC_ALL") || Quickshell.env("LC_MESSAGES") || Quickshell.env("LANG") || "").toLowerCase().indexOf("tr") === 0) ? "tr" : "en")
    Binding { target: ScribeStrings; property: "lang"; value: host.uiLang }

    readonly property int maxWords: 4000
    readonly property int readTimeoutMs: 90000
    readonly property string baseDir: Qt.resolvedUrl("..").toString().replace(/^file:\/\//, "")
    readonly property string script: baseDir + "scribe.sh"
    readonly property string langsPy: baseDir + "langs.py"
    readonly property string configPy: baseDir + "config.py"

    function notify(msg) {
        Quickshell.execDetached(["notify-send", "-a", "scribe", "scribe", msg]);
    }

    // Stop everything that is in flight and remove the screenshot. Late output of a stopped
    // process is ignored because every handler checks `phase`.
    function reset() {
        phase = "idle";
        words = [];
        translator.reset();
        choiceCode = "";                 // a reopened overlay starts with a clean settings panel
        choiceCmd = "";
        installMsg = "";
        watchdog.stop();
        grabProc.running = false;
        readProc.running = false;
        cleanProc.command = [script, "clean"];
        cleanProc.running = true;
    }

    function applyConfig(text) {
        try {
            var o = JSON.parse(text);
            if (o && typeof o === "object")
                host.cfg = Object.assign({}, host.cfg, o);
        } catch (e) {
            console.warn("scribe: could not parse the settings:", e);
        }
    }

    function start() {
        if (phase !== "idle")
            return;
        if (missing.length > 0) {
            notify(ScribeStrings.s.missing(missing.join(", ")));
            return;
        }
        var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
        var scr = null;
        for (var i = 0; i < Quickshell.screens.length; i++)
            if (Quickshell.screens[i].name === name)
                scr = Quickshell.screens[i];
        if (!scr && Quickshell.screens.length)
            scr = Quickshell.screens[0];
        targetScreen = scr;
        phase = "capturing";
        cfgProc.command = ["python3", "-I", configPy, "read"];
        cfgProc.running = true;
        if (devShot !== "") {          // dev mode only: use a prepared image instead of the screen
            shotPath = devShot;
            phase = "selecting";
            applyTest();
            return;
        }
        grabProc.command = [script, "shot", scr ? scr.name : ""];
        grabProc.running = true;
    }

    // ── language packs + settings panel ──────────────────
    property var installed: []
    property string pmName: ""
    property string osName: ""
    property string installing: ""
    property int installPct: 0
    property string installMsg: ""
    property string choiceCode: ""
    property string choiceCmd: ""
    property string terminalCode: ""

    function refreshLangs() {
        infoProc.command = ["python3", "-I", langsPy, "info"];
        infoProc.running = true;
    }

    function chooseLang(code) {
        choiceCode = code;
        choiceCmd = "";
        installMsg = "";
        cmdProc.command = ["python3", "-I", langsPy, "command", code, "--lang", uiLang];
        cmdProc.running = true;
    }

    function runTerminal(code) {
        if (terminalCode !== "")
            return;
        terminalCode = code;
        installMsg = "";
        termProc.command = ["python3", "-I", langsPy, "term", code, "--lang", uiLang];
        termProc.running = true;
    }

    function installLang(code) {
        if (installing !== "")
            return;
        choiceCode = "";
        installing = code;
        installPct = 0;
        installMsg = "";
        installProc.command = ["python3", "-I", langsPy, "install", code, "--lang", uiLang];
        installProc.running = true;
    }

    // config.py validates every key and value, and answers with the settings it actually saved
    function setCfg(key, value) {
        var change = {};
        change[key] = value;
        saveProc.command = ["python3", "-I", configPy, "write", JSON.stringify(change)];
        saveProc.running = true;
    }

    function pick(x, y, w, h, scale) {
        selRect = Qt.rect(x, y, w, h);
        phase = "reading";
        watchdog.restart();
        readProc.command = [script, "read", shotPath, String(x), String(y), String(w), String(h), String(scale), cfg.langs];
        readProc.running = true;
    }

    // The text goes to wl-copy through its stdin and never through a command line: process
    // arguments can be read by other local users (/proc/<pid>/cmdline), and this text is whatever
    // was on the screen.
    property string pendingCopy: ""
    function copy(text) {
        if (text === "")
            return;
        pendingCopy = text;
        copyProc.stdinEnabled = true;
        copyProc.running = true;
    }

    // ── developer helpers ────────────────────────────────
    // Only answer when the owner-only flag file $XDG_RUNTIME_DIR/scribe-dev exists. They exist
    // to take documentation screenshots and to test without a mouse.
    property string devShot: ""
    property var testRect: null
    property string devSel: ""
    property var devDrag: null
    readonly property string devFlagPath: (Quickshell.env("XDG_RUNTIME_DIR") || "") + "/scribe-dev"

    // The check is a real `test -f` on the flag file, so it cannot be fooled by a stale cache.
    property var devAction: null
    function devRun(fn) {
        devAction = fn;
        flagProc.command = ["test", "-f", devFlagPath];
        flagProc.running = true;
    }
    Process {
        id: flagProc
        onExited: code => {
            var fn = host.devAction;
            host.devAction = null;
            if (code === 0 && fn)
                fn();
        }
    }

    function applyTest() {
        if (testRect) {
            var r = testRect;
            testRect = null;
            pick(r.x, r.y, r.w, r.h, 1);
        }
    }

    IpcHandler {
        target: "scribe"
        function start(): void { host.start(); }
        function cancel(): void { host.reset(); }

        function devopen(): void { host.devRun(function () { if (lensLoader.item) lensLoader.item.settingsOpen = true; }); }
        function devchoose(code: string): void { host.devRun(function () { host.chooseLang(code); }); }
        // documentation screenshots: the card shown before translation is enabled, a hovered word,
        // and starting the translation without a click
        function devenable(): void { host.devRun(function () { if (lensLoader.item) lensLoader.item.devEnableCard(); }); }
        function devword(i: int): void { host.devRun(function () { if (lensLoader.item) lensLoader.item.devHoverWord(i); }); }
        function devtranslate(): void { host.devRun(function () { translator.start(); }); }
        function devclear(): void { host.devShot = ""; host.devDrag = null; host.testRect = null; host.devSel = ""; }
        function devdrag(x: real, y: real, w: real, h: real): void {
            host.devRun(function () { host.devDrag = { x: x, y: y, w: w, h: h }; });
        }
        function devread(x: real, y: real, w: real, h: real): void {   // static "reading" frame
            host.devRun(function () { host.selRect = Qt.rect(x, y, w, h); host.phase = "reading"; });
        }
        function testsel(x: real, y: real, w: real, h: real, lo: int, hi: int): void {
            host.devRun(function () {
                host.devSel = lo + "," + hi;
                host.testRect = { x: x, y: y, w: w, h: h };
                host.start();
            });
        }
        function test(x: real, y: real, w: real, h: real): void {
            host.devRun(function () {
                host.testRect = { x: x, y: y, w: w, h: h };
                host.start();
            });
        }
    }

    // ── processes ────────────────────────────────────────
    Component.onCompleted: {
        refreshLangs();
        cfgProc.command = ["python3", "-I", configPy, "read"];
        cfgProc.running = true;
        checkProc.command = [script, "check"];
        checkProc.running = true;
    }

    // a read that never finishes must not leave a full-screen overlay stuck on the display
    Timer {
        id: watchdog
        interval: host.readTimeoutMs
        onTriggered: {
            if (host.phase === "reading") {
                host.notify(ScribeStrings.s.readTimeout);
                host.reset();
            }
        }
    }

    Process {
        id: checkProc
        stdout: StdioCollector {
            onStreamFinished: {
                var miss = [], lines = text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var f = lines[i].split("\t");
                    if (f[0] === "MISSING" && f[1]) miss.push(f[1]);
                }
                host.missing = miss;
            }
        }
    }

    Process {
        id: cfgProc
        stdout: StdioCollector { onStreamFinished: host.applyConfig(text.trim()) }
    }

    Process {
        id: saveProc
        stdout: StdioCollector { onStreamFinished: host.applyConfig(text.trim()) }
    }

    Process { id: cleanProc }
    Process {
        id: copyProc
        command: ["wl-copy"]
        stdinEnabled: true
        onStarted: {
            write(host.pendingCopy);
            host.pendingCopy = "";
            stdinEnabled = false;        // closes stdin: wl-copy reads until EOF, then keeps the selection
        }
    }

    Process {
        id: grabProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (host.phase !== "capturing")
                    return;
                var p = text.trim();
                if (p !== "") {
                    host.shotPath = p;
                    host.phase = "selecting";
                    host.applyTest();
                }
            }
        }
        onExited: code => {
            if (code !== 0 && host.phase === "capturing") {
                host.notify(ScribeStrings.s.grabFailed);
                host.reset();
            }
        }
    }

    Process {
        id: readProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (host.phase !== "reading")
                    return;            // cancelled or timed out meanwhile
                watchdog.stop();
                var out = [], conf = 0, err = "";
                var parIds = {}, lineIds = {}, np = 0, nl = 0;
                var lines = text.split("\n");
                for (var i = 0; i < lines.length && out.length < host.maxWords; i++) {
                    var f = lines[i].split("\t");
                    if (f[0] === "W" && f.length >= 8) {
                        var x = parseFloat(f[3]), y = parseFloat(f[4]), w = parseFloat(f[5]), h = parseFloat(f[6]);
                        if (!isFinite(x) || !isFinite(y) || !isFinite(w) || !isFinite(h))
                            continue;
                        if (parIds[f[1]] === undefined) parIds[f[1]] = np++;
                        if (lineIds[f[2]] === undefined) lineIds[f[2]] = nl++;
                        out.push({ par: parIds[f[1]], line: lineIds[f[2]], x: x, y: y, w: w, h: h, t: f.slice(7).join("\t") });
                    } else if (f[0] === "CONF") {
                        conf = parseInt(f[1] || "0");
                    } else if (f[0] === "ERR") {
                        err = f[1] || "fail";
                    }
                }
                if (err !== "" && err !== "nolang") {
                    host.notify(ScribeStrings.s.readFailed(err));
                    host.reset();
                    return;
                }
                host.resultConf = conf;
                host.words = out;
                if (err === "nolang")
                    host.resultStatus = "nolang";
                else if (out.length === 0)
                    host.resultStatus = "empty";
                else if (conf < host.cfg.minConfidence)
                    host.resultStatus = "low";
                else
                    host.resultStatus = "ok";
                host.phase = "result";
                // text that was read is translated at the same time it can be copied
                if (out.length > 0 && err !== "nolang") {
                    translator.prepare(translator.paragraphs(out, 0, out.length - 1));
                    if (host.cfg.autoTranslate) translator.start();
                }
            }
        }
        onExited: code => {
            if (code !== 0 && code !== 2 && host.phase === "reading") {
                host.notify(ScribeStrings.s.readFailed("exit " + code));
                host.reset();
            }
        }
    }

    Process {
        id: cmdProc
        stdout: StdioCollector { onStreamFinished: host.choiceCmd = text.trim() }
    }

    Process {
        id: termProc
        onExited: {
            host.terminalCode = "";
            host.refreshLangs();
            host.installMsg = ScribeStrings.s.terminalClosed;
        }
    }

    Process {
        id: infoProc
        stdout: StdioCollector {
            onStreamFinished: {
                var codes = [], lines = text.split("\n");
                for (var i = 0; i < lines.length; i++) {
                    var f = lines[i].split("\t");
                    if (f[0] === "PM") { host.pmName = f[1] || ""; host.osName = f[2] || ""; }
                    else if (f[0] === "L" && f[1]) codes.push(f[1]);
                }
                host.installed = codes;
            }
        }
    }

    Process {
        id: installProc
        stdout: SplitParser {
            onRead: line => {
                var f = line.split("\t");
                if (f[0] === "MSG") host.installMsg = f[1] || "";
                else if (f[0] === "PCT") host.installPct = parseInt(f[1] || "0");
            }
        }
        onExited: code => {
            host.installing = "";
            host.installPct = 0;
            if (code !== 0 && host.installMsg === "")
                host.installMsg = ScribeStrings.s.installFailed;
            host.refreshLangs();
        }
    }

    Loader {
        id: lensLoader
        active: host.phase === "selecting" || host.phase === "reading" || host.phase === "result"
        sourceComponent: ScribeLens {
            screen: host.targetScreen
            shot: host.shotPath
            phase: host.phase === "selecting" ? "select" : (host.phase === "reading" ? "reading" : "result")
            words: host.words
            status: host.resultStatus
            confidence: host.resultConf
            autoSelect: host.cfg.autoCopy
            joinLines: host.cfg.joinLines
            closeAfterCopy: host.cfg.closeAfterCopy
            highlight: host.cfg.highlight
            devSel: host.devSel
            devDrag: host.devDrag
            cfg: host.cfg
            installed: host.installed
            installing: host.installing
            installPct: host.installPct
            installMsg: host.installMsg
            pmName: host.pmName
            osName: host.osName
            onSetCfg: (k, v) => host.setCfg(k, v)
            choiceCode: host.choiceCode
            choiceCmd: host.choiceCmd
            terminalCode: host.terminalCode
            onChooseLang: code => host.chooseLang(code)
            onCancelChoice: host.choiceCode = ""
            onCopyCommand: { host.copy(host.choiceCmd); host.installMsg = ScribeStrings.s.commandCopied; }
            onRunTerminal: code => host.runTerminal(code)
            onInstallLang: code => host.installLang(code)
            onSettingsOpened: { host.refreshLangs(); translator.refreshStatus(); }
            tr: translator
            onTranslateRequested: text => translator.start(text)
            rect: host.selRect
            onCancelled: host.reset()
            onCopyText: (t, n) => host.copy(t)
            onPicked: (x, y, w, h, scale) => host.pick(x, y, w, h, scale)
        }
    }
}
