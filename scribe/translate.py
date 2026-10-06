#!/usr/bin/env python3
"""scribe çeviri arka ucu: çeviri, kelime sözlüğü, link/IBAN bulma ve çevrimdışı paket yönetimi.

Metin ve kelimeler komut satırından değil STDIN'den gelir: ekrandaki yazı gizli olabilir ve
süreç argümanları /proc/<pid>/cmdline üzerinden başka kullanıcılar tarafından okunabilir.
Ayarlar ScribeHost tarafından argüman olarak verilir; bu betik hiçbir ayar dosyası okumaz.

Komutlar (hepsi tek satırlık JSON yazar, install ilerleme satırları yazar):

  translate [--src S] [--tgt T] [--engine offline|online] [--allow-online] [--email E]
                                stdin'deki metni çevir
  lookup    (aynı bayraklar)    stdin'deki tek kelime: çeviri + alternatifler
  entities                      stdin'deki metinde link/e-posta/telefon/IBAN bul
  status                        çevrimdışı kurulum durumu
  install [--pairs en-tr,tr-en] çevrimdışı çeviri paketini kur
  remove                        çevrimdışı paketi ve ortamı sil
  serve / stop                  model servisi (venv içindeki python ile) / kapat

Çevrimdışı çeviri: ctranslate2 + sentencepiece, Argos Translate modelleriyle, izole bir
ortamda (~/.local/share/scribe-translate/venv); sistem Python'una paket kurmaz. Modeli bellekte
tutan servis ilk çeviride başlar, 2 dakika boşta kalınca kapanır.
"""

import argparse
import contextlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

HOME = os.path.expanduser("~")
DATA_DIR = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.join(HOME, ".local/share")), "scribe-translate"
)
VENV_DIR = os.path.join(DATA_DIR, "venv")
MODELS_DIR = os.path.join(DATA_DIR, "models")
LOG_PATH = os.path.join(DATA_DIR, "daemon.log")
# Like the rest of scribe there is deliberately no /tmp fallback: without an owner-only runtime
# directory the service socket is not created at all.
RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "")
SOCK_PATH = os.path.join(RUNTIME_DIR, "scribe-translate.sock")


def runtime_dir_ok():
    return (
        bool(RUNTIME_DIR)
        and os.path.isdir(RUNTIME_DIR)
        and os.stat(RUNTIME_DIR).st_uid == os.getuid()
    )


IDLE_SECONDS = 120
# Everything the offline engine installs is pinned: exact package versions (wheels only) and the
# SHA-256 of each model archive, so a changed upstream file is refused instead of unpacked.
ALLOWED_HOSTS = {"argos-net.com"}
MAX_MODEL_BYTES = 200 * 1024 * 1024
MAX_UNPACKED_BYTES = 400 * 1024 * 1024
PIP_REQUIREMENTS = ("ctranslate2==4.8.2", "sentencepiece==0.2.2", "numpy==2.5.3", "pyyaml==6.0.3")
MODELS_INDEX = {
    "en-tr": {
        "url": "https://argos-net.com/v1/translate-en_tr-1_5.argosmodel",
        "size": 124742526,
        "sha256": "2d553a00880a0c21dea5b1c375535659e6bf18c9bf2ce9847c2a2fd2ff50316a",
    },
    "tr-en": {
        "url": "https://argos-net.com/v1/translate-tr_en-1_5.argosmodel",
        "size": 120561223,
        "sha256": "15217905586561fac843efb5730aabff9a1534d5a9aa3f6ebcc0f9641394ac2d",
    },
}
DEFAULT_PAIRS = ("en-tr", "tr-en")


def make_cfg(args):
    """Ayarlar çağıran tarafından (ScribeHost) argüman olarak verilir; bu betik dosya okumaz."""
    return {
        "engine": getattr(args, "engine", None) or "offline",
        "source": getattr(args, "src", None) or "auto",
        "target": getattr(args, "tgt", None) or "tr",
        "onlineEmail": getattr(args, "email", None) or "",
    }


def emit(obj, code=0):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    sys.exit(code)


def fail(code, msg, **extra):
    emit(dict(ok=False, code=code, msg=msg, **extra), 1)


