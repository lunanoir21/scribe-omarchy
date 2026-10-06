#!/usr/bin/env bash
# Keeps scribe/ (the vendored copy) identical to upstream.
#
#   scripts/sync.sh                 copy from a local upstream checkout (default ../scribe), then verify
#   scripts/sync.sh --check         only verify; with no local checkout it clones the pinned commit
#   scripts/sync.sh --upstream DIR  use another checkout
#
# The pinned upstream commit lives in UPSTREAM_COMMIT. Syncing takes the checkout's HEAD and
# writes it there; checking compares scribe/ against that exact commit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="$HERE/../scribe"
CHECK_ONLY=0
REPO_URL="https://github.com/lunanoir21/scribe.git"
# the files that make up the running module (not tests, docs or the installer)
FILES=(scribe.sh ocr.py langs.py config.py ui/qmldir)

while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK_ONLY=1 ;;
        --upstream) UPSTREAM="$2"; shift ;;
        -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 64 ;;
    esac
    shift
done

TMP=""
# shellcheck disable=SC2329  # called by the trap below
cleanup() { if [ -n "$TMP" ]; then rm -r -- "$TMP"; fi; }
trap cleanup EXIT

if [ "$CHECK_ONLY" = 1 ] && [ ! -d "$UPSTREAM/.git" ]; then
    TMP="$(mktemp -d)"
    PIN="$(tr -d '[:space:]' < "$HERE/UPSTREAM_COMMIT")"
    git clone -q "$REPO_URL" "$TMP/up"
    git -C "$TMP/up" checkout -q --detach "$PIN"
    UPSTREAM="$TMP/up"
fi

[ -d "$UPSTREAM/ui" ] || { echo "no scribe checkout at $UPSTREAM (use --upstream DIR)" >&2; exit 1; }

list_files() {
    for f in "${FILES[@]}"; do echo "$f"; done
    (cd "$UPSTREAM" && ls ui/*.qml)
}

if [ "$CHECK_ONLY" = 0 ]; then
    if [ -n "$(git -C "$UPSTREAM" status --porcelain 2>/dev/null)" ]; then
        echo "the upstream checkout has uncommitted changes; commit or stash them first" >&2
        exit 1
    fi
    mkdir -p "$HERE/scribe/ui"
    # drop vendored QML that upstream no longer has
    for f in "$HERE"/scribe/ui/*.qml; do
        [ -e "$f" ] || continue
        [ -e "$UPSTREAM/ui/$(basename "$f")" ] || rm -- "$f"
    done
    list_files | while read -r f; do install -m "$(stat -c %a "$UPSTREAM/$f")" "$UPSTREAM/$f" "$HERE/scribe/$f"; done
    git -C "$UPSTREAM" rev-parse HEAD > "$HERE/UPSTREAM_COMMIT"
    echo "synced scribe/ from $(cat "$HERE/UPSTREAM_COMMIT")"
fi

# verify: every upstream file is vendored byte for byte, and nothing extra is vendored
bad=0
while read -r f; do
    if ! cmp -s "$UPSTREAM/$f" "$HERE/scribe/$f"; then echo "differs or missing: scribe/$f" >&2; bad=1; fi
done < <(list_files)
extra="$(cd "$HERE/scribe" && find . -type f | sed 's|^\./||' | sort | comm -13 <(list_files | sort) -)"
if [ -n "$extra" ]; then echo "not in upstream: $extra" >&2; bad=1; fi
[ "$bad" = 0 ] && echo "scribe/ matches upstream $(cat "$HERE/UPSTREAM_COMMIT" | cut -c1-12)"
exit "$bad"
