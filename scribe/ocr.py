#!/usr/bin/env python3
"""scribe OCR: crop, clean up and read a screen region with tesseract, fast and robust.

usage: ocr.py <png> <x> <y> <w> <h> <scale> <langs>

stdout: one `W<TAB>par<TAB>line<TAB>x<TAB>y<TAB>w<TAB>h<TAB>word` per word (logical px,
relative to the crop, in reading order), then `CONF<TAB><0-100>`. Failures print
`ERR<TAB><reason>`: nolang (no requested language pack installed, exit 2), badregion,
badimage, fail.

How it reads
  1. A fast first pass: grayscale, polarity guessed from the mean brightness, the crop cut
     into strips at blank pixel rows and read by parallel tesseract processes.
  2. If that pass explains most of the "ink" (edges) in the crop, we are done. Plain pages
     take this path and cost the same as before.
  3. Otherwise the crop is hard (gradients, busy backgrounds, huge or script type, both
     light-on-dark and dark-on-light text). The extra passes read it with both polarities, at
     two scales and in two page modes (block and sparse text). The best pass wins, and words
     from the others are added only when they sit where the winner found nothing.
  4. Words are put into reading order from their geometry (columns are kept apart) and
     numbered into lines and paragraphs.

Memory is bounded on purpose: the crop is capped in pixels, the image decoder has a pixel
limit, every tesseract run has a timeout, the number of reading passes is fixed, and at most
MAX_WORDS words are returned.
"""
import math
import os
import statistics
import subprocess  # noqa: S404  (argument lists only, never a shell)
import sys
import tempfile
from collections import namedtuple
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image, ImageOps

sys.dont_write_bytecode = True      # never leave __pycache__ inside the installed module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import langs as langpacks  # noqa: E402  (installed languages, system + user dir)

Image.MAX_IMAGE_PIXELS = 120_000_000        # refuse decompression bombs

Word = namedtuple("Word", "text conf x y w h")   # x, y, w, h in crop pixels

MIN_WORD_CONF = 40
SUPPLEMENT_CONF = 70        # words added from a losing pass must be this sure
UPSCALE_BELOW = 150_000     # px area: small selections are read at 2x
COVERAGE_OK = 0.85          # fraction of ink the first pass must explain to skip the extra passes
INK_EDGE = 70               # gradient strength that counts as ink
CELL = 32                   # px, grid used to find pockets of unexplained ink
CELL_INK = 0.10             # share of ink pixels that makes a cell "dense"
CELL_LIMIT = 4              # this many dense unexplained cells also trigger the extra passes
MIN_STRIP = 70              # px, never cut thinner than this
EXTRA_STRIP = 140           # extra passes use fewer, taller strips
MAX_STRIPS = 12
MAX_CROP_PIXELS = 36_000_000   # about a 4K screen
MAX_WORDS = 4000
MAX_WORD_CHARS = 120
STRIP_TIMEOUT = 60          # seconds per tesseract run


# ── safety ──────────────────────────────────────────────────────────────────
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


# ── image helpers ───────────────────────────────────────────────────────────
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


def luminance(rgb):
    return (rgb[..., 0] * 0.299 + rgb[..., 1] * 0.587 + rgb[..., 2] * 0.114).astype(np.uint8)


def stretch(gray):
    return np.asarray(ImageOps.autocontrast(Image.fromarray(gray)))


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


# ── reading ─────────────────────────────────────────────────────────────────
def clean_word(text):
    text = "".join(ch for ch in text if ch.isprintable()).strip()
    return text[:MAX_WORD_CHARS]


def read_strip(job):
    idx, img, y_off, up, psm, langs, tmp, extra, tess = job
    path = os.path.join(tmp, f"s{idx}.png")
    img.save(path)
    env = dict(os.environ, OMP_THREAD_LIMIT="1")
    try:
        out = subprocess.run(
            [tess, path, "stdout", "-l", langs, "--oem", "1", "--psm", str(psm),
             "-c", "tessedit_do_invert=0", "tsv", *extra],
            capture_output=True, text=True, env=env, timeout=STRIP_TIMEOUT, check=False,
        ).stdout
    except subprocess.TimeoutExpired:
        return []
    words = []
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
        words.append(Word(text, conf, left / up, (top + y_off) / up, width / up, height / up))
    return words


def read_pass(gray, up, psm, strips, langs, tmp, extra, tess, tag):
    """Read one preprocessed grayscale crop. `up` is the scale applied before tesseract."""
    cuts = split_rows(gray, strips)
    img = Image.fromarray(gray)
    if up != 1.0:
        size = (max(8, int(img.width * up)), max(8, int(img.height * up)))
        img = img.resize(size, Image.LANCZOS)
    jobs = []
    for i in range(len(cuts) - 1):
        y0, y1 = int(cuts[i] * up), int(cuts[i + 1] * up)
        piece = img.crop((0, y0, img.width, y1))
        jobs.append((f"{tag}{i}", piece, y0, up, psm, langs, tmp, extra, tess))
    return jobs