# ---------------------------------------------------------------------------
# Dil tespiti ve varlık (link, e-posta, telefon, IBAN) bulma
# ---------------------------------------------------------------------------
_TR_WORDS = {
    "ve",
    "bir",
    "bu",
    "için",
    "ile",
    "de",
    "da",
    "mi",
    "mı",
    "ne",
    "çok",
    "gibi",
    "olarak",
    "daha",
    "var",
    "yok",
    "ama",
    "ben",
    "sen",
    "biz",
    "şu",
    "en",
    "her",
    "kadar",
    "sonra",
    "önce",
    "ise",
    "veya",
    "değil",
    "olan",
    "bunu",
    "şey",
}
_EN_WORDS = {
    "the",
    "and",
    "of",
    "to",
    "is",
    "in",
    "that",
    "it",
    "for",
    "with",
    "as",
    "on",
    "are",
    "this",
    "be",
    "from",
    "was",
    "not",
    "or",
    "by",
    "at",
    "an",
    "have",
    "you",
    "when",
    "will",
    "which",
    "your",
    "can",
    "has",
}


def detect_lang(text, default="en"):
    """Yalnızca en/tr ayırt eder; kanıt yoksa `default` döner (None verilebilir)."""
    words = re.findall(r"[^\W\d_]+", text.lower())
    tr = sum(1 for w in words if w in _TR_WORDS)
    en = sum(1 for w in words if w in _EN_WORDS)
    tr += 3 * len(re.findall(r"[çğışöüÇĞİŞÖÜ]", text)) // 2
    if tr == en:
        return default
    return "tr" if tr > en else "en"


_URL_RE = re.compile(r"(?:https?://|www\.)[^\s<>\"']+", re.I)
_MAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
_PHONE_RE = re.compile(r"(?<![\w@])\+?\d[\d\s().-]{8,}\d(?![\w@])")
_IBAN_RE = re.compile(r"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,4})?\b")


def _iban_ok(value):
    s = re.sub(r"\s", "", value).upper()
    if not 15 <= len(s) <= 34:
        return False
    moved = s[4:] + s[:4]
    digits = "".join(str(int(c, 36)) for c in moved)
    return int(digits) % 97 == 1


def _entity_spans(text):
    """(başlangıç, bitiş, tür, değer, extra) listesi; çakışanlar elenir."""
    spans = []

    def free(a, b):
        return not any(a < e and s < b for s, e, *_ in spans)

    for m in _URL_RE.finditer(text):
        v = m.group(0).rstrip(".,;:!?)]}'\"")
        a, b = m.start(), m.start() + len(v)
        if free(a, b):
            spans.append(
                (a, b, "url", v, dict(href=v if v.lower().startswith("http") else "https://" + v))
            )
    for m in _MAIL_RE.finditer(text):
        v = m.group(0).rstrip(".,")
        a, b = m.start(), m.start() + len(v)
        if free(a, b):
            spans.append((a, b, "email", v, dict(href="mailto:" + v)))
    for m in _IBAN_RE.finditer(text):
        if _iban_ok(m.group(0)) and free(m.start(), m.end()):
            spans.append((m.start(), m.end(), "iban", re.sub(r"\s", "", m.group(0)), {}))
    for m in _PHONE_RE.finditer(text):
        v = m.group(0).strip()
        digits = re.sub(r"\D", "", v)
        if 10 <= len(digits) <= 15 and free(m.start(), m.end()):
            spans.append(
                (
                    m.start(),
                    m.end(),
                    "phone",
                    v,
                    dict(href="tel:" + ("+" if v.startswith("+") else "") + digits),
                )
            )
    return sorted(spans, key=lambda t: t[0])


def find_entities(text):
    out, seen = [], set()
    for _a, _b, kind, value, extra in _entity_spans(text):
        if (kind, value) not in seen:
            seen.add((kind, value))
            out.append(dict(type=kind, value=value, **extra))
    return out


def mask_entities(text):
    """Bağlantı, e-posta, IBAN ve telefonu çeviriden koru: model "example"ı bile çeviriyor
    (example.com → ör.com). X1X biçimli yer tutucular ekleriyle birlikte sağlam geçiyor."""
    spans = _entity_spans(text)
    if not spans:
        return text, []
    out, last, values = [], 0, []
    for a, b, _kind, _value, _extra in spans:
        out.append(text[last:a])
        values.append(text[a:b])
        out.append(f"X{len(values)}X")
        last = b
    out.append(text[last:])
    return "".join(out), values


