"""Checks for the Omarchy wrapper: manifest, entry point, vendored copy and marketplace limits.

Run from the repository root:   python3 -m unittest discover -s tests -v
"""
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KINDS = {"bar-widget": "barWidget", "panel": "panel", "overlay": "overlay", "menu": "menu",
         "service": "service", "bar": "bar"}
FILE_LIMIT = 512 * 1024          # the marketplace baseline reads at most this much of one file
TOTAL_LIMIT = 8 * 1024 * 1024
COUNT_LIMIT = 1000


def tracked_files():
    for p in ROOT.rglob("*"):
        if ".git" not in p.parts and (p.is_file() or p.is_symlink()):
            yield p


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.m = json.loads((ROOT / "manifest.json").read_text())

    def test_required_fields(self):
        for key in ("schemaVersion", "id", "name", "version", "author", "license", "description",
                    "kinds", "entryPoints"):
            self.assertIn(key, self.m, key)
        self.assertEqual(self.m["schemaVersion"], 1)
        self.assertLessEqual(len(self.m["version"]), 64)
        self.assertRegex(self.m["version"], r"^\d+\.\d+\.\d+$")

    def test_id_is_namespaced_and_not_reserved(self):
        self.assertRegex(self.m["id"], r"^[a-z0-9]+(\.[a-z0-9-]+)+$")
        self.assertFalse(self.m["id"].startswith("omarchy."))

    def test_kinds_and_entry_points_agree_and_exist(self):
        self.assertTrue(self.m["kinds"])
        for kind in self.m["kinds"]:
            self.assertIn(kind, KINDS)
            self.assertIn(KINDS[kind], self.m["entryPoints"])
        for path in self.m["entryPoints"].values():
            self.assertFalse(Path(path).is_absolute() or ".." in Path(path).parts, path)
            self.assertTrue((ROOT / path).is_file(), path)

    def test_version_matches_the_pinned_upstream_release(self):
        readme = (ROOT / "README.md").read_text()
        pin = (ROOT / "UPSTREAM_COMMIT").read_text().strip()
        self.assertRegex(pin, r"^[0-9a-f]{40}$")
        self.assertIn(pin, readme)
        self.assertIn(f"`v{self.m['version']}`", readme)


class RepositoryRuleTests(unittest.TestCase):
    def test_required_files_exist(self):
        for name in ("manifest.json", "README.md", "LICENSE", "Service.qml", "preview.png"):
            self.assertTrue((ROOT / name).is_file(), name)

    def test_no_symlinks_and_limits(self):
        files = list(tracked_files())
        self.assertLessEqual(len(files), COUNT_LIMIT)
        self.assertLessEqual(sum(p.stat().st_size for p in files if not p.is_symlink()), TOTAL_LIMIT)
        for p in files:
            self.assertFalse(p.is_symlink(), f"symlink: {p}")
            self.assertLess(p.stat().st_size, FILE_LIMIT, f"too large for the scanner: {p}")

    def test_preview_is_a_real_png_of_the_documented_size(self):
        data = (ROOT / "preview.png").read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(int.from_bytes(data[16:20], "big"), 1280)
        self.assertEqual(int.from_bytes(data[20:24], "big"), 640)

    def test_no_agent_instruction_files(self):
        for name in ("AGENTS.md", "CLAUDE.md", ".cursorrules", "GEMINI.md"):
            self.assertFalse((ROOT / name).exists(), name)

    def test_service_imports_only_the_vendored_module(self):
        text = (ROOT / "Service.qml").read_text()
        self.assertIn('import "./scribe/ui" as Scribe', text)
        self.assertEqual(len(re.findall(r"^\s*import\s+\"", text, re.M)), 1)
        self.assertNotIn("Process", text)


class VendoredCopyTests(unittest.TestCase):
    def test_vendored_files_are_the_documented_set(self):
        names = sorted(str(p.relative_to(ROOT / "scribe")) for p in (ROOT / "scribe").rglob("*") if p.is_file())
        self.assertIn("scribe.sh", names)
        self.assertIn("ui/ScribeHost.qml", names)
        self.assertIn("ui/qmldir", names)
        for forbidden in ("settings.json", "install.sh"):
            self.assertNotIn(forbidden, names)

    def test_matches_the_pinned_upstream_when_a_checkout_is_next_to_it(self):
        up = ROOT.parent / "scribe"
        if not (up / ".git").is_dir():
            self.skipTest("no sibling upstream checkout (CI runs scripts/sync.sh --check instead)")
        r = subprocess.run(["bash", str(ROOT / "scripts" / "sync.sh"), "--check"], capture_output=True,
                           text=True, check=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class BindHelperTests(unittest.TestCase):
    """scripts/bind.sh against throwaway configs and a stub hyprctl, never the real session."""

    def run_bind(self, home, *args):
        stub = Path(home) / "bin"
        stub.mkdir(exist_ok=True)
        (stub / "hyprctl").write_text('#!/bin/sh\ncase "$1" in binds) echo "[]";; esac\nexit 0\n')
        (stub / "hyprctl").chmod(0o755)
        env = dict(os.environ, PATH=f"{stub}:{os.environ['PATH']}", XDG_CONFIG_HOME=str(Path(home) / "cfg"))
        r = subprocess.run(["sh", str(ROOT / "scripts" / "bind.sh"), *args], capture_output=True, text=True,
                           env=env, check=False)
        return r.stdout.strip().split("|")[0]

    def test_adds_once_and_never_edits_without_a_config(self):
        with tempfile.TemporaryDirectory() as home:
            self.assertEqual(self.run_bind(home, "auto"), "nohypr")
            hypr = Path(home) / "cfg" / "hypr"
            hypr.mkdir(parents=True)
            (hypr / "hyprland.conf").write_text("")
            (hypr / "bindings.conf").write_text("bind = SUPER, Q, killactive\n")
            self.assertEqual(self.run_bind(home, "auto"), "ok")
            self.assertEqual(self.run_bind(home, "auto"), "exists")
            text = (hypr / "bindings.conf").read_text()
            self.assertEqual(text.count("qs ipc call scribe start"), 1)
            self.assertIn("bind = SUPER, Q, killactive", text)

    def test_rejects_odd_keys(self):
        with tempfile.TemporaryDirectory() as home:
            hypr = Path(home) / "cfg" / "hypr"
            hypr.mkdir(parents=True)
            (hypr / "hyprland.conf").write_text("")
            self.assertEqual(self.run_bind(home, "SUPER", "x;rm"), "bad")
            self.assertEqual(self.run_bind(home, "NONE", "a"), "bad")       # a bare letter would eat typing
            self.assertEqual(self.run_bind(home, "HYPER", "a"), "bad")
            self.assertEqual((hypr / "hyprland.conf").read_text(), "")


if __name__ == "__main__":
    unittest.main()
