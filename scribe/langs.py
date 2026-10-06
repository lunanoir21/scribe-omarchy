#!/usr/bin/env python3
"""scribe language packs: what is installed, and how to get more on this OS.

usage:
  langs.py info              PM<TAB>name<TAB>os, DIR<TAB>path, then L<TAB>code<TAB>system|user
  langs.py install <code>    download the tessdata_fast file into ~/.local/share/scribe/tessdata
                             (no password); prints MSG<TAB>text and PCT<TAB>n, exit 0 on success
  langs.py command <code>    print the package manager command to run by hand (needs a password)
  langs.py term <code>       run that command in a terminal window and wait until it is closed
add `--lang tr` or `--lang en` anywhere to pick the language of the messages (default en).

scribe never runs a privileged command itself: the package manager command is only ever
shown, or typed into the user's own terminal where the user enters the password.
"""
import contextlib
import os
import re
import shlex
import shutil
import subprocess  # noqa: S404  (argument lists only, never a shell)
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

USER_DIR = os.path.expanduser("~/.local/share/scribe/tessdata")
FAST_URL = "https://github.com/tesseract-ocr/tessdata_fast/raw/main/{}.traineddata"
ALLOWED_HOSTS = {"github.com", "raw.githubusercontent.com", "media.githubusercontent.com"}
CODE_RE = re.compile(r"^[a-z]{2,3}(_[a-z]{2,8})?$")
MIN_BYTES = 200 * 1024            # a real traineddata file is megabytes
MAX_BYTES = 64 * 1024 * 1024      # the largest tessdata_fast file is about 30 MB
TIMEOUT = 30

# distro family -> (package manager, install argv template, package name template)
FAMILIES = {
    "arch": ("pacman", ["pacman", "-S", "--needed"], "tesseract-data-{code}"),
    "debian": ("apt", ["apt-get", "install", "-y"], "tesseract-ocr-{dash}"),
    "fedora": ("dnf", ["dnf", "install", "-y"], "tesseract-langpack-{code}"),
    "alpine": ("apk", ["apk", "add"], "tesseract-ocr-data-{code}"),
}
LIKE = {
    "arch": "arch", "cachyos": "arch", "manjaro": "arch", "endeavouros": "arch",
    "artix": "arch", "debian": "debian", "ubuntu": "debian", "linuxmint": "debian",
    "pop": "debian", "kali": "debian", "fedora": "fedora", "rhel": "fedora",
    "centos": "fedora", "nobara": "fedora", "alpine": "alpine",
}
TERMINALS = [
    ("kitty", ["kitty"]), ("foot", ["foot"]), ("alacritty", ["alacritty", "-e"]),
    ("wezterm", ["wezterm", "start", "--"]), ("konsole", ["konsole", "-e"]),
    ("gnome-terminal", ["gnome-terminal", "--"]), ("xfce4-terminal", ["xfce4-terminal", "-x"]),
    ("xterm", ["xterm", "-e"]),
]


def valid_code(code):
    return isinstance(code, str) and bool(CODE_RE.match(code))


MESSAGES = {
    "invalid": {"tr": "Geçersiz dil kodu", "en": "Invalid language code"},
    "symlink": {"tr": "Hedef klasör bir sembolik bağlantı", "en": "The target folder is a symlink"},
    "downloading": {"tr": "{code} indiriliyor (tessdata_fast)",
                    "en": "Downloading {code} (tessdata_fast)"},
    "installed": {"tr": "{code} kuruldu", "en": "{code} installed"},
    "already": {"tr": "{code} zaten kurulu", "en": "{code} is already installed"},
    "failed": {"tr": "İndirme başarısız: {e}", "en": "Download failed: {e}"},
    "nocommand": {"tr": "Bu sistem için paket komutu bilinmiyor",
                  "en": "No package command is known for this system"},
    "noterminal": {"tr": "Terminal bulunamadı", "en": "No terminal found"},
    "done": {"tr": "Bitti. Kapatmak icin Enter tusuna bas", "en": "Done. Press Enter to close"},
}
LANG = "en"


def msg(key, **kw):
    return MESSAGES[key][LANG].format(**kw)


def say(key, **kw):
    print(f"MSG\t{msg(key, **kw)}", flush=True)


def os_release():
    info = {}
    try:
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    info[k] = v.strip('"')
    except OSError:
        pass
    return info


