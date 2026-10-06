# Scribe for Omarchy

> **This repo is only packaging.** The project itself lives at
> **[lunanoir21/scribe](https://github.com/lunanoir21/scribe)**: source,
> [changelog](https://github.com/lunanoir21/scribe/blob/main/CHANGELOG.md),
> [website](https://lunanoir21.github.io/scribe/), screenshots and the issue tracker are all there.
> Please open bugs and feature requests upstream; issues here are limited to the Omarchy wrapper
> itself (manifest, `Service.qml`, vendoring).

[Scribe](https://github.com/lunanoir21/scribe) packaged as an Omarchy shell plugin. Press a key,
drag a box around any text on the screen (a video, an image, a PDF, a terminal), then drag over the
words and press **Copy**, the way Google Lens does it. The original text stays untouched.

![Words selected on the Hyprland Wikipedia article, with the Copy toolbar above the selection](preview.png)

This repo is a thin wrapper. All behaviour lives upstream; the `scribe/` directory here is a
vendored, pinned copy of the running module (currently `v0.2.1`, commit
`e8ff1aa07f3386ec802320d137d000a99c6fd6f9`, written to `UPSTREAM_COMMIT`), and `Service.qml` is
what Omarchy's plugin loader needs to start it. Nothing is developed here.

`manifest.json` declares `kinds: ["service"]` with `keepLoaded: true`, the same shape as Omarchy's
built-in `background`, `lock` and `notifications` plugins. Scribe draws nothing until you press its
key: the overlay is one full-screen layer window that exists only while it is open, so nothing needs
a place in Omarchy's bar.

## Install

```bash
omarchy plugin add https://github.com/lunanoir21/scribe-omarchy.git --enable
```

Scribe needs a few programs the plugin cannot install for you. On Omarchy (Arch):

```bash
sudo pacman -S --needed grim wl-clipboard tesseract tesseract-data-eng python-numpy python-pillow
```

If something is missing, Scribe says so by name in a notification instead of failing silently. More
languages are added from the gear in the overlay, with a direct download that needs no password
or the exact package manager command.

> **Don't forget the key.** The plugin adds no key on its own, so there is nothing to press until
> you bind one. Run `scripts/bind.sh` from this repo (it asks for a key, or picks a free one such as
> `SUPER + SHIFT + T`), or add the line yourself:

```
bind = SUPER SHIFT, T, exec, qs ipc call scribe start
```

(`scripts/bind.sh` writes into your `bindings.conf` / `bindings.lua` only when *you* run it, and
prints one `STATUS|KEYS|FILE` line.)

## Use

1. Press the key. The screen freezes.
2. Drag a box around the text. A scan line shows it is being read.
3. Drag over the words you want. A toolbar appears above the selection: **Copy** or **Select all**.

`Ctrl+A` selects everything, `Ctrl+C` or `Enter` copies, `Esc` closes. The gear in the bottom-right
corner opens settings: reading languages (with downloads), behaviour, highlight colour and the
interface language (English or Turkish; `auto` follows `$LANG`).

## What it reads and writes

- **Reads** a screenshot of the focused monitor, taken with `grim` into `$XDG_RUNTIME_DIR/scribe`
  (an owner-only directory, mode 700, in RAM). It is deleted when the overlay closes. Scribe refuses
  to run without that directory instead of falling back to `/tmp`.
- **Writes** its settings to `~/.config/scribe/settings.json` (mode 600, six known keys), the
  language packs you choose to download to `~/.local/share/scribe/tessdata/`, and text to the
  clipboard through `wl-copy`, which gets the text on its stdin only: screen text never appears on a
  command line, where other local users could read it. It never touches `~/.config/omarchy/shell.json` or any other
  configuration, and nothing is written inside the plugin folder.
- **Network:** only the language pack download, and only when you press **Download directly**: HTTPS
  to `github.com` / `raw.githubusercontent.com` (`tesseract-ocr/tessdata_fast`), redirects to other
  hosts refused, a 30 second timeout, a 64 MiB cap and a minimum size. No telemetry, no update
  check.
- **Privileges:** none. For a package manager install Scribe only *shows* the command and can
  type it into your own terminal, where you enter the password. Nothing is piped to a shell.
- **Processes:** `grim`, `tesseract` (one per strip of the selection, each with a 60 second timeout),
  `wl-copy`, `notify-send` and short Python helpers. It starts no second Quickshell instance.
- **Limits:** the selection is capped at 36 megapixels, at most 4000 words come back, the output of
  the reader is cut at 4 MiB, and a read that runs longer than 90 seconds is cancelled.

The upstream [SECURITY.md](https://github.com/lunanoir21/scribe/blob/main/SECURITY.md) has the full
list, and its test suite (`python3 -m unittest discover -s tests`) checks these rules.

## Uninstall

```bash
omarchy plugin remove io.github.lunanoir21.scribe
```

Your settings stay in `~/.config/scribe/` and downloaded language packs in
`~/.local/share/scribe/`; delete them if you want them gone. Remove the key bind line (marked
`scribe-omarchy`) from your bindings file too if you added one.

## Requirements

- Quickshell 0.3+ with Qt 6.6+ on a Wayland compositor with layer-shell (Hyprland on Omarchy)
- `grim`, `wl-clipboard` (`wl-copy`), `tesseract` with at least one language pack, Python 3 with
  `numpy` and `pillow`
- Optional: `notify-send` (error messages), a terminal (to run a package manager command from the
  settings)

## Updating the vendored copy

`scribe/` is a plain copy, not a git submodule: Omarchy's marketplace clones a single ref of this
repo, and a submodule would need an extra `--recurse-submodules` step outside the plugin loader's
control. To pick up a new release:

```bash
git -C ../scribe pull && scripts/sync.sh      # copies from ../scribe and pins its HEAD
# bump "version" in manifest.json and the commit above, then commit
scripts/sync.sh --check                        # verify against the pinned upstream commit
```

CI runs the same check, so the two repos cannot drift apart unnoticed. Watch the
[upstream releases](https://github.com/lunanoir21/scribe/releases).

## License

MIT, same as upstream; see [LICENSE](LICENSE).

---

<sub>Maintainer note: marketplace submission: category `Productivity`, tags `hyprland`, `quickshell`.
`preview.png` is the project's cover image (1280×640).</sub>