def unmask_entities(text, values):
    return re.sub(
        r"X(\d+)X",
        lambda m: values[int(m.group(1)) - 1] if 0 < int(m.group(1)) <= len(values) else m.group(0),
        text,
    )


# ---------------------------------------------------------------------------
# Çevrimiçi çeviri (MyMemory, belgelenmiş ücretsiz API) — yalnızca izinle
#
# Google'ın resmi olmayan uç noktası denendi ama bu ortamda CAPTCHA/429 ile
# engellendi; MyMemory anahtarsız çalışıyor, ayrıca kelime için alternatif
# çeviriler de dönüyor. Sınırlar: istek başına 500 karakter, günde ~5000
# karakter (ayarlardaki e-posta ile 50.000).
# ---------------------------------------------------------------------------
def _mymemory(text, src, tgt, email=""):
    pair = f"{'Autodetect' if src == 'auto' else src}|{tgt}"
    q = [("q", text), ("langpair", pair)]
    if email:
        q.append(("de", email))
    req = urllib.request.Request(
        "https://api.mymemory.translated.net/get?" + urllib.parse.urlencode(q),
        headers={"User-Agent": "scribe"},
    )
    with urllib.request.urlopen(req, timeout=12) as r:  # noqa: S310  (fixed https URL)
        data = json.loads(r.read().decode("utf-8"))
    if data.get("quotaFinished"):
        raise OSError("günlük çeviri kotası doldu (ayarlara e-posta ekleyerek artırabilirsin)")
    if str(data.get("responseStatus")) != "200":
        raise OSError(str(data.get("responseDetails") or "bilinmeyen hata"))
    return data


def _chunks(text, limit=450):
    out, cur = [], ""
    for sent in re.split(r"(?<=[.!?…])\s+|\n+", text):
        if not sent.strip():
            continue
        if cur and len(cur) + len(sent) + 1 > limit:
            out.append(cur)
            cur = ""
        cur = (cur + " " + sent).strip()
    if cur:
        out.append(cur)
    return out or [text[:limit]]


def online_translate(text, src, tgt, email="", word=False):
    import html

    if word:
        data = _mymemory(text, src, tgt, email)
        best = html.unescape(data["responseData"]["translatedText"])
        alts = []
        for m in data.get("matches", []):
            t = html.unescape(str(m.get("translation", ""))).strip()
            if (
                t
                and t.lower() != best.lower()
                and t.lower() not in [a.lower() for a in alts]
                and len(t) < 40
            ):
                alts.append(t)
        return best, alts[:5], [], src
    out, detected = [], src
    for chunk in _chunks(text):
        data = _mymemory(chunk, src, tgt, email)
        out.append(html.unescape(data["responseData"]["translatedText"]))
        detected = data["responseData"].get("detectedLanguage") or detected
    return " ".join(out), [], [], (detected if detected != "auto" else src)


# ---------------------------------------------------------------------------
# Çevrimdışı motor (servisin içinde çalışır)
# ---------------------------------------------------------------------------
def model_dir_for(pair):
    base = os.path.join(MODELS_DIR, pair)
    for root, _dirs, files in os.walk(base):
        if "model.bin" in files:
            return root
    return None


def sp_path_for(pair):
    base = os.path.join(MODELS_DIR, pair)
    for root, _dirs, files in os.walk(base):
        if "sentencepiece.model" in files:
            return os.path.join(root, "sentencepiece.model")
    return None


def installed_pairs():
    if not os.path.isdir(MODELS_DIR):
        return []
    return sorted(p for p in os.listdir(MODELS_DIR) if model_dir_for(p) and sp_path_for(p))


def _target_prefix(pair):
    base = os.path.join(MODELS_DIR, pair)
    for root, _dirs, files in os.walk(base):
        if "metadata.json" in files:
            try:
                with open(os.path.join(root, "metadata.json"), encoding="utf-8") as f:
                    return json.load(f).get("target_prefix") or None
            except (OSError, ValueError):
                return None
    return None


_SENT_SPLIT = re.compile(r"(?<=[.!?…])\s+(?=\S)")