def family():
    info = os_release()
    for token in [info.get("ID", "")] + info.get("ID_LIKE", "").split():
        if token in LIKE:
            return LIKE[token]
    return None


def system_dir():
    tess = shutil.which("tesseract")
    if tess:
        out = subprocess.run([tess, "--list-langs"], capture_output=True, text=True,
                             timeout=20, check=False)
        first = (out.stdout or out.stderr).split("\n")[0]
        if '"' in first:
            return first.split('"')[1].rstrip("/")
    return "/usr/share/tessdata"


def installed():
    """{code: 'system' | 'user'}; a user-dir copy wins over a system one."""
    found = {}
    for source, d in (("system", system_dir()), ("user", USER_DIR)):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for f in names:
            code = f[: -len(".traineddata")]
            if f.endswith(".traineddata") and code != "osd" and valid_code(code):
                found[code] = source
    return found


def info():
    fam = family()
    print(f"PM\t{FAMILIES[fam][0] if fam else 'indirme'}\t{os_release().get('PRETTY_NAME', '')}")
    print(f"DIR\t{USER_DIR}")
    for code, source in sorted(installed().items()):
        print(f"L\t{code}\t{source}")


class _HttpsOnly(urllib.request.HTTPRedirectHandler):
    """Follow redirects only to https URLs on the GitHub hosts."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlsplit(newurl)
        if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
            raise urllib.error.URLError(f"redirect to {parts.hostname} refused")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download(code):
    if not valid_code(code):
        say("invalid")
        return False
    url = FAST_URL.format(code)
    os.makedirs(USER_DIR, mode=0o700, exist_ok=True)
    if os.path.islink(USER_DIR):
        say("symlink")
        return False
    dest = os.path.join(USER_DIR, f"{code}.traineddata")
    say("downloading", code=code)
    opener = urllib.request.build_opener(_HttpsOnly)
    # unique temp file (O_EXCL, mode 600) in the target folder, renamed into place at the end
    fd, tmp = tempfile.mkstemp(prefix=f".{code}-", suffix=".part", dir=USER_DIR)
    try:
        with opener.open(url, timeout=TIMEOUT) as r, os.fdopen(fd, "wb") as f:  # noqa: S310
            total = int(r.headers.get("Content-Length") or 0)
            if total > MAX_BYTES:
                raise ValueError("file is larger than expected")
            done, last = 0, -1
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                done += len(chunk)
                if done > MAX_BYTES:
                    raise ValueError("file is larger than expected")
                f.write(chunk)
                if total and done * 100 // total != last:
                    last = done * 100 // total
                    print(f"PCT\t{last}", flush=True)
        if done < MIN_BYTES:
            raise ValueError("file is too small to be a language pack")
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    except (OSError, ValueError) as e:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        say("failed", e=e)
        return False
    say("installed", code=code)
    return True


def pm_command(code):
    """The shell command that installs `code` with the distro's package manager, or None."""
    fam = family()
    if not fam or not valid_code(code):
        return None
    _pm, argv, pkg = FAMILIES[fam]
    package = pkg.format(code=code, dash=code.replace("_", "-"))
    return shlex.join(["sudo", *argv, package])


def run_in_terminal(code):
    cmd = pm_command(code)
    if not cmd:
        say("nocommand")
        return 1
    script = f'{cmd}; echo; read -r -p "{msg("done")} " _'
    wanted = os.path.basename(os.environ.get("TERMINAL", ""))
    options = [t for t in TERMINALS if t[0] == wanted] + TERMINALS
    for name, prefix in options:
        path = shutil.which(name)
        if path:
            return subprocess.call([path, *prefix[1:], "sh", "-c", script])
    say("noterminal")
    return 1


def install(code):
    if not valid_code(code):
        say("invalid")
        return 1
    if code in installed():
        say("already", code=code)
        return 0
    return 0 if download(code) else 1


def main(argv):
    global LANG
    if "--lang" in argv:                      # --lang tr|en, anything else keeps English
        i = argv.index("--lang")
        if i + 1 < len(argv) and argv[i + 1] in ("tr", "en"):
            LANG = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    if len(argv) >= 2 and argv[1] == "info":
        info()
    elif len(argv) >= 3 and argv[1] == "install":
        return install(argv[2])
    elif len(argv) >= 3 and argv[1] == "command":
        print(pm_command(argv[2]) or "")
    elif len(argv) >= 3 and argv[1] == "term":
        return run_in_terminal(argv[2])
    else:
        print(__doc__)
        return 64
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
