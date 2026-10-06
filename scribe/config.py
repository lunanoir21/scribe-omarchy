#!/usr/bin/env python3
"""scribe user settings: read, validate and write ~/.config/scribe/settings.json.

usage:
  config.py read            print the settings (defaults merged with the file) as one JSON line
  config.py write <json>    validate <json>, merge it over the current file, write it atomically
  config.py path            print the settings file path

Only the keys below are ever read or written, each with a strict type and range, so a
hand-edited or corrupted file can never feed odd values to the rest of the module.
"""
import contextlib
import json
import os
import re
import sys
import tempfile

DEFAULTS = {
    "langs": "tur+eng",
    "autoCopy": False,
    "joinLines": True,
    "closeAfterCopy": True,
    "minConfidence": 60,
    "highlight": "#8ab4f8",
    "ui": "auto",
}
LANGS_RE = re.compile(r"^[a-z]{2,3}(_[a-z]{2,8})?(\+[a-z]{2,3}(_[a-z]{2,8})?){0,7}$")
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
MAX_FILE_BYTES = 16 * 1024


def config_dir():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "scribe")


def config_path():
    return os.path.join(config_dir(), "settings.json")


def clean(raw):
    """Keep only known keys with valid values."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for key in DEFAULTS:
        if key not in raw:
            continue
        value = raw[key]
        if key == "langs":
            ok = isinstance(value, str) and LANGS_RE.match(value)
        elif key == "highlight":
            ok = isinstance(value, str) and COLOR_RE.match(value)
        elif key == "ui":
            ok = value in ("auto", "tr", "en")
        elif key == "minConfidence":
            ok = isinstance(value, int) and not isinstance(value, bool) and 0 <= value <= 100
        else:
            ok = isinstance(value, bool)
        if ok:
            out[key] = value
    return out


def load():
    path = config_path()
    try:
        if os.path.islink(path) or os.path.getsize(path) > MAX_FILE_BYTES:
            return {}
        with open(path, encoding="utf-8") as f:
            return clean(json.load(f))
    except (OSError, ValueError):
        return {}


def save(values):
    d = config_dir()
    if os.path.islink(d):
        raise OSError("settings directory is a symlink")
    os.makedirs(d, mode=0o700, exist_ok=True)
    merged = {**DEFAULTS, **load(), **clean(values)}
    # unique temp file (O_EXCL, mode 600) in the same directory, then an atomic rename
    fd, tmp = tempfile.mkstemp(prefix=".settings-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(merged, f, indent=2)
            f.write("\n")
        os.replace(tmp, config_path())
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return merged


def main(argv):
    if len(argv) >= 2 and argv[1] == "read":
        print(json.dumps({**DEFAULTS, **load()}, separators=(",", ":")))
    elif len(argv) >= 3 and argv[1] == "write":
        try:
            values = json.loads(argv[2])
        except ValueError:
            print("ERR\tbadjson")
            return 65
        print(json.dumps(save(values), separators=(",", ":")))
    elif len(argv) >= 2 and argv[1] == "path":
        print(config_path())
    else:
        print(__doc__)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