class Engine:
    def __init__(self):
        self.loaded = {}

    def _load(self, pair):
        if pair in self.loaded:
            return self.loaded[pair]
        import ctranslate2
        import sentencepiece

        mdir, sp = model_dir_for(pair), sp_path_for(pair)
        if not mdir or not sp:
            raise FileNotFoundError(pair)
        threads = max(2, (os.cpu_count() or 4) // 2)
        tr = ctranslate2.Translator(mdir, device="cpu", intra_threads=threads, inter_threads=1)
        proc = sentencepiece.SentencePieceProcessor(model_file=sp)
        self.loaded[pair] = (tr, proc, _target_prefix(pair))
        return self.loaded[pair]

    def _run(self, pair, sentences, nbest=1, short=False):
        tr, sp, prefix = self._load(pair)
        batch = [sp.encode(s, out_type=str) for s in sentences]
        kw = dict(
            beam_size=max(4, nbest), num_hypotheses=nbest, max_decoding_length=24 if short else 300
        )
        if prefix:
            kw["target_prefix"] = [[prefix]] * len(batch)
        results = tr.translate_batch(batch, **kw)
        out = []
        for r in results:
            hyps = []
            for h in r.hypotheses:
                toks = h[1:] if prefix and h and h[0] == prefix else h
                hyps.append(sp.decode(toks).strip())
            out.append(hyps)
        return out

    def translate(self, text, pair, nbest=1):
        paragraphs = [p for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
        sentences, layout = [], []
        for para in paragraphs:
            para = re.sub(r"\s*\n\s*", " ", para.strip())
            parts = [s for s in _SENT_SPLIT.split(para) if s.strip()]
            layout.append(len(parts))
            sentences.extend(parts)
        if not sentences:
            return "", []
        if nbest > 1 and len(sentences) == 1:
            # Tek kelimeyi cümle gibi vermezsek model kelimeyi tekrarlayıp duruyor
            # ("düzen düzeni düzeni"); sona nokta eklemek bunu tamamen çözüyor.
            word = sentences[0]
            lower = word[:1].islower()
            hyps = self._run(pair, [word + "."], nbest, short=True)[0]
            clean = []
            for h in hyps:
                h = h.rstrip(".").strip()
                if lower and h:
                    h = ("i" if h[0] == "İ" else h[0].lower()) + h[1:]
                h = h.replace("\u0307", "")
                if h and h.lower() not in [c.lower() for c in clean]:
                    clean.append(h)
            if not clean:
                return word, []
            return clean[0], clean[1:]
        done = [h[0] for h in self._run(pair, sentences)]
        out, i = [], 0
        for n in layout:
            out.append(" ".join(done[i : i + n]))
            i += n
        return "\n\n".join(out), []


def serve():
    if not runtime_dir_ok():
        sys.exit(70)
    os.makedirs(DATA_DIR, exist_ok=True)
    if os.path.exists(SOCK_PATH):
        with contextlib.suppress(OSError):
            os.unlink(SOCK_PATH)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(SOCK_PATH)
    os.chmod(SOCK_PATH, 0o600)
    srv.listen(8)
    srv.settimeout(5)
    eng = Engine()
    last = time.time()
    try:
        while time.time() - last < IDLE_SECONDS:
            try:
                conn, _ = srv.accept()
            except TimeoutError:
                continue
            last = time.time()
            with conn:
                conn.settimeout(30)
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    buf += chunk
                try:
                    req = json.loads(buf.decode("utf-8"))
                    op = req.get("op")
                    if op == "ping":
                        resp = dict(ok=True, pairs=sorted(eng.loaded), pid=os.getpid())
                    elif op == "stop":
                        conn.sendall(b'{"ok":true}\n')
                        break
                    elif op == "translate":
                        t0 = time.time()
                        text, alts = eng.translate(
                            req["text"], req["pair"], int(req.get("nbest", 1))
                        )
                        resp = dict(
                            ok=True, text=text, alts=alts, ms=round((time.time() - t0) * 1000)
                        )
                    else:
                        resp = dict(ok=False, msg="bilinmeyen işlem")
                except Exception as e:  # noqa: BLE001 - istemciye düzgün hata dön
                    resp = dict(ok=False, msg=f"{type(e).__name__}: {e}")
                conn.sendall((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
                last = time.time()
    finally:
        srv.close()
        with contextlib.suppress(OSError):
            os.unlink(SOCK_PATH)


def _daemon_call(req, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(SOCK_PATH)
    with s:
        s.sendall((json.dumps(req, ensure_ascii=False) + "\n").encode("utf-8"))
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    return json.loads(buf.decode("utf-8"))


def venv_python():
    py = os.path.join(VENV_DIR, "bin", "python")
    return py if os.path.exists(py) else None


def _ping():
    try:
        _daemon_call(dict(op="ping"), timeout=3)
        return True
    except (OSError, ValueError):
        return False


def ensure_daemon():
    if _ping():
        return True
    py = venv_python()
    if not py or not runtime_dir_ok():
        return False
    os.makedirs(DATA_DIR, exist_ok=True)
    # Çeviri ve kelime sorgusu aynı anda gelirse iki servis açılmasın.
    import fcntl

    with open(os.path.join(DATA_DIR, "daemon.lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if _ping():
            return True
        with open(LOG_PATH, "ab") as log:
            subprocess.Popen(
                [py, "-I", os.path.abspath(__file__), "serve"],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
            )
        for _ in range(750):
            time.sleep(0.02)
            if _ping():
                return True
    return False


# ---------------------------------------------------------------------------
# Çeviri ve sözlük komutları
# ---------------------------------------------------------------------------
def resolve_pair(cfg, text):
    src, tgt = cfg["source"], cfg["target"]
    if src == "auto":
        # Çevrimiçi motor dili kendisi bulabilir; kanıt yoksa ona bırak.
        src = detect_lang(text, default=None if cfg["engine"] == "online" else "en") or "auto"
    if src == tgt:
        tgt = "en" if src != "en" else "tr"
    return src, tgt


def do_translate(text, src, tgt, cfg, allow_online, word=False):
    """Seçilen motorla çevir. Dönüş: (text, alts, defs, engine, ms, src)."""
    pair = f"{src}-{tgt}"
    t0 = time.time()
    values = []
    if not word:
        text, values = mask_entities(text)
    if cfg["engine"] != "online":
        if pair not in installed_pairs():
            fail("no_model", f"{src.upper()} → {tgt.upper()} paketi kurulu değil", src=src, tgt=tgt)
        if not venv_python():
            fail("no_runtime", "Çevrimdışı çeviri ortamı kurulu değil", src=src, tgt=tgt)
        if not ensure_daemon():
            fail("offline_failed", f"Çeviri servisi başlamadı (bkz. {LOG_PATH})", src=src, tgt=tgt)
        try:
            r = _daemon_call(
                dict(op="translate", pair=pair, text=text, nbest=5 if word else 1), timeout=60
            )
        except (OSError, ValueError) as e:
            fail("offline_failed", f"Çeviri servisi yanıt vermedi: {e}", src=src, tgt=tgt)
        if not r.get("ok"):
            fail("offline_failed", r.get("msg", "bilinmeyen hata"), src=src, tgt=tgt)
        alts = [
            a
            for a in dict.fromkeys(r.get("alts", []))
            if a.lower().strip(".") != r["text"].lower().strip(".")
        ]
        return (
            unmask_entities(r["text"], values),
            alts,
            [],
            "offline",
            round((time.time() - t0) * 1000),
            src,
        )
    if not allow_online:
        fail("online_blocked", "Çevrimiçi çeviri için izin gerekli", src=src, tgt=tgt)
    try:
        out, alts, defs, detected = online_translate(text, src, tgt, cfg["onlineEmail"], word)
    except (urllib.error.URLError, OSError, ValueError) as e:
        fail("network", f"Çevrimiçi çeviri başarısız: {e}", src=src, tgt=tgt)
    return (
        unmask_entities(out, values),
        alts,
        defs,
        "online",
        round((time.time() - t0) * 1000),
        detected,
    )


MAX_STDIN = 256 * 1024  # ekran metni bunun çok altında; üst sınır savunma için


def read_stdin():
    return sys.stdin.read(MAX_STDIN)


def cmd_translate(args):
    cfg = make_cfg(args)
    text = read_stdin()
    if not text.strip():
        fail("no_text", "Çevrilecek metin yok")
    src, tgt = resolve_pair(cfg, text)
    out, alts, defs, engine, ms, src = do_translate(text, src, tgt, cfg, args.allow_online)
    emit(dict(ok=True, text=out, src=src, tgt=tgt, engine=engine, ms=ms))


def cmd_lookup(args):
    cfg = make_cfg(args)
    word = read_stdin().strip().strip(".,;:!?()[]{}\"'«»“”‘’")
    if not word or len(word) > 80:
        fail("no_text", "Kelime boş ya da çok uzun")
    src, tgt = resolve_pair(cfg, word)
    query = word if word.isupper() and len(word) > 1 else word.lower()
    out, alts, defs, engine, ms, src = do_translate(
        query, src, tgt, cfg, args.allow_online, word=True
    )
    # Model bilmediği kelimeyi aynen döndürüp uydurma alternatifler üretiyor
    # (compositor → koositor, kotaor); böyle durumda alternatif gösterme.
    same = out.strip().lower() == word.lower()
    if same:
        alts = []
    emit(
        dict(
            ok=True,
            word=word,
            text=out,
            alts=alts,
            defs=defs,
            same=same,
            src=src,
            tgt=tgt,
            engine=engine,
            ms=ms,
        )
    )


# ---------------------------------------------------------------------------
# Durum, kurulum, kaldırma
# ---------------------------------------------------------------------------
def dir_size_mb(path):
    total = 0
    for root, _d, files in os.walk(path):
        for f in files:
            with contextlib.suppress(OSError):
                total += os.path.getsize(os.path.join(root, f))
    return round(total / 1048576, 1)


def runtime_ok():
    """Ortam kurulu mu? Modülleri içe aktarmak 0,2 sn sürüyor; paket klasörlerinin varlığı yetiyor
    (servis yine de başlamazsa çeviri 'offline_failed' ile bunu bildirir)."""
    if not venv_python():
        return False
    import glob

    site = glob.glob(os.path.join(VENV_DIR, "lib", "python*", "site-packages"))
    return any(
        os.path.isdir(os.path.join(d, "ctranslate2"))
        and os.path.exists(os.path.join(d, "sentencepiece", "__init__.py"))
        for d in site
    )


def _rss_mb(pid):
    """Sürecin şu an kullandığı bellek (MB), okunamazsa None."""
    try:
        with open(f"/proc/{int(pid)}/status", encoding="utf-8") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return round(int(line.split()[1]) / 1024)
    except (OSError, ValueError, TypeError):
        pass
    return None


def cmd_status(_args):
    daemon, rss = False, None
    try:
        r = _daemon_call(dict(op="ping"), timeout=1)
        daemon = bool(r.get("ok"))
        rss = _rss_mb(r.get("pid"))
    except (OSError, ValueError):
        pass
    pairs = installed_pairs()
    emit(
        dict(
            ok=True,
            runtime=runtime_ok(),
            pairs=pairs,
            wanted=list(DEFAULT_PAIRS),
            daemon=daemon,
            rss_mb=rss,
            size_mb=dir_size_mb(DATA_DIR) if os.path.isdir(DATA_DIR) else 0,
            path=DATA_DIR,
        )
    )


def progress(stage, pct, msg):
    sys.stdout.write(json.dumps(dict(stage=stage, pct=pct, msg=msg), ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _find_model(pair):
    return MODELS_INDEX.get(pair)


class _HttpsOnly(urllib.request.HTTPRedirectHandler):
    """A redirect may only stay on the allowed host over HTTPS."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlparse(newurl)
        if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
            raise urllib.error.URLError(f"redirect to {parts.hostname} refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _download_model(pair, dest_file, lo, say):
    """Fetch one pinned model: HTTPS, one host, a size cap, and the SHA-256 must match."""
    import hashlib

    spec = _find_model(pair)
    if not spec:
        raise RuntimeError(f"{pair}: unknown package")
    parts = urllib.parse.urlparse(spec["url"])
    if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
        raise RuntimeError("model URL is not on an allowed host")
    opener = urllib.request.build_opener(_HttpsOnly)
    req = urllib.request.Request(spec["url"], headers={"User-Agent": "scribe"})  # noqa: S310  (pinned https URL)
    digest = hashlib.sha256()
    a, b = pair.split("-")
    with opener.open(req, timeout=60) as r, open(dest_file, "wb") as f:  # noqa: S310  (pinned https URL)
        total = int(r.headers.get("Content-Length") or 0)
        if total > MAX_MODEL_BYTES:
            raise RuntimeError("model is larger than expected")
        got, last = 0, 0.0
        while True:
            chunk = r.read(262144)
            if not chunk:
                break
            got += len(chunk)
            if got > MAX_MODEL_BYTES:
                raise RuntimeError("model is larger than expected")
            digest.update(chunk)
            f.write(chunk)
            if total and time.time() - last > 0.4:
                last = time.time()
                say(
                    "download",
                    lo + int(30 * got / total),
                    f"{a.upper()} → {b.upper()} ({got // 1048576}/{total // 1048576} MB)",
                )
    if got != spec["size"] or digest.hexdigest() != spec["sha256"]:
        raise RuntimeError(f"{pair}: checksum mismatch, the download was discarded")


def _safe_extract(zip_path, dest):
    """Unpack a model archive without letting it write outside `dest` or grow without bound."""
    with zipfile.ZipFile(zip_path) as z:
        total = 0
        root = os.path.realpath(dest)
        for info in z.infolist():
            target = os.path.realpath(os.path.join(root, info.filename))
            if target != root and not target.startswith(root + os.sep):
                raise RuntimeError("archive entry escapes the target folder")
            total += info.file_size
            if total > MAX_UNPACKED_BYTES:
                raise RuntimeError("archive unpacks to more than expected")
        z.extractall(dest)  # noqa: S202  (every entry was checked above)


def cmd_install(args):
    pairs = [p for p in (args.pairs or ",".join(DEFAULT_PAIRS)).split(",") if p]
    os.makedirs(MODELS_DIR, exist_ok=True)
    try:
        if not venv_python() or not runtime_ok():
            progress("venv", 3, "Preparing the Python environment")
            subprocess.run(
                [sys.executable, "-m", "venv", VENV_DIR], check=True, capture_output=True
            )
            progress("pip", 8, "Installing the translation engine (pinned versions)")
            # wheels only (no setup.py is ever run), pinned versions, and --isolated so a user's pip
            # configuration or environment cannot redirect the install
            r = subprocess.run(
                [
                    os.path.join(VENV_DIR, "bin", "pip"),
                    "install",
                    "--isolated",
                    "--quiet",
                    "--disable-pip-version-check",
                    "--no-input",
                    "--only-binary=:all:",
                    *PIP_REQUIREMENTS,
                ],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                raise RuntimeError("pip failed: " + r.stderr.strip()[-300:])
        for n, pair in enumerate(pairs):
            if pair in installed_pairs():
                continue
            if not _find_model(pair):
                raise RuntimeError(f"{pair}: unknown package")
            lo = 30 + n * 35
            tmp = os.path.join(MODELS_DIR, f"{pair}.argosmodel.part")
            try:
                _download_model(pair, tmp, lo, progress)
                progress("unpack", lo + 31, f"{pair}: unpacking")
                dest = os.path.join(MODELS_DIR, pair)
                shutil.rmtree(dest, ignore_errors=True)
                _safe_extract(tmp, dest)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
        stop_daemon()
        progress("done", 100, "Ready")
    except Exception as e:  # noqa: BLE001
        progress("error", 0, f"{type(e).__name__}: {e}")
        sys.exit(1)


def stop_daemon():
    with contextlib.suppress(OSError, ValueError):
        _daemon_call(dict(op="stop"), timeout=3)


def cmd_remove(_args):
    stop_daemon()
    shutil.rmtree(DATA_DIR, ignore_errors=True)
    emit(dict(ok=True))


def cmd_entities(_args):
    emit(dict(ok=True, entities=find_entities(read_stdin())))


def cmd_stop(_args):
    stop_daemon()
    emit(dict(ok=True))


def main():
    ap = argparse.ArgumentParser(prog="translate.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("translate", cmd_translate), ("lookup", cmd_lookup)):
        p = sub.add_parser(name)
        p.add_argument("--src")
        p.add_argument("--tgt")
        p.add_argument("--engine", choices=("offline", "online"))
        p.add_argument("--allow-online", action="store_true")
        p.add_argument("--email")
        p.set_defaults(fn=fn)
    sub.add_parser("status").set_defaults(fn=cmd_status)
    p = sub.add_parser("install")
    p.add_argument("--pairs")
    p.set_defaults(fn=cmd_install)
    sub.add_parser("remove").set_defaults(fn=cmd_remove)
    sub.add_parser("stop").set_defaults(fn=cmd_stop)
    sub.add_parser("entities").set_defaults(fn=cmd_entities)
    sub.add_parser("serve").set_defaults(fn=lambda _a: serve())
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
