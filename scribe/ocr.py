#!/usr/bin/env python3
"""scribe OCR: crop, clean up and read a screen region with tesseract, fast.

usage: ocr.py <png> <x> <y> <w> <h> <scale> <langs>

The crop is cut into horizontal strips at blank pixel rows and the strips are read by
separate tesseract processes at the same time (tesseract itself is single threaded here,
so this is where the speed comes from).

stdout: one `W<TAB>par<TAB>line<TAB>x<TAB>y<TAB>w<TAB>h<TAB>word` per word (logical px,
relative to the crop), then `CONF<TAB><0-100>`. Failures print `ERR<TAB><reason>`:
nolang (no requested language pack installed, exit 2), badregion, badimage, fail.

Memory is bounded on purpose: the crop is capped in pixels, the image decoder has a pixel
limit, every tesseract run has a timeout, and at most MAX_WORDS words are returned.
"""
import math
import os
import subprocess  # noqa: S404  (argument lists only, never a shell)
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image, ImageOps

sys.dont_write_bytecode = True      # never leave __pycache__ inside the installed module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import langs as langpacks  # noqa: E402  (installed languages, system + user dir)

Image.MAX_IMAGE_PIXELS = 120_000_000        # refuse decompression bombs

MIN_WORD_CONF = 40
UPSCALE_BELOW = 150_000     # px area: small selections are read at 2x
RETRY_BELOW_CONF = 60
RETRY_MAX_AREA = 1_500_000
MIN_STRIP = 70              # px, never cut thinner than this
MAX_STRIPS = 12
MAX_CROP_PIXELS = 36_000_000   # about a 4K screen
MAX_WORDS = 4000
MAX_WORD_CHARS = 120
STRIP_TIMEOUT = 60          # seconds per tesseract run


def runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR", "")
    return os.path.realpath(os.path.join(base, "scribe")) if base else ""


def allowed_image(path):
    """Only read the screenshot scribe itself took (or anything, in explicit dev mode)."""
    if os.environ.get("SCRIBE_DEV") == "1":
        return True
    rt = runtime_dir()
    real = os.path.realpath(path)
    return bool(rt) and os.path.dirname(real) == rt


def split_rows(gray, n):
    """Row indices where to cut `gray` into n strips, preferring blank rows."""
    h = gray.shape[0]
    if n <= 1:
        return [0, h]
    ptp = gray.max(axis=1).astype(int) - gray.min(axis=1).astype(int)
    blank = ptp < 28
    cuts = [0]
    span = h / n
    for k in range(1, n):
        target = int(span * k)
        lo = max(cuts[-1] + MIN_STRIP, target - int(span * 0.4))
        hi = min(h - MIN_STRIP, target + int(span * 0.4))
        if lo >= hi:
            continue
        window = np.arange(lo, hi)
        good = window[blank[lo:hi]]
        if good.size:
            cut = int(good[np.argmin(np.abs(good - target))])
        else:
            cut = int(window[np.argmin(ptp[lo:hi])])
        cuts.append(cut)
    cuts.append(h)
    return cuts


def tessdata_args(langs, tmp):
    """Extra tesseract args. Packs in the user dir win over system ones; when any comes from
    there, tesseract gets a small tessdata dir of symlinks to the chosen files."""
    sysdir = langpacks.system_dir()
    chosen, from_user = {}, False
    for code in langs.split("+"):
        user_file = os.path.join(langpacks.USER_DIR, f"{code}.traineddata")
        if os.path.isfile(user_file) and not os.path.islink(user_file):
            chosen[code], from_user = user_file, True
        else:
            chosen[code] = os.path.join(sysdir, f"{code}.traineddata")
    if not from_user:
        return []
    d = os.path.join(tmp, "tessdata")
    os.makedirs(d, exist_ok=True)
    for code, path in chosen.items():
        os.symlink(path, os.path.join(d, f"{code}.traineddata"))
    for extra in ("configs", "tessconfigs"):          # `tsv` output is a config file
        if os.path.exists(os.path.join(sysdir, extra)):
            os.symlink(os.path.join(sysdir, extra), os.path.join(d, extra))
    return ["--tessdata-dir", d]


def clean_word(text):
    text = "".join(ch for ch in text if ch.isprintable()).strip()
    return text[:MAX_WORD_CHARS]