def run_jobs(jobs, pool):
    words = []
    for part in pool.map(read_strip, jobs):
        words += part
    return words


# ── quality ─────────────────────────────────────────────────────────────────
def alpha_ratio(text):
    return sum(ch.isalnum() for ch in text) / max(1, len(text))


def plausible(w):
    """Drop what is almost certainly noise: stray marks and one-letter 'words'."""
    if w.w < 3 or w.h < 5:
        return False
    if len(w.text) == 1 and w.conf < 85:
        return False
    return alpha_ratio(w.text) >= 0.5 or w.conf >= 85


def quality(words):
    """Higher is better: confident, letter-like, longer words count more."""
    return sum((w.conf / 100) ** 2 * min(len(w.text), 8) * alpha_ratio(w.text)
               for w in words if plausible(w))


def uncovered_ink(lum, words):
    """-> (coverage, cells). coverage is the fraction of the crop's edge pixels ('ink') inside a
    detected word box; cells counts CELL-sized squares that still hold dense, unexplained ink
    (a small button label next to a big headline barely moves the coverage, but shows up here)."""
    li = lum.astype(np.int16)
    ink = (np.abs(np.diff(li, axis=1))[:-1, :] + np.abs(np.diff(li, axis=0))[:, :-1]) > INK_EDGE
    total = int(ink.sum())
    if total < 60:
        return 1.0, 0
    mask = np.zeros(ink.shape, dtype=bool)
    hh, ww = ink.shape
    for w in words:
        x0, y0 = max(0, int(w.x) - 2), max(0, int(w.y) - 2)
        x1, y1 = min(ww, int(w.x + w.w) + 3), min(hh, int(w.y + w.h) + 3)
        if x1 > x0 and y1 > y0:
            mask[y0:y1, x0:x1] = True
    left = ink & ~mask
    hh2, ww2 = (hh // CELL) * CELL, (ww // CELL) * CELL
    cells = 0
    if hh2 and ww2:
        grid = left[:hh2, :ww2].reshape(hh2 // CELL, CELL, ww2 // CELL, CELL).mean(axis=(1, 3))
        cells = int((grid > CELL_INK).sum())
    return float((ink & mask).sum()) / total, cells


def overlaps(a, b):
    ix = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
    iy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
    if ix <= 0 or iy <= 0:
        return False
    inter = ix * iy
    small = min(a.w * a.h, b.w * b.h)
    return small > 0 and inter / small > 0.3


def merge_passes(passes):
    """passes: {name: [Word]}. The best pass wins; confident words on empty ground are added."""
    ranked = sorted(passes.items(), key=lambda kv: quality(kv[1]), reverse=True)
    chosen = [w for w in ranked[0][1] if plausible(w)]
    for _name, words in ranked[1:]:
        for w in words:
            if w.conf < SUPPLEMENT_CONF or not plausible(w) or alpha_ratio(w.text) < 0.8:
                continue
            if not any(overlaps(w, c) for c in chosen):
                chosen.append(w)
    return chosen


# ── reading order ───────────────────────────────────────────────────────────
def build_lines(words):
    """Group words into lines: same horizontal band, and no wide gap inside a line."""
    if not words:
        return []
    med_h = statistics.median(w.h for w in words)
    order = sorted(words, key=lambda w: w.y + w.h / 2)
    bands, cur, cur_cy = [], [], None
    for w in order:
        cy = w.y + w.h / 2
        if cur and abs(cy - cur_cy) > 0.6 * max(min(w.h, statistics.median(x.h for x in cur)), 4):
            bands.append(cur)
            cur = []
        cur.append(w)
        cur_cy = statistics.mean(x.y + x.h / 2 for x in cur)
    bands.append(cur)
    lines = []
    for band in bands:
        band.sort(key=lambda w: w.x)
        seg = [band[0]]
        for w in band[1:]:
            gap = w.x - (seg[-1].x + seg[-1].w)
            if gap > max(2.5 * max(w.h, seg[-1].h), 28, 2.0 * med_h):
                lines.append(seg)
                seg = []
            seg.append(w)
        lines.append(seg)
    return lines


def box(line):
    x0 = min(w.x for w in line)
    y0 = min(w.y for w in line)
    return x0, y0, max(w.x + w.w for w in line), max(w.y + w.h for w in line)


def xy_cut(lines, med_h, gid=0):
    """Reading order of lines: split by the widest empty row band (top first) or empty
    column band (left first), recursively. Yields (line, group id)."""
    if len(lines) <= 1:
        return [(ln, gid) for ln in lines]
    boxes = [box(ln) for ln in lines]

    def best_gap(lo_i, hi_i):
        spans = sorted((b[lo_i], b[hi_i]) for b in boxes)
        best, edge, reach = 0, None, spans[0][1]
        for lo, hi in spans[1:]:
            if lo - reach > best:
                best, edge = lo - reach, (reach + lo) / 2
            reach = max(reach, hi)
        return best, edge

    gy, cut_y = best_gap(1, 3)
    gx, cut_x = best_gap(0, 2)
    if gy >= 0.5 * med_h and gy >= gx / 2:
        a = [ln for ln, b in zip(lines, boxes, strict=True) if (b[1] + b[3]) / 2 < cut_y]
        b_ = [ln for ln, b in zip(lines, boxes, strict=True) if (b[1] + b[3]) / 2 >= cut_y]
        if a and b_:
            return xy_cut(a, med_h, gid) + xy_cut(b_, med_h, gid + 1000)
    if gx >= 2.0 * med_h:
        a = [ln for ln, b in zip(lines, boxes, strict=True) if (b[0] + b[2]) / 2 < cut_x]
        b_ = [ln for ln, b in zip(lines, boxes, strict=True) if (b[0] + b[2]) / 2 >= cut_x]
        if a and b_:
            return xy_cut(a, med_h, gid) + xy_cut(b_, med_h, gid + 1)
    return [(ln, gid) for ln in sorted(lines, key=lambda ln: (box(ln)[1], box(ln)[0]))]


def reading_order(words):
    """-> [(par, line, Word)] in reading order, with line and paragraph numbers."""
    lines = build_lines(words)
    if not lines:
        return []
    med_h = statistics.median(w.h for w in words)
    ordered = xy_cut(lines, med_h)
    out, par, prev = [], 0, None
    for n, (ln, gid) in enumerate(ordered):
        x0, y0, x1, y1 = box(ln)
        if prev is not None:
            gap = y0 - prev[3]
            if gid != prev[4] or gap > 0.9 * max(y1 - y0, prev[3] - prev[1]):
                par += 1
        for w in ln:
            out.append((par, n, w))
        prev = (x0, y0, x1, y1, gid)
    return out


# ── driver ──────────────────────────────────────────────────────────────────
def extract(rgb, langs, tess, workers, tmp, extra):
    """Read an RGB crop (numpy uint8 HxWx3). Returns [Word] in crop pixels."""
    lum = luminance(rgb.astype(np.float32))
    h, w = lum.shape
    area = h * w
    small = area < UPSCALE_BELOW
    base_up = 2.0 if small else 1.0
    normal, inverted = stretch(lum), stretch(255 - lum)
    guess_inverted = float(lum.mean()) < 128

    with ThreadPoolExecutor(max_workers=workers) as pool:
        strips = 1 if small else max(1, min(workers, MAX_STRIPS, h // MIN_STRIP))
        base_gray = inverted if guess_inverted else normal
        jobs = read_pass(base_gray, base_up, 6, strips, langs, tmp, extra, tess, "b")
        base = run_jobs(jobs, pool)
        cover, cells = uncovered_ink(lum, base)
        if cover >= COVERAGE_OK and cells < CELL_LIMIT:
            return [wd for wd in base if plausible(wd)]

        # hard crop: read it again with both polarities, two scales and two page modes
        e_strips = 1 if small else max(1, min(workers, MAX_STRIPS, h // EXTRA_STRIP))
        ups = (2.0, 1.0) if small else (1.0, 0.5)
        variants = []
        for pol_name, gray in (("n", normal), ("i", inverted)):
            for up in ups:
                for psm in (6, 11):
                    if pol_name == ("i" if guess_inverted else "n") and up == base_up and psm == 6:
                        continue            # that is the pass we already did
                    variants.append((f"{pol_name}{up}p{psm}", gray, up, psm))
        all_jobs, owners = [], []
        for name, gray, up, psm in variants:
            js = read_pass(gray, up, psm, e_strips, langs, tmp, extra, tess, name)
            all_jobs += js
            owners += [name] * len(js)
        passes = {"base": base}
        for name, words in zip(owners, pool.map(read_strip, all_jobs), strict=True):
            passes.setdefault(name, []).extend(words)
        return merge_passes(passes)


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
        full = Image.open(png).convert("RGB")
        left, top = max(0, int(x * scale)), max(0, int(y * scale))
        right = min(full.width, int((x + w) * scale))
        bottom = min(full.height, int((y + h) * scale))
        pixels = (right - left) * (bottom - top)
        if right - left < 2 or bottom - top < 2 or pixels > MAX_CROP_PIXELS:
            print("ERR\tbadregion")
            return 64
        crop = np.asarray(full.crop((left, top, right, bottom)))
        del full
        workers = min(os.cpu_count() or 4, MAX_STRIPS)
        with tempfile.TemporaryDirectory(prefix="scribe-") as tmp:
            extra = tessdata_args(langs, tmp)
            words = extract(crop, langs, tess, workers, tmp, extra)
    except (OSError, ValueError, MemoryError):
        print("ERR\tfail")
        return 1

    ordered = reading_order(words[:MAX_WORDS])
    conf = sum(wd.conf for _, _, wd in ordered) / len(ordered) if ordered else 0
    for par, line, wd in ordered:
        print(f"W\t{par}\t{line}\t{wd.x / scale:.1f}\t{wd.y / scale:.1f}\t{wd.w / scale:.1f}\t"
              f"{wd.h / scale:.1f}\t{wd.text}")
    print(f"CONF\t{int(conf)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
