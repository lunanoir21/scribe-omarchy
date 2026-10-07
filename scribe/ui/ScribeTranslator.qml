import QtQuick
import Quickshell
import Quickshell.Io

// Translation state and processes for the result view. One instance lives in ScribeHost; the view
// (ScribeTranslateView) only reads it and calls its functions.
//
// Every process takes the text on STDIN, never on its command line: the text is whatever was on
// the screen and command lines are readable by other local users (/proc/<pid>/cmdline).
// Settings come from `cfg` (config.py) and are handed to translate.py as flags.
Scope {
    id: tr

    property var cfg: ({})
    // Nothing runs for translation until the user switched it on in the settings panel.
    readonly property bool enabled: cfg.translate === true
    property string baseDir: ""
    readonly property string py: baseDir + "translate.py"

    signal copyRequested(string text)
    signal cfgRequested(string key, var value)

    // ── text ─────────────────────────────────────────────
    property string original: ""
    property string translated: ""
    property string srcLang: "en"
    property string tgtLang: "tr"
    property bool translating: false
    property string trError: ""
    property string engineUsed: ""
    property int tookMs: 0
    property var entities: []
    readonly property bool hasTranslation: translated !== ""

    // idle | ready | nomodel | consent | installing
    property string status: "idle"
    readonly property bool active: status !== "idle"
    property bool forceOnline: false      // "use online" chosen for this read
    property bool onlineOnce: false       // "send once" chosen for this read
    property string needSrc: ""
    property string needTgt: ""

    function parse(text) {
        try { return JSON.parse(text.trim()); } catch (e) { return null; }
    }

    function errText(code, msg) {
        var s = ScribeStrings.s;
        if (code === "network") return s.trNetwork;
        if (code === "offline_failed") return s.trService;
        return s.trFailed;
    }

    // Bumped on every reset: a late answer from the link finder is only used if it still belongs to
    // the text that is on screen (status alone cannot tell, it is "idle" before Translate is pressed).
    property int gen: 0

    function reset() {
        gen++;
        status = "idle";
        original = ""; translated = ""; trError = ""; entities = [];
        translating = false; forceOnline = false; onlineOnce = false;
        pending = null; hideDict();
        retranslate.stop(); entityTimer.stop();
        trProc.running = false; lookProc.running = false; entProc.running = false;
    }

    // Joins words (as ScribeHost/ScribeLens hold them) into paragraphs: one line per paragraph,
    // a blank line between paragraphs. words[lo..hi]; the engine re-joins wrapped lines itself.
    function paragraphs(words, lo, hi) {
        var out = "", prev = null;
        for (var i = lo; i <= hi && i < words.length; i++) {
            var w = words[i];
            if (prev) {
                if (w.par === prev.par) {
                    out += " ";
                } else {
                    // The reader can start a new paragraph in the middle of a sentence (slightly
                    // rotated text, uneven lines), and translating the halves apart ruins both. A
                    // paragraph that ends without sentence punctuation and is followed by a
                    // lowercase word is the same sentence.
                    var c = w.t.charAt(0);
                    var lower = c !== "" && c === c.toLowerCase() && c !== c.toUpperCase();
                    var open = !/[.!?:;…"”»)\]]$/.test(prev.t);
                    out += (open && lower) ? " " : "\n\n";
                }
            }
            out += w.t;
            prev = w;
        }
        return out;
    }

    // a region was read: remember its text and look for links; translating starts separately
    // Smart actions (links, e-mail, phone, IBAN) do not need translation to be on: they only run the
    // local helper, no model and no network.
    function prepare(text) {
        reset();
        original = text;
        srcLang = "en";
        tgtLang = cfg.tTarget || "tr";
        if (cfg.smartActions) findEntities();
    }

    // show the translation view and translate `text` (or the text already prepared)
    function start(text) {
        if (!enabled) return;
        if (text !== undefined && text !== "") {
            reset();
            original = text;
            tgtLang = cfg.tTarget || "tr";
            if (cfg.smartActions) findEntities();
        }
        status = "ready";
        translate();
    }

    function engineArgs() {
        var a = ["--engine", (forceOnline || cfg.tEngine === "online") ? "online" : "offline"];
        if (cfg.tOnline || onlineOnce) a.push("--allow-online");
        if (cfg.tEmail) a.push("--email", cfg.tEmail);
        return a;
    }

    // ── translate ────────────────────────────────────────
    property var pending: null

    function translate() {
        if (!enabled || original.trim() === "") return;
        var job = { text: original, args: ["python3", "-I", py, "translate", "--src", cfg.tSource || "auto",
                                           "--tgt", tgtLang].concat(engineArgs()) };
        translating = true;
        trError = "";
        if (trProc.running) { pending = job; return; }
        runTranslate(job);
    }

    function runTranslate(job) {
        trProc.input = job.text;
        trProc.command = job.args;
        trProc.stdinEnabled = true;
        trProc.running = true;
    }

    Process {
        id: trProc
        property string input: ""
        stdinEnabled: true
        onStarted: { write(input); stdinEnabled = false; }
        stdout: StdioCollector {
            onStreamFinished: {
                if (tr.pending) {
                    var j = tr.pending; tr.pending = null;
                    tr.runTranslate(j);
                    return;
                }
                tr.translating = false;
                if (tr.status === "idle") return;
                var r = tr.parse(text);
                if (!r) { tr.trError = ScribeStrings.s.trService; return; }
                if (r.ok) {
                    tr.translated = r.text;
                    tr.srcLang = r.src; tr.tgtLang = r.tgt;
                    tr.engineUsed = r.engine; tr.tookMs = r.ms;
                    return;
                }
                tr.needSrc = r.src || tr.srcLang; tr.needTgt = r.tgt || tr.tgtLang;
                if (r.code === "no_model" || r.code === "no_runtime") tr.status = "nomodel";
                else if (r.code === "online_blocked") tr.status = "consent";
                else tr.trError = tr.errText(r.code, r.msg);
            }
        }
    }

    // the read text was corrected: translate it again shortly after typing stops
    function edited(text) {
        original = text;
        retranslate.restart();
        entityTimer.restart();
    }
    Timer { id: retranslate; interval: 900; onTriggered: if (tr.hasTranslation || tr.cfg.autoTranslate) tr.translate() }
    Timer { id: entityTimer; interval: 600; onTriggered: if (tr.cfg.smartActions) tr.findEntities() }

    function swap() {
        if (!hasTranslation) return;
        var a = srcLang;
        original = translated; translated = "";
        srcLang = tgtLang; tgtLang = a;
        translate();
    }

    // ── consent and missing pack ─────────────────────────
    function sendOnce()    { onlineOnce = true; status = "ready"; translate(); }
    function allowAlways() { cfgRequested("tOnline", true); onlineOnce = true; status = "ready"; translate(); }
    function giveUp()      { forceOnline = false; status = "ready"; }
    function useOnline()   { forceOnline = true; status = "ready"; translate(); }
    function closeCard()   { status = "ready"; }

    // ── smart actions ────────────────────────────────────
    function findEntities() {
        entProc.gen = gen;
        entProc.input = original;
        entProc.stdinEnabled = true;
        entProc.command = ["python3", "-I", py, "entities"];
        entProc.running = true;
    }
    Process {
        id: entProc
        property int gen: 0
        property string input: ""
        stdinEnabled: true
        onStarted: { write(input); stdinEnabled = false; }
        stdout: StdioCollector {
            onStreamFinished: {
                var r = tr.parse(text);
                if (r && r.ok && entProc.gen === tr.gen) tr.entities = r.entities;
            }
        }
    }

    function entityLabel(e) {
        var v = e.value;
        if (e.type === "url") v = v.replace(/^https?:\/\//, "").replace(/^www\./, "");
        return v.length > 30 ? v.substring(0, 29) + "…" : v;
    }
    function entityMark(e) { return e.type === "url" ? "↗" : e.type === "email" ? "@" : e.type === "phone" ? "☎" : "IBAN"; }
    // Only http(s) links and mailto: addresses are ever handed to xdg-open, and the scheme is
    // checked here as well (the href comes from translate.py, which got it from screen text), so
    // a crafted string cannot become an option or another scheme.
    function safeHref(h) {
        return typeof h === "string" && /^(https?:\/\/|mailto:)[^\s\u0000-\u001f]+$/.test(h);
    }

    function runEntity(e) {
        if ((e.type === "url" || e.type === "email") && safeHref(e.href)) {
            Quickshell.execDetached(["xdg-open", e.href]);
            return true;                         // the caller closes the overlay
        }
        copyRequested(e.value);
        return false;
    }

    // ── dictionary (hover) ───────────────────────────────
    property string hoverWord: ""
    property string hoverSide: "orig"        // orig: src → tgt, tr: tgt → src
    property rect hoverRect: Qt.rect(0, 0, 0, 0)
    property bool dictShown: false
    property bool dictLoading: false
    property var dictData: null
    property var dictCache: ({})
    property var lookPending: null
    property string lookKey: ""

    function isLetter(c) { return c !== undefined && c !== "" && c.toLowerCase() !== c.toUpperCase(); }
    function isApos(c) { return c === "'" || c === "’"; }

    // [start, end) of the word at `pos`, or null
    function wordRange(text, pos) {
        var i = pos;
        if (!isLetter(text[i])) {
            if (i > 0 && isLetter(text[i - 1])) i = i - 1; else return null;
        }
        var a = i, b = i;
        while (a > 0 && (isLetter(text[a - 1]) || (isApos(text[a - 1]) && a > 1 && isLetter(text[a - 2])))) a--;
        while (b < text.length - 1 && (isLetter(text[b + 1]) || (isApos(text[b + 1]) && b + 2 < text.length && isLetter(text[b + 2])))) b++;
        return { start: a, end: b + 1 };
    }

    function trimNonLetters(t) {
        var a = 0, b = t.length;
        while (a < b && !isLetter(t[a])) a++;
        while (b > a && !isLetter(t[b - 1])) b--;
        return t.substring(a, b);
    }

    function setHover(word, side, rect) {
        // the dictionary uses the translation model, so it only runs once translation was asked for
        if (!enabled || !cfg.dictionary || status === "idle" || word.length < 2 || word.length > 60) { leaveWord(); return; }
        if (word === hoverWord && side === hoverSide) { leaveTimer.stop(); return; }
        hoverWord = word; hoverSide = side; hoverRect = rect;
        dictShown = false;
        leaveTimer.stop();
        dwellTimer.restart();
    }
    function leaveWord() { if (hoverWord !== "") leaveTimer.restart(); }
    function keepDict() { leaveTimer.stop(); }
    function hideDict() { dwellTimer.stop(); leaveTimer.stop(); dictShown = false; hoverWord = ""; dictData = null; }

    Timer { id: dwellTimer; interval: 350; onTriggered: tr.lookup() }
    Timer { id: leaveTimer; interval: 220; onTriggered: tr.hideDict() }

    function lookup() {
        if (hoverWord === "") return;
        var src = hoverSide === "orig" ? srcLang : tgtLang;
        var dst = hoverSide === "orig" ? tgtLang : srcLang;
        var key = src + "|" + dst + "|" + hoverWord.toLowerCase();
        lookKey = key;
        dictShown = true;
        if (dictCache[key]) { dictData = dictCache[key]; dictLoading = false; return; }
        dictData = null; dictLoading = true;
        var job = { key: key, word: hoverWord, args: ["python3", "-I", py, "lookup", "--src", src, "--tgt", dst].concat(engineArgs()) };
        if (lookProc.running) { lookPending = job; return; }
        runLookup(job);
    }
    function runLookup(job) {
        lookProc.key = job.key;
        lookProc.input = job.word;
        lookProc.command = job.args;
        lookProc.stdinEnabled = true;
        lookProc.running = true;
    }
    Process {
        id: lookProc
        property string key: ""
        property string input: ""
        stdinEnabled: true
        onStarted: { write(input); stdinEnabled = false; }
        stdout: StdioCollector {
            onStreamFinished: {
                var r = tr.parse(text) || { ok: false, code: "offline_failed" };
                if (r.ok || r.code) tr.dictCache[lookProc.key] = r;
                if (tr.lookPending) {
                    var p = tr.lookPending; tr.lookPending = null;
                    tr.runLookup(p);
                    return;
                }
                if (lookProc.key === tr.lookKey) { tr.dictData = r; tr.dictLoading = false; }
            }
        }
    }

    // ── offline pack: status, install, remove (also used by the settings panel) ──
    property var off: null                    // translate.py status, or null while unknown
    property bool installing: false
    property real installPct: 0
    property string installMsg: ""
    property string installError: ""
    readonly property bool offlineReady: off !== null && off.runtime && off.pairs.length >= 2
    readonly property bool offlinePartial: off !== null && !offlineReady && (off.runtime || off.pairs.length > 0)

    function refreshStatus() {
        if (!enabled || statusProc.running) return;
        statusProc.command = ["python3", "-I", py, "status"];
        statusProc.running = true;
    }
    Process {
        id: statusProc
        stdout: StdioCollector { onStreamFinished: { var r = tr.parse(text); if (r && r.ok) tr.off = r; } }
    }

    function installOffline() {
        if (!enabled || installing) return;
        installing = true; installPct = 2; installMsg = ""; installError = "";
        if (status === "nomodel") status = "installing";
        installProc.command = ["python3", "-I", py, "install"];
        installProc.running = true;
    }
    function cancelInstall() {
        installProc.running = false;
        installing = false;
        if (status === "installing") status = "nomodel";
    }
    Process {
        id: installProc
        stdout: SplitParser {
            onRead: line => {
                var r = tr.parse(line);
                if (!r) return;
                if (r.stage === "error") tr.installError = r.msg;
                else { tr.installPct = r.pct; tr.installMsg = r.msg; }
            }
        }
        onExited: code => {
            var was = tr.status === "installing";
            tr.installing = false;
            if (code !== 0 && tr.installError === "") tr.installError = ScribeStrings.s.installFailed;
            tr.refreshStatus();
            if (was) {
                if (code === 0) { tr.status = "ready"; tr.translate(); }
                else tr.status = "nomodel";
            }
        }
    }

    function removeOffline() {
        removeProc.command = ["python3", "-I", py, "remove"];
        removeProc.running = true;
    }
    Process { id: removeProc; onExited: tr.refreshStatus() }

    onEnabledChanged: { if (enabled) refreshStatus(); else reset(); }
}