def read_strip(job):
    idx, img, y_off, up, scale, langs, tmp, extra, tess = job
    path = os.path.join(tmp, f"s{idx}.png")
    img.save(path)
    env = dict(os.environ, OMP_THREAD_LIMIT="1")
    try:
        out = subprocess.run(
            [tess, path, "stdout", "-l", langs, "--oem", "1", "--psm", "6",
             "-c", "tessedit_do_invert=0", "tsv", *extra],
            capture_output=True, text=True, env=env, timeout=STRIP_TIMEOUT, check=False,
        ).stdout
    except subprocess.TimeoutExpired:
        return [], []
    f = scale * up
    words, confs = [], []
    for row in out.split("\n")[1:]:
        c = row.split("\t")
        if len(c) < 12 or c[0] != "5":
            continue
        text = clean_word(c[11])
        try:
            conf = float(c[10])
            left, top, width, height = int(c[6]), int(c[7]), int(c[8]), int(c[9])
        except ValueError:
            continue
        if not text or conf < MIN_WORD_CONF:
            continue
        confs.append(conf)
        words.append((f"{idx}-{c[2]}-{c[3]}", f"{idx}-{c[2]}-{c[3]}-{c[4]}",
                      left / f, (top + y_off) / f, width / f, height / f, text))
    return words, confs


def run(gray, up, scale, langs, workers, tmp, extra, tess):
    h = gray.shape[0]
    area = gray.shape[0] * gray.shape[1]
    n = 1 if area < UPSCALE_BELOW else max(1, min(workers, MAX_STRIPS, h // MIN_STRIP))
    cuts = split_rows(gray, n)
    img = Image.fromarray(gray)
    if up != 1:
        img = img.resize((img.width * up, img.height * up), Image.LANCZOS)
    jobs = []
    for i in range(len(cuts) - 1):
        y0, y1 = cuts[i] * up, cuts[i + 1] * up
        jobs.append((i, img.crop((0, y0, img.width, y1)), y0, up, scale, langs, tmp, extra, tess))
    words, confs = [], []
    with ThreadPoolExecutor(max_workers=len(jobs)) as ex:
        for w, c in ex.map(read_strip, jobs):
            words += w
            confs += c
    return words[:MAX_WORDS], (sum(confs) / len(confs) if confs else 0)


def parse_region(args):
    try:
        x, y, w, h, scale = (float(v) for v in args)
    except ValueError:
        return None
    if not all(math.isfinite(v) for v in (x, y, w, h, scale)):
        return None
    if w < 1 or h < 1 or scale < 0.25 or scale > 8:
        return None
    return x, y, w, h, scale


def main():
    if len(sys.argv) != 8:
        print("ERR\tusage")
        return 64
    png, want = sys.argv[1], sys.argv[7]
    region = parse_region(sys.argv[2:7])
    if region is None:
        print("ERR\tbadregion")
        return 64
    x, y, w, h, scale = region
    if not allowed_image(png):
        print("ERR\tbadimage")
        return 64

    have = set(langpacks.installed())
    wanted = [lang for lang in want.split("+") if langpacks.valid_code(lang) and lang in have]
    if not wanted:
        print("ERR\tnolang")
        return 2
    langs = "+".join(wanted)

    tess = langpacks.shutil.which("tesseract")
    if not tess:
        print("ERR\tfail")
        return 1

    try:
        full = Image.open(png).convert("L")
        left, top = max(0, int(x * scale)), max(0, int(y * scale))
        right = min(full.width, int((x + w) * scale))
        bottom = min(full.height, int((y + h) * scale))
        pixels = (right - left) * (bottom - top)
        if right - left < 2 or bottom - top < 2 or pixels > MAX_CROP_PIXELS:
            print("ERR\tbadregion")
            return 64
        img = full.crop((left, top, right, bottom))
        del full
        if np.asarray(img).mean() < 128:          # light text on dark: flip it
            img = ImageOps.invert(img)
        gray = np.asarray(ImageOps.autocontrast(img))
        area = gray.shape[0] * gray.shape[1]
        workers = min(os.cpu_count() or 4, MAX_STRIPS)

        with tempfile.TemporaryDirectory(prefix="scribe-") as tmp:
            extra = tessdata_args(langs, tmp)
            up = 2 if area < UPSCALE_BELOW else 1
            words, conf = run(gray, up, scale, langs, workers, tmp, extra, tess)
            if up == 1 and conf < RETRY_BELOW_CONF and area < RETRY_MAX_AREA:
                words2, conf2 = run(gray, 2, scale, langs, workers, tmp, extra, tess)
                if conf2 > conf:
                    words, conf = words2, conf2
    except (OSError, ValueError, MemoryError):
        print("ERR\tfail")
        return 1

    for par, line, wx, wy, ww, wh, text in words:
        print(f"W\t{par}\t{line}\t{wx:.1f}\t{wy:.1f}\t{ww:.1f}\t{wh:.1f}\t{text}")
    print(f"CONF\t{int(conf)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
