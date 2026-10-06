#!/usr/bin/env bash
# scribe.sh — helper for the scribe OCR module (the OCR itself is ocr.py).
#   scribe.sh shot [output]   grab one output into the private runtime dir, print the png path
#   scribe.sh read <png> <x> <y> <w> <h> <scale> <langs>
#                             crop and read a region; see ocr.py for the output format
#   scribe.sh clean           delete the screenshot and the temporary crops
#   scribe.sh check           print MISSING<TAB>name for every dependency that is not installed
#
# Everything lives in $XDG_RUNTIME_DIR/scribe (owner-only, mode 700). There is deliberately
# no fallback to /tmp: a screenshot of the whole screen must never sit in a shared directory.
set -euo pipefail
umask 077

die() { printf 'ERR\t%s\n' "$1"; exit "${2:-70}"; }

RUNTIME="${XDG_RUNTIME_DIR:-}"
if [ -z "$RUNTIME" ] || [ ! -d "$RUNTIME" ] || [ ! -O "$RUNTIME" ]; then die norundir; fi
RT="$RUNTIME/scribe"
[ ! -L "$RT" ] || die symlink
mkdir -p "$RT"
if [ ! -d "$RT" ] || [ ! -O "$RT" ]; then die norundir; fi
chmod 700 "$RT"          # also tightens a directory an older version created with looser rights

case "${1:-}" in
shot)
    out="${2:-}"
    # output names come from the compositor; refuse anything that is not a plain name
    if [ -n "$out" ] && ! [[ "$out" =~ ^[A-Za-z0-9._:-]{1,64}$ ]]; then die badoutput 64; fi
    rm -f -- "$RT/shot.png"
    if [ -n "$out" ]; then grim -l 0 -o "$out" "$RT/shot.png"; else grim -l 0 "$RT/shot.png"; fi
    echo "$RT/shot.png"
    ;;
read)
    [ $# -ge 8 ] || die usage 64
    # the engine prints at most a few thousand words; the cap is a second line of defence
    # for the process that collects our stdout
    python3 -I "$(dirname "$0")/ocr.py" "$2" "$3" "$4" "$5" "$6" "$7" "$8" | head -c 4194304
    ;;
clean)
    # exactly the files this script creates, nothing else
    rm -f -- "$RT/shot.png" "$RT/crop.png" "$RT/prep.png"
    ;;
check)
    missing=0
    for bin in grim wl-copy tesseract python3; do
        command -v "$bin" >/dev/null || { printf 'MISSING\t%s\n' "$bin"; missing=1; }
    done
    if command -v python3 >/dev/null; then
        python3 -I -c 'import numpy' 2>/dev/null || { printf 'MISSING\tpython-numpy\n'; missing=1; }
        python3 -I -c 'import PIL' 2>/dev/null || { printf 'MISSING\tpython-pillow\n'; missing=1; }
    fi
    [ "$missing" = 1 ] || echo OK
    ;;
*)
    echo "usage: scribe.sh shot|read|clean|check ..." >&2
    exit 64
    ;;
esac
