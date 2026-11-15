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


def list_image(name: str, rows: list[int], marker_dx: int = 0, content_dy: int = 0,
               fill: bool = True, markers: bool = True, extra_marker: bool = False) -> str:
    """List rows: a small marker square (x 20–27) on the first of three
    wrapped content lines from x 60 (a row crop the size of a real one, so
    a 1 px marker move is a fraction of a percent), each row on a
    low-contrast decision-style fill (Δ ≈ 16 grey levels: below the
    tolerant threshold 24 and the ink threshold 40)."""
    img = Image.new("RGB", (300, 400), (242, 242, 247))
    draw = ImageDraw.Draw(img)
    for i, y in enumerate(rows):
        if fill:
            draw.rectangle((10, y - 8, 289, y + 44), fill=(226, 226, 231))
        if markers or (extra_marker and i == 0):
            draw.rectangle((20 + marker_dx, y + 3, 27 + marker_dx, y + 9), fill=(30, 30, 30))
        for line, width in enumerate((220, 210, 120)):
            top = y + content_dy + line * 13
            draw.rectangle((60, top, 60 + width, top + 9), fill=(30, 30, 30))
    path = os.path.join(work, name + ".png")
    img.save(path)
    return path


def run_pair(name: str, kind: str, ref: str, cand: str, *extra: str) -> tuple[int, dict]:
    out = os.path.join(work, name)
    res = subprocess.run([sys.executable, "-I", DIFF, "--out", out, "--pair", kind, name, ref, cand, *extra],
                         capture_output=True, text=True)
    try:
        pair = json.load(open(os.path.join(out, "scores.json")))["pairs"][0]
    except (OSError, KeyError, IndexError, ValueError):
        pair = {"verdict": "(no scores.json)"}
    return res.returncode, pair


def run(name: str, kind: str, ref: str, cand: str, *extra: str) -> tuple[int, str]:
    code, pair = run_pair(name, kind, ref, cand, *extra)
    return code, pair["verdict"]


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

# Marker / content crops and list pairs.
rows = [40, 120, 200]
list_a, list_b = list_image("list-a", rows), list_image("list-b", rows)
list_pair = ("--list-pair", "lp-:3")
code, pair = run_pair("lp-same", "tolerant", list_a, list_b, *list_pair)
check("identical list pair finds 3 marker crops -> PASS", (code, pair["verdict"]), 0, "PASS")
check("  ... marker_crops == 3", (0, str(pair.get("marker_crops"))), 0, "3")

marker_moved = list_image("list-marker-1px", rows, marker_dx=1)
code, pair = run_pair("lp-marker-1px", "tolerant", list_a, marker_moved, *list_pair)
check("marker moved 1 px right (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
hidden = pair.get("viewport_pct", 99) <= 0.5 and pair.get("max_crop_pct", 99) <= 0.5
check("  ... the 1 px move hides inside the viewport and crop percentages",
      (0, "hidden" if hidden else f"vp {pair.get('viewport_pct')} crop {pair.get('max_crop_pct')}"), 0, "hidden")
check("  ... caught by the marker crops", (0, str(pair.get("failing_marker_crops"))), 0, "3")

baseline_moved = list_image("list-content-1px", rows, content_dy=1)
check("content first line 1 px lower, marker unmoved (tolerant) -> FAIL",
      run("lp-baseline-1px", "tolerant", list_a, baseline_moved, *list_pair), 1, "FAIL")

extra = list_image("list-extra-marker", rows, markers=False, extra_marker=True)
plain = list_image("list-no-markers", rows, markers=False)
check("a marker only in the candidate (tolerant) -> FAIL",
      run("lp-extra-marker", "tolerant", plain, extra), 1, "FAIL")
check("list pair without any marker -> INVALID",
      run("lp-no-markers", "exact", plain, list_image("list-no-markers-2", rows, markers=False), *list_pair),
      1, "INVALID")
check("the same pair outside --list-pair -> PASS",
      run("other-no-markers", "exact", plain, list_image("list-no-markers-3", rows, markers=False), *list_pair),
      0, "PASS")

no_fill = list_image("list-no-fill", rows, fill=False)
code, pair = run_pair("lp-no-fill", "tolerant", list_a, no_fill, *list_pair)
check("decision-style fill missing in a list pair (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
check("  ... invisible to the tolerant pixel rule", (0, str(pair.get("viewport_px"))), 0, "0")
check("the same fill change outside --list-pair -> PASS (fill reported only)",
      run("other-no-fill", "tolerant", list_a, no_fill), 0, "PASS")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
