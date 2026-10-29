#!/usr/bin/env python3
"""Positive and negative cases for Scripts/visual_diff.py on synthetic PNGs.

USAGE
    python3 -I Scripts/tests/visual_diff_tests.py <workdir>

Draws small grey "text" bars on a light background, runs the comparator on
each pair and checks the verdict and exit status. Needs Pillow and numpy
(as visual_diff.py does). Exits 1 on any mismatch.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True

from PIL import Image, ImageDraw  # noqa: E402

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIFF = os.path.join(SCRIPTS, "visual_diff.py")
work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "visual-diff-tests")
os.makedirs(work, exist_ok=True)
results: list[bool] = []


def image(name: str, lines: list[tuple[int, int]], shift: int = 0) -> str:
    """A 300×400 page with one dark bar per (y, width) — stand-ins for text lines."""
    img = Image.new("RGB", (300, 400), (242, 242, 247))
    draw = ImageDraw.Draw(img)
    for y, width in lines:
        draw.rectangle((20, y + shift, 20 + width, y + shift + 10), fill=(30, 30, 30))
    path = os.path.join(work, name + ".png")
    img.save(path)
    return path


def run(name: str, kind: str, ref: str, cand: str, *extra: str) -> tuple[int, str]:
    out = os.path.join(work, name)
    res = subprocess.run([sys.executable, "-I", DIFF, "--out", out, "--pair", kind, name, ref, cand, *extra],
                         capture_output=True, text=True)
    try:
        verdict = json.load(open(os.path.join(out, "scores.json")))["pairs"][0]["verdict"]
    except (OSError, KeyError, IndexError, ValueError):
        verdict = "(no scores.json)"
    return res.returncode, verdict


def check(name: str, got: tuple[int, str], want_code: int, want_verdict: str) -> None:
    code, verdict = got
    ok = code == want_code and verdict == want_verdict
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'} {name}: exit {code} {verdict} (want {want_code} {want_verdict})")


text = [(40, 200), (60, 180), (80, 220), (140, 150), (160, 210)]
blank_a, blank_b = image("blank-a", []), image("blank-b", [])
text_a, text_b = image("text-a", text), image("text-b", text)
shifted = image("text-shifted", text, shift=3)

check("blank pair (noise) -> INVALID", run("blank-noise", "noise", blank_a, blank_b), 1, "INVALID")
check("blank pair (tolerant) -> INVALID", run("blank-tolerant", "tolerant", blank_a, blank_b), 1, "INVALID")
check("blank pair with --allow-empty -> PASS",
      run("blank-allowed", "exact", blank_a, blank_b, "--allow-empty"), 0, "PASS")
check("identical text pair -> PASS", run("text-same", "exact", text_a, text_b), 0, "PASS")
check("text shifted 3 px (tolerant) -> FAIL", run("text-shift", "tolerant", text_a, shifted), 1, "FAIL")
check("text vs blank candidate -> FAIL", run("text-vs-blank", "tolerant", text_a, blank_b), 1, "FAIL")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
