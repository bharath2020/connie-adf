#!/usr/bin/env python3
"""Positive and negative cases for Scripts/visual_diff.py on synthetic PNGs.

USAGE
    python3 -I Scripts/tests/visual_diff_tests.py <workdir>

Draws small grey "text" bars on a light background, runs the comparator on
each pair and checks the verdict and exit status; then code boxes (the
grey box, header strip and code lines of a code block) with the negative
controls of the code crops, of the engine proof and of the capture-time
geometry (CAPTURE_GEOMETRY: which TextKit 2 row drew a scored box, the
measured landing); then container and caption captures (PR 4: the kind
on the declaration, the kind's engine proof, the owner geometry and the
owner text crops). Needs Pillow and numpy (as visual_diff.py does). Exits
1 on any mismatch.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True

import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIFF = os.path.join(SCRIPTS, "visual_diff.py")
work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "visual-diff-tests")
os.makedirs(work, exist_ok=True)
results: list[bool] = []
CONTROL = False   # True from the code boxes on: see a_prime()


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


def a_prime(ref: str) -> str:
    """The A' capture of a reference: an exact copy (capture noise 0)."""
    path = ref[:-len(".png")] + "-a2.png"
    shutil.copyfile(ref, path)
    return path


def run_pair(name: str, kind: str, ref: str, cand: str, *extra: str, control: bool | None = None) -> tuple[int, dict]:
    """One pair (scores.json's first). With `control` (default CONTROL) a
    non-noise pair also gets its matching A-A' noise pair, <name>-AA."""
    out = os.path.join(work, name)
    command = [sys.executable, "-I", DIFF, "--out", out, "--pair", kind, name, ref, cand]
    if (CONTROL if control is None else control) and kind != "noise":
        command += ["--pair", "noise", name + "-AA", ref, a_prime(ref)]
    res = subprocess.run(command + list(extra), capture_output=True, text=True)
    try:
        pair = json.load(open(os.path.join(out, "scores.json")))["pairs"][0]
    except (OSError, KeyError, IndexError, ValueError):
        pair = {"verdict": "(no scores.json)"}
    return res.returncode, pair


def run(name: str, kind: str, ref: str, cand: str, *extra: str, control: bool | None = None) -> tuple[int, str]:
    code, pair = run_pair(name, kind, ref, cand, *extra, control=control)
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


# ---------------------------------------------------------------- code boxes
# A code block as CodeBlockView draws it: a box filled with the page colour
# blended 10 % toward system grey, a header strip (language badge on the
# left, Copy icon on the right) and code lines. Text lines have soft left
# and right edges (steps of ~20 grey levels, under the tolerant threshold
# 24), as anti-aliased glyphs do, so a 1 px sideways move changes no pixel
# by the tolerant rule.
# Exact chrome is judged only where A-A' proves it stable, so from here every
# exact or tolerant pair runs with its matching A-A' pair (A' an exact copy
# of the reference), as visual-parity.sh's default arms A A2 B C give every
# A-B and A-C pair; control=False drops it (the negative controls below).
CONTROL = True

BOX = (20, 80, 280, 200)   # x0, y0, x1, y1 (exclusive)


def code_page(name: str, *, dark: bool = False, box: tuple[int, int, int, int] | None = BOX,
              lines: tuple[int, ...] = (200, 150, 110), text_dx: int = 0, text_dy: int = 0,
              tint: tuple[int, int, int] | None = None, copy: bool = True, top: int = 0,
              second_box: bool = False, extra_boxes: tuple[tuple[int, int, int, int], ...] = (),
              page_tint: tuple[tuple[int, int, int, int, tuple[int, int, int]], ...] = (),
              edits: tuple[tuple[int, int, int], ...] = ()) -> str:
    """A 300x400 page with one text line and (unless `box` is None) a code
    box. `text_dx`/`text_dy` move the code lines only; `tint` replaces the
    fill (a panel); `top` moves the whole box; `extra_boxes` are more code
    boxes (x0, y0, x1, y1) with one line each; `page_tint` paints
    (x0, y0, x1, y1, colour) rectangles on the page first; `edits` are
    (y, x, delta) one-pixel changes applied last."""
    background = (0, 0, 0) if dark else (255, 255, 255)
    ink, secondary = (235, 150) if dark else (20, 120)
    fill = tuple(round(b + 0.1 * (g - b)) for b, g in zip(background, (142, 142, 147)))
    img = np.empty((400, 300, 3), dtype=np.uint8)
    img[:] = background
    for tx0, ty0, tx1, ty1, colour in page_tint:
        img[ty0:ty1, tx0:tx1] = colour
    img[30:40, 20:220] = ink   # page text, so no pair is blank

    def draw_box(x0: int, y0: int, x1: int, y1: int, widths: tuple[int, ...]) -> None:
        img[y0:y1, x0:x1] = tint or fill
        for cy, cx in ((y0, x0), (y0, x1 - 2), (y1 - 2, x0), (y1 - 2, x1 - 2)):
            img[cy:cy + 2, cx:cx + 2] = background   # rounded corners
        img[y0 + 8:y0 + 18, x0 + 12:x0 + 50] = secondary   # language badge
        if copy:
            img[y0 + 8:y0 + 18, x1 - 22:x1 - 12] = secondary   # Copy icon
        level = float(np.mean(tint or fill))
        for index, width in enumerate(widths):
            row = y0 + 32 + index * 14 + text_dy
            left = x0 + 12 + text_dx
            profile = np.full(width, float(ink))
            ramp = level + (ink - level) * np.arange(1, 11) / 11.0
            profile[:10], profile[-10:] = ramp, ramp[::-1]
            img[row:row + 9, left:left + width] = np.round(profile)[None, :, None]

    if box is not None:
        x0, y0, x1, y1 = box
        draw_box(x0, y0 + top, x1, y1 + top, lines)
    if second_box:
        draw_box(20, 260, 280, 330, (90,))
    for extra in extra_boxes:
        draw_box(*extra, (90,))
    for y, x, delta in edits:
        img[y, x] = np.clip(img[y, x].astype(int) + delta, 0, 255)
    path = os.path.join(work, name + ".png")
    Image.fromarray(img).save(path)
    return path


# Owner 0.12's code row over the default box's code text (lines at y 112 to
# 149, x 32 to 232), at 1x: frame and visible part, then its draws.
ROW_012 = "0.12|code|32,112,268,190|32,112,268,190|3"
# A live code row the lazy stack keeps below the window (TK2_CODE_ROWS lists
# it, the window shows nothing of it).
ROW_014_OFF = "0.14|code|32,500,268,560|-|2"


def geometry(rows: str = ROW_012, *, scale: float | str = 1, screen: tuple[float | str, float | str] = (300, 400),
             visible: str = "0.10,0.11,0.12", window: str | None = None, second: str | None = None) -> list[str]:
    """The two CAPTURE_GEOMETRY lines the app prints around a screenshot
    (seq=1 before, seq=2 after); `second` replaces seq=2's rows."""
    def line(seq: int, rows_text: str) -> str:
        return (f"CAPTURE_GEOMETRY seq={seq} scale={scale} screen={screen[0]}x{screen[1]} "
                f"window={window or f'0,0,{screen[0]},{screen[1]}'} visibleRows={visible} rows={rows_text}")
    return [line(1, rows), line(2, rows if second is None else second)]


def proof_log(name: str, *, renderer: str = "textkit2", live: int = 2, draws: int = 5,
              rows: str | None = "0.12:3,0.14:2", landed: str | None = "0.10", ready_live: int = 0,
              geo: list[str] | None = None) -> str:
    """A launch log as `simctl launch --console-pty` writes it (\r\n): the
    READY-time stats, then (unless `landed` is None) the post-jump lines and
    the capture-time geometry (`geo`, default `geometry()`; [] for none)."""
    def stats(code_live: int, code_draws: int) -> str:
        return (f"RENDERER_STATS renderer={renderer} tk2Live={code_live} tk2Layouts=9 tk2Draws=9 "
                f"tk2CodeLive={code_live} tk2CodeDraws={code_draws} eligibleCodeRoots=20 fallbackCodeRoots=4 "
                "codeAdmitted=19 codeGated=1")
    text = ["APP: /builds/ADFReader.app", "READY fixture=code-parity blocks=24 firstChunkMs=12",
            stats(ready_live, ready_live)]
    if landed is not None:
        text += [f"SCROLL_LANDED fixture=code-parity fraction=0.42 index=10 block={landed} blocks=24",
                 stats(live, draws)]
        if rows is not None:
            text.append(f"TK2_CODE_ROWS live={0 if rows == '-' else rows.count(',') + 1} owners={rows}")
        text += geometry() if geo is None else geo
    path = os.path.join(work, name + ".log")
    with open(path, "w", newline="") as handle:
        handle.write("\r\n".join(text) + "\r\n")
    return path


def run_pairs(name: str, pairs: list[tuple[str, str, str, str]], *extra: str) -> tuple[int, dict]:
    """Several pairs in one run: (exit status, {pair name: scores.json entry})."""
    out = os.path.join(work, name)
    command = [sys.executable, "-I", DIFF, "--out", out]
    for kind, pair_name, ref, cand in pairs:
        command += ["--pair", kind, pair_name, ref, cand]
    res = subprocess.run(command + list(extra), capture_output=True, text=True)
    try:
        scored = {pair["name"]: pair for pair in json.load(open(os.path.join(out, "scores.json")))["pairs"]}
    except (OSError, KeyError, ValueError):
        scored = {}
    return res.returncode, scored


def code_capture(name: str, cls: str, owners: str, engine: str, log: str) -> tuple[str, ...]:
    return ("--code-capture", name, cls, owners, engine, log)


def expect(name: str, got: object, want: object) -> None:
    ok = got == want
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'}   ... {name}: {got!r} (want {want!r})")


code_a, code_b = code_page("code-a"), code_page("code-b")
good_log = proof_log("proof-good")
positive = "0.12=tk2;land=0.10"

code, pair = run_pair("cb-same", "tolerant", code_a, code_b, *code_capture("cb-same", "positive", positive, "textkit2", good_log))
check("identical code capture, owner-level proof and 0.12's row over the box (P1, 1x) -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("one code box, one code text crop", (pair.get("code_boxes"), pair.get("code_text_crops")), (1, 1))
expect("box found at its rectangle", pair["code_details"][0]["box"] if pair.get("code_details") else None, "20,80,280,200")
expect("three code lines scored", pair["code_details"][0]["lines"] if pair.get("code_details") else None, 3)
expect("proof is owner-level", str(pair.get("code_proof", "")).startswith("owner-level"), True)
box = pair["code_details"][0] if pair.get("code_details") else {}
expect("the box is attributed to owner 0.12's row, with its code-ink pixels",
       (box.get("owner"), box.get("owner_px", 0) > 0), ("tk2:0.12", True))
expect("the landing is measured", "land 0.10 measured" in pair.get("code_geometry", ""), True)

check("identical code boxes in a pair that declares nothing -> PASS (boxes scored anyway)",
      run("cb-undeclared", "exact", code_a, code_b), 0, "PASS")

dark_a, dark_b = code_page("code-dark-a", dark=True), code_page("code-dark-b", dark=True)
code, pair = run_pair("cb-dark", "exact", dark_a, dark_b)
check("dark appearance: the box is found on black", (code, pair["verdict"]), 0, "PASS")
expect("dark code boxes", pair.get("code_boxes"), 1)

# A viewport of mostly code (code-parity, code-dense: 70-80 % of the pixels
# are fill) has more fill than page. The page is still found: the commonest
# colour is the code fill of the runner-up, which fills whole rows (the gaps
# between blocks).
DENSE = dict(box=(4, 48, 296, 252), extra_boxes=((4, 268, 296, 396),))
# Owner 0.12's code row over the first dense box's code text (x 16 to 216, y 80 to 117).
dense_log = proof_log("proof-dense", geo=geometry("0.12|code|16,76,284,250|16,76,284,250|3"))
for label, dark in (("light", False), ("dark", True)):
    dense_a = code_page(f"code-dense-{label}-a", dark=dark, **DENSE)
    dense_b = code_page(f"code-dense-{label}-b", dark=dark, **DENSE)
    pixels = np.asarray(Image.open(dense_a).convert("RGB")).reshape(-1, 3)
    page_share = float((pixels == (0 if dark else 255)).all(axis=1).mean())
    expect(f"fill-dominated page ({label}): the page is the minority colour", page_share < 0.3, True)
    code, pair = run_pair(f"cb-dense-{label}", "tolerant", dense_a, dense_b,
                          *code_capture(f"cb-dense-{label}", "positive", positive, "textkit2", dense_log))
    check(f"fill-dominated page ({label}), identical positive capture -> PASS", (code, pair["verdict"]), 0, "PASS")
    expect(f"fill-dominated page ({label}): both boxes and their text crops",
           (pair.get("code_boxes"), pair.get("code_text_crops")), (2, 2))
dense_a = code_page("code-dense-light-a2", **DENSE)
code, pair = run_pair("cb-dense-dx", "tolerant", dense_a, code_page("code-dense-1px-right", text_dx=1, **DENSE),
                      *code_capture("cb-dense-dx", "positive", positive, "textkit2", dense_log))
check("fill-dominated page, code text moved 1 px right (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("... both boxes report it", pair.get("failing_code_boxes"), 2)
check("fill-dominated page, the second box 1 px lower -> FAIL",
      run("cb-dense-moved", "tolerant", dense_a,
          code_page("code-dense-box-lower", box=DENSE["box"], extra_boxes=((4, 269, 296, 397),))), 1, "FAIL")
# Guard: a page dominated by another tint (a decision row background, 246 on
# white) is not taken for code fill; it holds no code box.
tinted = dict(box=None, page_tint=((0, 48, 300, 400, (246, 246, 246)),))
code, pair = run_pair("cb-tint-dominated", "exact", code_page("tint-dominated-a", **tinted),
                      code_page("tint-dominated-b", **tinted))
check("page dominated by a non-code tint -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... and no code box is found on it", pair.get("code_boxes"), 0)

# Negative control: code text one pixel to the right.
moved_x = code_page("code-text-1px-right", text_dx=1)
code, pair = run_pair("cb-text-dx", "tolerant", code_a, moved_x, *code_capture("cb-text-dx", "positive", positive, "textkit2", good_log))
check("code text moved 1 px right (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("the move changes no pixel by the tolerant rule (hidden from every percentage)",
       (pair.get("viewport_px"), pair.get("max_crop_pct"), pair.get("max_abs_offset")), (0, 0.0, 0))
box = pair["code_details"][0] if pair.get("code_details") else {}
expect("horizontal displacement scored: dx, dy", (box.get("dx"), box.get("dy")), (1, 0))
expect("ink centroid moved 1 px in x", box.get("centroid_dx"), 1.0)
check("code text moved 1 px left (tolerant) -> FAIL",
      run("cb-text-dx-left", "tolerant", code_a, code_page("code-text-1px-left", text_dx=-1)), 1, "FAIL")
code, pair = run_pair("cb-text-dy", "tolerant", code_a, code_page("code-text-1px-down", text_dy=1))
check("code text moved 1 px down (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
box = pair["code_details"][0] if pair.get("code_details") else {}
expect("vertical displacement scored: dx, dy", (box.get("dx"), box.get("dy")), (0, 1))

# Negative control: chrome. One pixel, one grey level.
badge_pixel = code_page("code-badge-pixel", edits=((90, 40, 1),))
code, pair = run_pair("cb-chrome-header", "tolerant", code_a, badge_pixel)
check("one header-strip pixel one level off (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("invisible to the tolerant pixel rule", pair.get("viewport_px"), 0)
expect("header strip px at threshold 0", pair["code_details"][0]["header_px"] if pair.get("code_details") else None, 1)
edge_pixel = code_page("code-edge-pixel", edits=((150, 19, -1),))
code, pair = run_pair("cb-chrome-outline", "tolerant", code_a, edge_pixel)
check("one pixel just outside the box edge one level off (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("outline px at threshold 0", pair["code_details"][0]["outline_px"] if pair.get("code_details") else None, 1)
# Inside the first code line (rows 112 to 120, x 32 to 231), so inside the
# scored text crop and outside the chrome.
code, pair = run_pair("cb-text-pixel", "tolerant", code_a, code_page("code-text-pixel", edits=((115, 100, 1),)))
check("a pixel of the code text one level off (tolerant) -> PASS (text is tolerant, chrome is exact)",
      (code, pair["verdict"]), 0, "PASS")
box = pair["code_details"][0] if pair.get("code_details") else {}
tx0, ty0, tx1, ty1 = (int(v) for v in (box.get("text_box") or "0,0,0,0").split(","))
expect("the edited pixel (x 100, y 115) is inside the scored text crop", tx0 <= 100 < tx1 and ty0 <= 115 < ty1, True)
expect("... and not in the chrome: header and outline px at threshold 0",
       (box.get("header_px"), box.get("outline_px")), (0, 0))
taller = code_page("code-taller", box=(20, 80, 280, 201))
code, pair = run_pair("cb-geometry", "tolerant", code_a, taller)
check("the box one pixel taller (tolerant) -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("geometry names the move", pair["code_details"][0]["geometry"] if pair.get("code_details") else None, "moved +0,+0,+0,+1")
check("a code box only in the candidate -> FAIL",
      run("cb-extra-box", "tolerant", code_a, code_page("code-two-boxes", second_box=True)), 1, "FAIL")

# Chrome is exact only where A-A' is exactly stable.
noisy = code_page("code-a2-noisy", edits=((90, 40, 1),))
code, scored = run_pairs("cb-unstable", [("noise", "u-AA", code_a, noisy), ("tolerant", "u-AC", code_a, badge_pixel)])
expect("A-A' differs in the header strip: the noise pair FAILs", scored.get("u-AA", {}).get("verdict"), "FAIL")
expect("... and A-C's chrome is reported, not judged: INVALID", scored.get("u-AC", {}).get("verdict"), "INVALID")
expect("... with the A-A' count", "not exactly stable in A-A'" in scored.get("u-AC", {}).get("notes", ""), True)
code, scored = run_pairs("cb-stable", [("noise", "s-AA", code_a, code_b), ("tolerant", "s-AC", code_a, badge_pixel)])
expect("A-A' exact, A-C header pixel off: FAIL", scored.get("s-AC", {}).get("verdict"), "FAIL")
expect("... A-A' measured as 0 px",
       scored["s-AC"]["code_details"][0]["stable_header_px"] if scored.get("s-AC", {}).get("code_details") else None, 0)

# Without its matching A-A' pair, stability is not proven: exact chrome is
# not judged, and the pair is INVALID, never PASS (Astra review R4).
code, pair = run_pair("cb-no-control", "tolerant", code_a, code_b,
                      *code_capture("cb-no-control", "positive", positive, "textkit2", good_log), control=False)
check("identical positive code capture without its A-A' pair -> INVALID (chrome stability not proven)",
      (code, pair["verdict"]), 1, "INVALID")
box = pair["code_details"][0] if pair.get("code_details") else {}
expect("... the box is UNMEASURED, its chrome counts kept and A-A' not measured",
       (box.get("verdict"), box.get("header_px"), box.get("outline_px"), box.get("stable_header_px"),
        box.get("stable_outline_px")), ("UNMEASURED", 0, 0, -1, -1))
expect("... and the pair says why", "no matching A-A' pair" in pair.get("notes", ""), True)
code, pair = run_pair("cb-no-control-b", "exact", code_a, code_b,
                      *code_capture("cb-no-control-b", "positive", positive, "swiftui",
                                   proof_log("proof-swiftui-no-control", renderer="swiftui", live=0, draws=0,
                                             rows="-", geo=geometry("-"))), control=False)
check("the same for an A-B (exact) pair -> INVALID", (code, pair["verdict"]), 1, "INVALID")
code, scored = run_pairs("cb-other-control", [("noise", "o-AA", dark_a, dark_b), ("tolerant", "o-AC", code_a, code_b)])
expect("an A-A' pair of another reference proves nothing here: INVALID", scored.get("o-AC", {}).get("verdict"),
       "INVALID")
small = os.path.join(work, "code-a2-short.png")
Image.open(code_b).crop((0, 0, 300, 399)).save(small)
code, scored = run_pairs("cb-short-control", [("noise", "sh-AA", code_a, small), ("tolerant", "sh-AC", code_a, code_b)])
expect("an A' capture smaller than the reference proves nothing: INVALID", scored.get("sh-AC", {}).get("verdict"),
       "INVALID")
check("one header-strip pixel off without the A-A' pair -> INVALID (chrome not judged, not FAIL)",
      run("cb-chrome-header-no-control", "tolerant", code_a, badge_pixel, control=False), 1, "INVALID")
check("code text 1 px right without the A-A' pair -> FAIL (only the chrome rule waits for A-A')",
      run("cb-text-dx-no-control", "tolerant", code_a, moved_x, control=False), 1, "FAIL")

# A code capture without its crops is INVALID, never PASS.
plain_a, plain_b = code_page("plain-a", box=None), code_page("plain-b", box=None)
check("positive capture without any code box -> INVALID",
      run("cb-no-box", "tolerant", plain_a, plain_b, *code_capture("cb-no-box", "positive", positive, "textkit2", good_log)),
      1, "INVALID")
check("the same blank-of-code pair, undeclared -> PASS",
      run("cb-no-box-undeclared", "tolerant", plain_a, plain_b), 0, "PASS")
empty_a, empty_b = code_page("code-empty-a", lines=()), code_page("code-empty-b", lines=())
fallback_log = proof_log("proof-fallback", rows="0.14:2", geo=geometry(ROW_014_OFF))
fallback = "0.12=swiftui;land=0.10"
check("positive capture of an empty code block (no code ink) -> INVALID",
      run("cb-empty-positive", "tolerant", empty_a, empty_b,
          *code_capture("cb-empty-positive", "positive", positive, "textkit2", good_log)), 1, "INVALID")
code, pair = run_pair("cb-empty-fallback", "tolerant", empty_a, empty_b,
                      *code_capture("cb-empty-fallback", "fallback", fallback, "textkit2", fallback_log))
check("expected-fallback capture of an empty code block -> PASS on geometry, chrome and fallback",
      (code, pair["verdict"]), 0, "PASS")
expect("no code text crop", pair.get("code_text_crops"), 0)
panel_a, panel_b = code_page("panel-a", tint=(224, 241, 255)), code_page("panel-b", tint=(224, 241, 255))
code, pair = run_pair("cb-panel", "exact", panel_a, panel_b, *code_capture("cb-panel", "fallback", fallback, "none", "-"))
check("a tinted panel is not a code box: declared capture -> INVALID", (code, pair["verdict"]), 1, "INVALID")
no_copy_a, no_copy_b = code_page("no-copy-a", copy=False), code_page("no-copy-b", copy=False)
code, pair = run_pair("cb-no-copy", "exact", no_copy_a, no_copy_b)
expect("a grey box without a Copy icon is not a code box", pair.get("code_boxes"), 0)
band_a, band_b = code_page("band-a", top=-45), code_page("band-b", top=-45)
code, pair = run_pair("cb-top-band", "exact", band_a, band_b, "--top-band", "50",
                      *code_capture("cb-top-band", "fallback", fallback, "none", "-"))
check("a box cut by the top band is not scored as a code box -> INVALID", (code, pair["verdict"]), 1, "INVALID")

# Engine proof.
check("all-fallback capture declared positive (owner-level: no live code row) -> INVALID",
      run("cb-allfallback-owner", "tolerant", code_a, code_b,
          *code_capture("cb-allfallback-owner", "positive", positive, "textkit2",
                        proof_log("proof-allfallback", live=0, draws=0, rows="-"))), 1, "INVALID")
check("all-fallback capture declared positive (counters only: tk2CodeLive=0) -> INVALID",
      run("cb-allfallback-counters", "tolerant", code_a, code_b,
          *code_capture("cb-allfallback-counters", "positive", positive, "textkit2",
                        proof_log("proof-allfallback-counters", live=0, draws=0, rows=None))), 1, "INVALID")
check("positive, another owner is live but not the named one -> INVALID",
      run("cb-wrong-owner", "tolerant", code_a, code_b,
          *code_capture("cb-wrong-owner", "positive", positive, "textkit2", proof_log("proof-other", rows="0.14:2"))),
      1, "INVALID")
check("positive, the named owner is live but never drew natively -> INVALID",
      run("cb-no-draw", "tolerant", code_a, code_b,
          *code_capture("cb-no-draw", "positive", positive, "textkit2", proof_log("proof-nodraw", rows="0.12:0"))),
      1, "INVALID")
code, pair = run_pair("cb-counters", "tolerant", code_a, code_b,
                      *code_capture("cb-counters", "positive", positive, "textkit2", proof_log("proof-counters", rows=None)))
check("positive with counters only (no TK2_CODE_ROWS line) -> INVALID (the owner-level proof is required)",
      (code, pair["verdict"]), 1, "INVALID")
expect("... and says so", "no TK2_CODE_ROWS line" in pair.get("notes", ""), True)
check("... the same with --require-owner-proof (accepted, always on) -> INVALID",
      run("cb-counters-required", "tolerant", code_a, code_b, "--require-owner-proof",
          *code_capture("cb-counters-required", "positive", positive, "textkit2", proof_log("proof-counters-2", rows=None))),
      1, "INVALID")
check("stats at READY only (no SCROLL_LANDED), even with live code rows -> INVALID",
      run("cb-ready-only", "tolerant", code_a, code_b,
          *code_capture("cb-ready-only", "positive", positive, "textkit2", proof_log("proof-ready", landed=None, ready_live=5))),
      1, "INVALID")
check("landed on another block than declared -> INVALID",
      run("cb-landed-elsewhere", "tolerant", code_a, code_b,
          *code_capture("cb-landed-elsewhere", "positive", positive, "textkit2", proof_log("proof-landed", landed="0.9"))),
      1, "INVALID")
check("candidate declared textkit2 but the log says swiftui -> INVALID",
      run("cb-wrong-engine", "tolerant", code_a, code_b,
          *code_capture("cb-wrong-engine", "positive", positive, "textkit2", proof_log("proof-engine", renderer="swiftui"))),
      1, "INVALID")
check("missing launch log -> INVALID",
      run("cb-no-log", "tolerant", code_a, code_b,
          *code_capture("cb-no-log", "positive", positive, "textkit2", os.path.join(work, "absent.log"))), 1, "INVALID")
code, pair = run_pair("cb-fallback", "tolerant", code_a, code_b,
                      *code_capture("cb-fallback", "fallback", fallback, "textkit2", fallback_log))
check("expected-fallback capture, its owner has no TextKit 2 row -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("class recorded as fallback", pair.get("code_class"), "fallback")
check("expected-fallback capture whose owner is drawn by TextKit 2 -> INVALID",
      run("cb-fallback-native", "tolerant", code_a, code_b,
          *code_capture("cb-fallback-native", "fallback", fallback, "textkit2", good_log)), 1, "INVALID")
check("expected-fallback, counters only, live code rows elsewhere: not provable -> INVALID",
      run("cb-fallback-counters", "tolerant", code_a, code_b,
          *code_capture("cb-fallback-counters", "fallback", fallback, "textkit2",
                        proof_log("proof-fb-counters", rows=None, geo=geometry(ROW_014_OFF)))),
      1, "INVALID")
check("expected-fallback, counters only, tk2CodeLive=0 -> INVALID (the owner-level proof is required)",
      run("cb-fallback-zero", "tolerant", code_a, code_b,
          *code_capture("cb-fallback-zero", "fallback", fallback, "textkit2",
                        proof_log("proof-fb-zero", live=0, draws=3, rows=None, geo=geometry("-")))), 1, "INVALID")
swiftui_log = proof_log("proof-swiftui", renderer="swiftui", live=0, draws=0, rows="-", geo=geometry("-"))
check("SwiftUI arm (B) with zero code counters -> PASS",
      run("cb-b-arm", "exact", code_a, code_b, *code_capture("cb-b-arm", "positive", positive, "swiftui", swiftui_log)),
      0, "PASS")
check("SwiftUI arm (B) reporting TextKit 2 code draws -> INVALID",
      run("cb-b-arm-native", "exact", code_a, code_b,
          *code_capture("cb-b-arm-native", "positive", positive, "swiftui",
                        proof_log("proof-swiftui-native", renderer="swiftui", live=0, draws=2, rows="-",
                                  geo=geometry("-")))), 1, "INVALID")
check("reference build (engine none): no proof asked -> PASS",
      run("cb-a-arm", "noise", code_a, code_b, *code_capture("cb-a-arm", "positive", positive, "none", "-")), 0, "PASS")

# A fallback capture is never native coverage.
code, scored = run_pairs(
    "cb-coverage", [("noise", "cov-AA", code_a, code_b), ("tolerant", "cov-pos-AC", code_a, code_b),
                    ("tolerant", "cov-fb-AC", code_a, code_b)],
    *code_capture("cov-pos-AC", "positive", positive, "textkit2", good_log),
    *code_capture("cov-fb-AC", "fallback", fallback, "textkit2", fallback_log))
try:
    coverage = json.load(open(os.path.join(work, "cb-coverage", "scores.json")))["code_coverage"]
except (OSError, KeyError, ValueError):
    coverage = {}
expect("coverage counts the positive capture only", (code, coverage.get("positive_pass"), coverage.get("fallback_pass")), (0, 1, 1))

# Capture-time geometry (docstring "CODE CAPTURES", G1-G9): the engine proof
# says a row drew, the geometry says whose row covers the pixels scored.
def geo_case(name: str, owners: str, log: str, *extra: str, cls: str = "positive", engine: str = "textkit2",
             kind: str = "tolerant", ref: str | None = None, cand: str | None = None) -> tuple[int, dict]:
    return run_pair(name, kind, ref or code_a, cand or code_b, *extra,
                    *code_capture(name, cls, owners, engine, log))


def notes_of(pair: dict) -> str:
    return pair.get("notes", "")


def owners_of(pair: dict) -> list[str]:
    return [box.get("owner") for box in pair.get("code_details", [])]


# Negative 1, the review's case (Astra R1, Fable R5): the declared owner's
# row is alive and has drawn (TK2_CODE_ROWS 0.12:3) but sits below the
# window, and the image shows the box: the box is SwiftUI's.
code, pair = geo_case("g-offscreen", positive,
                      proof_log("geo-offscreen", geo=geometry("0.12|code|32,500,268,560|-|3")))
check("positive, owner 0.12 live and drawn but off the image -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... the box is marked swiftui", owners_of(pair), ["swiftui"])
expect("... and the note names 0.12", "owner 0.12: its row is clipped off screen" in notes_of(pair), True)
code, pair = geo_case("g-pre-fix", positive, proof_log("geo-pre-fix", geo=[]))
check("the same log with no geometry lines (the pre-fix input) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... no CAPTURE_GEOMETRY", "no CAPTURE_GEOMETRY seq=1" in notes_of(pair), True)

# Negative 2: on screen, but over the page text, not over the box.
code, pair = geo_case("g-elsewhere", positive,
                      proof_log("geo-elsewhere", geo=geometry("0.12|code|20,30,220,40|20,30,220,40|3")))
check("positive, owner 0.12 on screen over no scored code box -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "owner 0.12: on screen but over no scored code box" in notes_of(pair), True)

# Negative 3: the frame holds only the first code line.
code, pair = geo_case("g-partial", positive,
                      proof_log("geo-partial", geo=geometry("0.12|code|32,112,268,122|32,112,268,122|3")))
check("positive, owner 0.12's frame covers only the first code line -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... the box is mixed", owners_of(pair), ["mixed"])
expect("... and the note counts the ink outside", "code ink outside owner 0.12's on-screen frame" in notes_of(pair), True)

# Negative 4: two code rows over one box.
code, pair = geo_case("g-two-rows", "0.12=tk2,0.13=tk2;land=0.10",
                      proof_log("geo-two-rows", rows="0.12:3,0.13:2",
                                geo=geometry(ROW_012 + ";0.13|code|32,140,268,190|32,140,268,190|2")))
check("two TextKit 2 code rows over one box -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "two TextKit 2 rows over one box (0.12,0.13)" in notes_of(pair), True)

# Negative 5 (G4, G5): a fallback capture whose box an undeclared TextKit 2
# row covers exactly.
code, pair = geo_case("g-fallback-native", fallback,
                      proof_log("geo-fallback-native", rows="0.13:2",
                                geo=geometry("0.13|code|32,112,268,190|32,112,268,190|2")), cls="fallback")
check("fallback, an undeclared TextKit 2 row drew the box -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... the box is tk2:0.13", owners_of(pair), ["tk2:0.13"])

# Negative 6 (G6): a fallback capture whose declared swiftui owner has a row
# in the window (off screen), born after TK2_CODE_ROWS was printed.
code, pair = geo_case("g-fallback-row", fallback,
                      proof_log("geo-fallback-row", rows="0.14:2",
                                geo=geometry("0.12|code|32,500,268,560|-|0;" + ROW_014_OFF)), cls="fallback")
check("fallback, declared swiftui 0.12 has a TextKit 2 row in the window -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "owner 0.12 (declared swiftui) has a TextKit 2 row in the window (off screen)" in notes_of(pair), True)

# Negative 7 (G1): the bracket.
code, pair = geo_case("g-moved", positive,
                      proof_log("geo-moved", geo=geometry(second="0.12|code|32,113,268,191|32,113,268,191|3")))
check("seq=2's frame 1 pt lower than seq=1's -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... the screen changed across the screenshot", "geometry changed across the screenshot (rows)" in notes_of(pair), True)
check("only seq=1 (no line after the screenshot) -> INVALID",
      run("g-only-1", "tolerant", code_a, code_b,
          *code_capture("g-only-1", "positive", positive, "textkit2", proof_log("geo-only-1", geo=geometry()[:1]))),
      1, "INVALID")
check("a seq=3 line (the protocol posts exactly twice) -> INVALID",
      run("g-seq-3", "tolerant", code_a, code_b,
          *code_capture("g-seq-3", "positive", positive, "textkit2",
                        proof_log("geo-seq-3", geo=geometry() + [geometry()[1].replace("seq=2", "seq=3")]))),
      1, "INVALID")
check("seq=1 is error=no-key-window -> INVALID",
      run("g-no-window", "tolerant", code_a, code_b,
          *code_capture("g-no-window", "positive", positive, "textkit2",
                        proof_log("geo-no-window", geo=["CAPTURE_GEOMETRY seq=1 error=no-key-window", geometry()[1]]))),
      1, "INVALID")
check("draws differing across the screenshot (a redraw) -> PASS",
      run("g-redraw", "tolerant", code_a, code_b,
          *code_capture("g-redraw", "positive", positive, "textkit2",
                        proof_log("geo-redraw", geo=geometry(second="0.12|code|32,112,268,190|32,112,268,190|4")))),
      0, "PASS")

# Negative 8 (G1): the geometry describes another image size.
code, pair = geo_case("g-size", positive, proof_log("geo-size", geo=geometry(scale=3)))
check("scale=3 screen=300x400 on a 300x400 image -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names both sizes", "geometry is 300x400 pt at 3x, the image is 300x400 px" in notes_of(pair), True)
check("a window that is not the whole screen -> INVALID",
      run("g-window", "tolerant", code_a, code_b,
          *code_capture("g-window", "positive", positive, "textkit2",
                        proof_log("geo-window", geo=geometry(window="0,20,300,400")))), 1, "INVALID")

# Negative 9 (G7): the landing is measured, not taken from the jump's target.
check("land block 0.10 not in visibleRows -> INVALID",
      run("g-land-missing", "tolerant", code_a, code_b,
          *code_capture("g-land-missing", "positive", positive, "textkit2",
                        proof_log("geo-land-missing", geo=geometry(visible="0.11,0.12")))), 1, "INVALID")
code, pair = geo_case("g-land-high", positive, proof_log("geo-land-high", geo=geometry(visible="0.8,0.10,0.11,0.12")))
check("block 0.8 fully visible with land 0.10 (landed higher) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names the block above", "block(s) 0.8 above the land block 0.10" in notes_of(pair), True)
check("block 0.9 fully visible with land 0.10 (one block of slack) -> PASS",
      run("g-land-slack", "tolerant", code_a, code_b,
          *code_capture("g-land-slack", "positive", positive, "textkit2",
                        proof_log("geo-land-slack", geo=geometry(visible="0.9,0.10,0.11,0.12")))), 0, "PASS")
check("visibleRows=unavailable (no visibility feed) -> INVALID",
      run("g-land-unavailable", "tolerant", code_a, code_b,
          *code_capture("g-land-unavailable", "positive", positive, "textkit2",
                        proof_log("geo-land-unavailable", geo=geometry(visible="unavailable")))), 1, "INVALID")
code, pair = geo_case("g-land-under-band", positive,
                      proof_log("geo-land-under-band",
                                geo=geometry(ROW_012 + ";0.10|root|20,40,220,52|20,40,220,52|-")), "--top-band", "60")
check("the land block's TextKit 2 row under the top band -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "row starts at 40.0 px, under the top band (60 px)" in notes_of(pair), True)
check("the land block's TextKit 2 row just below the top band -> PASS",
      run("g-land-below-band", "tolerant", code_a, code_b, "--top-band", "60",
          *code_capture("g-land-below-band", "positive", positive, "textkit2",
                        proof_log("geo-land-below-band",
                                  geo=geometry(ROW_012 + ";0.10|root|20,62,220,74|20,62,220,74|-")))), 0, "PASS")

# Negative 10 (G8): a fallback capture must show a named owner.
code, pair = geo_case("g-absent", fallback,
                      proof_log("geo-absent", rows="0.14:2", geo=geometry(ROW_014_OFF, visible="0.10,0.11")), cls="fallback")
check("fallback, no declared owner in visibleRows -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "no declared owner is visibly present" in notes_of(pair), True)
check("fallback, nested owner 0.30.0.1 present through its top-level block 0.30 -> PASS",
      run("g-nested", "tolerant", code_a, code_b,
          *code_capture("g-nested", "fallback", "0.30.0.1=swiftui;land=0.10", "textkit2",
                        proof_log("geo-nested", rows="0.14:2", geo=geometry(ROW_014_OFF, visible="0.10,0.30")))),
      0, "PASS")
check("... and absent when only 0.31 is visible -> INVALID",
      run("g-nested-absent", "tolerant", code_a, code_b,
          *code_capture("g-nested-absent", "fallback", "0.30.0.1=swiftui;land=0.10", "textkit2",
                        proof_log("geo-nested-absent", rows="0.14:2", geo=geometry(ROW_014_OFF, visible="0.10,0.31")))),
      1, "INVALID")

# Negative 11 (G9): the SwiftUI arm has no TextKit 2 row at all.
check("B arm (swiftui) whose geometry lists a TextKit 2 row -> INVALID",
      run("g-b-row", "exact", code_a, code_b,
          *code_capture("g-b-row", "positive", positive, "swiftui",
                        proof_log("geo-b-row", renderer="swiftui", live=0, draws=0, rows="-",
                                  geo=geometry("0.10|root|20,30,220,41|20,30,220,41|-")))), 1, "INVALID")
check("B arm without a measured landing -> INVALID",
      run("g-b-land", "exact", code_a, code_b,
          *code_capture("g-b-land", "positive", positive, "swiftui",
                        proof_log("geo-b-land", renderer="swiftui", live=0, draws=0, rows="-",
                                  geo=geometry("-", visible="0.11,0.12")))), 1, "INVALID")

# Negative 12 (Fable (b)): a candidate arm without renderer stats.
check("engine none on a tolerant pair -> INVALID (no engine proof)",
      run("g-none-tolerant", "tolerant", code_a, code_b, *code_capture("g-none-tolerant", "positive", positive, "none", "-")),
      1, "INVALID")
check("engine none on an exact pair -> INVALID",
      run("g-none-exact", "exact", code_a, code_b, *code_capture("g-none-exact", "positive", positive, "none", "-")),
      1, "INVALID")

# P2, P3: the same image described at 2x and at 3x.
code, pair = geo_case("g-2x", positive,
                      proof_log("geo-2x", geo=geometry("0.12|code|16,56,134,95|16,56,134,95|3", scale=2,
                                                       screen=(150, 200))))
check("2x geometry (150x200 pt) of the same image -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... 0.12 owns the box", owners_of(pair), ["tk2:0.12"])
row_3x = "0.12|code|10.6667,37.3333,89.3333,63.3333|10.6667,37.3333,89.3333,63.3333|3"
code, pair = geo_case("g-3x", positive,
                      proof_log("geo-3x", geo=geometry(row_3x, scale="3.0000", screen=("100.0000", "133.3333"),
                                                       window="0.0000,0.0000,100.0000,133.3333")))
check("3x geometry with 4-decimal points (100x133.3333 pt) -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... 0.12 owns the box", owners_of(pair), ["tk2:0.12"])

# P4, the mixed CP-S4 declaration: CP-15 (SwiftUI), CP-16 (TextKit 2), CP-17
# (SwiftUI) under the heading 0.17.
CPS4 = dict(box=(20, 50, 280, 150), extra_boxes=((20, 160, 280, 250), (20, 260, 280, 350)))
cps4_a, cps4_b = code_page("cps4-a", **CPS4), code_page("cps4-b", **CPS4)
cps4 = "0.18=swiftui,0.19=tk2,0.20=swiftui;land=0.17"
cps4_rows = "0.17|root|20,30,220,41|20,30,220,41|-;0.19|code|32,192,268,240|32,192,268,240|5"
code, pair = geo_case("g-cps4", cps4,
                      proof_log("geo-cps4", rows="0.19:5", landed="0.17",
                                geo=geometry(cps4_rows, visible="0.17,0.18,0.19")), ref=cps4_a, cand=cps4_b)
check("CP-S4 shape, 0.19's row over the middle box -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... owners per box", owners_of(pair), ["swiftui", "tk2:0.19", "swiftui"])
code, pair = geo_case("g-cps4-off", cps4,
                      proof_log("geo-cps4-off", rows="0.19:5", landed="0.17",
                                geo=geometry(cps4_rows.replace("32,192,268,240|5", "-|5"), visible="0.17,0.18,0.19")),
                      ref=cps4_a, cand=cps4_b)
check("CP-S4 shape, 0.19 alive and drawn but not shown (only SwiftUI boxes scored) -> INVALID",
      (code, pair["verdict"]), 1, "INVALID")
expect("... names 0.19", "owner 0.19" in notes_of(pair), True)
try:
    summary_md = open(os.path.join(work, "g-cps4", "summary.md")).read()
except OSError:
    summary_md = ""
expect("summary.md has the code geometry column", "| code geometry |" in summary_md, True)

# Usage errors.
check("--code-capture for a pair that does not exist -> usage error",
      run("cb-usage-name", "tolerant", code_a, code_b, *code_capture("other", "positive", positive, "none", "-")),
      2, "(no scores.json)")
check("positive declaration without a tk2 owner -> usage error",
      run("cb-usage-owner", "tolerant", code_a, code_b,
          *code_capture("cb-usage-owner", "positive", "0.12=swiftui;land=0.10", "none", "-")), 2, "(no scores.json)")
check("fallback declaration naming a tk2 owner -> usage error",
      run("cb-usage-fallback", "tolerant", code_a, code_b,
          *code_capture("cb-usage-fallback", "fallback", "0.12=tk2;land=0.10", "none", "-")), 2, "(no scores.json)")
check("a declaration without land= -> usage error (the landing is measured)",
      run("cb-usage-land", "tolerant", code_a, code_b,
          *code_capture("cb-usage-land", "positive", "0.12=tk2", "textkit2", good_log)), 2, "(no scores.json)")


# ------------------------------------------------- container and caption captures
# PR 4 (plan §5 step 3 item 5, P16): the declaration's class carries a kind
# (container:positive, caption:fallback); the kind's counters and per-owner
# line prove the engine, the capture-time geometry ties each tk2 owner to
# its TextKit 2 row, and a text crop over that row's on-screen frame is
# held to the code text rule.

def container_page(name: str, *, text_dx: int = 0, text_dy: int = 0, lines: tuple[int, ...] = (200, 150, 110),
                   text: bool = True, caption_dx: int = 0, line_dx: tuple[int, ...] = (),
                   band_tint: tuple[int, int, int] | None = None) -> str:
    """A 300x400 white page: a page text line (y 30-40), a tinted panel
    (x 20-280, y 80-200) holding soft-edged text lines from (40, 100) every
    14 px (a container owner's text; `text_dx`/`text_dy` move it, and
    `line_dx[i]` moves line i alone), and a light media box (y 220-300)
    with a soft-edged caption line at (40, 310) (`caption_dx` moves it).
    Tint and media box stay under the ink threshold, as a panel's tint
    does. `band_tint` repaints the panel's bottom band (y 160-198, away
    from its text) in another low-contrast tint: a fill difference."""
    background, ink = 255, 20
    img = np.full((400, 300, 3), background, dtype=np.uint8)
    img[30:40, 20:220] = ink
    tint = (224, 241, 255)
    img[80:200, 20:280] = tint
    if band_tint is not None:
        img[160:198, 20:280] = band_tint

    def soft_line(top: int, left: int, width: int, level: float) -> None:
        profile = np.full(width, float(ink))
        ramp = level + (ink - level) * np.arange(1, 11) / 11.0
        profile[:10], profile[-10:] = ramp, ramp[::-1]
        img[top:top + 9, left:left + width] = np.round(profile)[None, :, None]

    if text:
        for index, width in enumerate(lines):
            dx = text_dx + (line_dx[index] if index < len(line_dx) else 0)
            soft_line(100 + index * 14 + text_dy, 40 + dx, width, float(np.mean(tint)))
    img[220:300, 20:280] = 235
    soft_line(310, 40 + caption_dx, 180, float(background))
    path = os.path.join(work, name + ".png")
    Image.fromarray(img).save(path)
    return path


# Owner 0.4.0's container row over the panel text (x 40-240, y 100-137) and
# caption owner 0.6.0's row over the caption line (x 40-220, y 310-319), at 1x.
ROW_040 = "0.4.0|root|36,96,264,141|36,96,264,141|-"
ROW_060 = "0.6.0|root|36,306,264,323|36,306,264,323|-"


def owner_log(name: str, *, renderer: str = "textkit2", container: tuple[int, int] | None = (1, 4),
              caption: tuple[int, int] | None = (0, 0), container_rows: str | None = "0.4.0:4",
              caption_rows: str | None = "-", landed: str = "0.3", geo: list[str] | None = None,
              visible: str = "0.3,0.4,0.5,0.6", code: tuple[int, int] = (0, 0), code_rows: str = "-") -> str:
    """A launch log of a container or caption capture: READY, then after
    SCROLL_LANDED the stats with the code, container and caption keys
    (`code` / `container` / `caption` = (live, draws); None leaves the
    container or caption keys out: a build without them), TK2_CODE_ROWS
    (`code_rows`), TK2_CONTAINER_ROWS and TK2_CAPTION_ROWS (None leaves a
    line out) and the geometry (default: 0.4.0's row)."""
    keys = (f"tk2CodeLive={code[0]} tk2CodeDraws={code[1]} eligibleCodeRoots=0 fallbackCodeRoots=0 "
            "codeAdmitted=0 codeGated=0")
    if container is not None:
        keys += f" tk2ContainerLive={container[0]} tk2ContainerNativeDraws={container[1]} tk2ContainerTK1Draws=0"
    if caption is not None:
        keys += f" tk2CaptionLive={caption[0]} tk2CaptionNativeDraws={caption[1]}"
    text = ["APP: /builds/ADFReader.app", "READY fixture=containers-parity blocks=12 firstChunkMs=9",
            f"RENDERER_STATS renderer={renderer} tk2Live=0 {keys}",
            f"SCROLL_LANDED fixture=containers-parity fraction=0.25 index=3 block={landed} blocks=12",
            f"RENDERER_STATS renderer={renderer} tk2Live=3 {keys}",
            f"TK2_CODE_ROWS live={0 if code_rows == '-' else code_rows.count(',') + 1} owners={code_rows}"]
    for marker, rows in (("TK2_CONTAINER_ROWS", container_rows), ("TK2_CAPTION_ROWS", caption_rows)):
        if rows is not None:
            text.append(f"{marker} live={0 if rows == '-' else rows.count(',') + 1} owners={rows}")
    text += geometry(ROW_040, visible=visible) if geo is None else geo
    path = os.path.join(work, name + ".log")
    with open(path, "w", newline="") as handle:
        handle.write("\r\n".join(text) + "\r\n")
    return path


def owner_case(name: str, label: str, owners: str, log: str, *extra: str, engine: str = "textkit2",
               kind: str = "tolerant", ref: str | None = None, cand: str | None = None) -> tuple[int, dict]:
    return run_pair(name, kind, ref or panel_ref, cand or panel_cand, *extra,
                    *code_capture(name, label, owners, engine, log))


def owner_crops_of(pair: dict) -> list[tuple[str, str]]:
    return [(crop.get("owner"), crop.get("verdict")) for crop in pair.get("owner_details", [])]


panel_ref, panel_cand = container_page("panel-ref"), container_page("panel-cand")
container_pos = "0.4.0=tk2;land=0.3"
container_good = owner_log("own-good")

code, pair = owner_case("o-same", "container:positive", container_pos, container_good)
check("container capture, identical, 0.4.0's row over the panel text -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("one owner text crop, three lines, PASS", (owner_crops_of(pair), (pair.get("owner_details") or [{}])[0].get("lines")),
       ([("0.4.0", "PASS")], 3))
expect("the class carries the kind", pair.get("owner_class"), "container:positive")
expect("the proof reads the container keys",
       pair.get("owner_proof", "").startswith("container: owner-level: tk2ContainerLive=1 tk2ContainerNativeDraws=4"), True)
expect("no code class (no code declaration)", pair.get("code_class"), "")
expect("the crop is the row's frame", (pair.get("owner_details") or [{}])[0].get("box"), "36,96,264,141")

moved_right = container_page("panel-1px-right", text_dx=1)
check("container text 1 px right, undeclared: invisible to the text crops -> PASS",
      run("o-dx-undeclared", "tolerant", panel_ref, moved_right), 0, "PASS")
code, pair = owner_case("o-dx", "container:positive", container_pos, owner_log("own-dx"), cand=moved_right)
check("container text 1 px right, declared -> FAIL (the owner text crop)", (code, pair["verdict"]), 1, "FAIL")
expect("... the crop says x", "container line displaced +1,+0 px (x,y)" in (pair.get("owner_details") or [{}])[0].get("notes", ""), True)
code, pair = owner_case("o-dy", "container:positive", container_pos, owner_log("own-dy"),
                        cand=container_page("panel-1px-lower", text_dy=1))
check("container text 1 px lower -> FAIL", (code, pair["verdict"]), 1, "FAIL")
code, pair = owner_case("o-missing", "container:positive", container_pos, owner_log("own-missing"),
                        cand=container_page("panel-no-text", text=False))
check("container text missing in the candidate under its row -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("... and its crop says the row's drawing is not on screen",
       "no candidate ink inside owner 0.4.0's on-screen frame" in (pair.get("owner_details") or [{}])[0].get("notes", ""), True)

# F-R24: two tk2 owners of one kind, only one failing. 0.4.0's row holds
# the panel's first line (y 100-109), 0.4.1's the second and third.
ROW_040_TOP = "0.4.0|root|36,96,264,112|36,96,264,112|-"
ROW_041 = "0.4.1|list|36,112,264,141|36,112,264,141|-"
two_pos = "0.4.0=tk2,0.4.1=tk2;land=0.3"
two_geo = geometry(ROW_040_TOP + ";" + ROW_041, visible="0.3,0.4")
code, pair = owner_case("o-two", "container:positive", two_pos,
                        owner_log("own-two", container=(2, 7), container_rows="0.4.0:4,0.4.1:3", geo=two_geo))
check("two tk2 container owners, identical -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... one crop per owner", owner_crops_of(pair), [("0.4.0", "PASS"), ("0.4.1", "PASS")])
code, pair = owner_case("o-two-one-moved", "container:positive", two_pos,
                        owner_log("own-two-one-moved", container=(2, 7), container_rows="0.4.0:4,0.4.1:3", geo=two_geo),
                        cand=container_page("panel-line2-1px-right", line_dx=(0, 1, 0)))
check("two tk2 owners, only 0.4.1's second line 1 px right -> FAIL", (code, pair["verdict"]), 1, "FAIL")
expect("... 0.4.0's crop passes, 0.4.1's fails", owner_crops_of(pair), [("0.4.0", "PASS"), ("0.4.1", "FAIL")])
code, pair = owner_case("o-two-one-tk1", "container:positive", two_pos,
                        owner_log("own-two-one-tk1", container=(2, 4), container_rows="0.4.0:4,0.4.1:0", geo=two_geo))
check("two tk2 owners, only 0.4.1 TextKit 1-backed (0 native draws) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names 0.4.1 only", ("owner 0.4.1 is a live TextKit 2 container row with no native draw" in notes_of(pair),
                                "owner 0.4.0 is a live" in notes_of(pair)), (True, False))
code, pair = owner_case("o-two-one-off", "container:positive", two_pos,
                        owner_log("own-two-one-off", container=(2, 7), container_rows="0.4.0:4,0.4.1:3",
                                  geo=geometry(ROW_040_TOP + ";0.4.1|list|36,500,264,545|-|-", visible="0.3,0.4")))
check("two tk2 owners, only 0.4.1's row off screen -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names 0.4.1", "owner 0.4.1: its row is clipped off screen" in notes_of(pair), True)

# Engine proof (the kind's keys and per-owner line).
code, pair = owner_case("o-no-keys", "container:positive", container_pos, owner_log("own-no-keys", container=None))
check("a build without the container keys -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "a build without the container keys" in notes_of(pair), True)
code, pair = owner_case("o-no-line", "container:positive", container_pos, owner_log("own-no-line", container_rows=None))
check("no TK2_CONTAINER_ROWS line -> INVALID (the owner-level proof is required)", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "no TK2_CONTAINER_ROWS line after SCROLL_LANDED" in notes_of(pair), True)
code, pair = owner_case("o-tk1", "container:positive", container_pos,
                        owner_log("own-tk1", container=(1, 0), container_rows="0.4.0:0"))
check("the owner's row is TextKit 1-backed (0 native draws) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names it", "owner 0.4.0 is a live TextKit 2 container row with no native draw" in notes_of(pair), True)
code, pair = owner_case("o-other", "container:positive", container_pos, owner_log("own-other", container_rows="0.4.1:2"))
check("the owner is not in TK2_CONTAINER_ROWS (only another owner is) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... names it", "owner 0.4.0 has no live TextKit 2 container row (declared tk2)" in notes_of(pair), True)
check("the code counters alone prove no container (code draws, container 0) -> INVALID",
      run("o-code-only", "tolerant", panel_ref, panel_cand,
          *code_capture("o-code-only", "container:positive", container_pos, "textkit2",
                        owner_log("own-code-only", container=(0, 0), container_rows="-"))), 1, "INVALID")
# F-R24: the owner's text drawn natively by a live code row (code counters
# and TK2_CODE_ROWS > 0, its geometry row a code row with draws), the
# container counters 0: the code proof is never container proof.
code_only_geo = geometry(ROW_040.replace("|root|", "|code|").replace("|-", "|4"), visible="0.3,0.4")
code, pair = owner_case("o-code-draws", "container:positive", container_pos,
                        owner_log("own-code-draws", container=(0, 0), container_rows="-", code=(1, 4),
                                  code_rows="0.4.0:4", geo=code_only_geo))
check("the owner drawn natively by a code row (code 1/4, 0.4.0:4 in TK2_CODE_ROWS), container 0 -> INVALID",
      (code, pair["verdict"]), 1, "INVALID")
expect("... the container proof names the zero counters, the geometry the code row",
       ("tk2ContainerLive=0" in notes_of(pair), "owner 0.4.0: its TextKit 2 row is a code row" in notes_of(pair)),
       (True, True))
code, pair = owner_case("o-code-draws-listed", "container:positive", container_pos,
                        owner_log("own-code-draws-listed", container=(1, 4), container_rows="-", code=(1, 4),
                                  code_rows="0.4.0:4", geo=code_only_geo))
check("... with container counters > 0 but the owner listed only as a code row -> INVALID",
      (code, pair["verdict"]), 1, "INVALID")
expect("... names it", "owner 0.4.0 has no live TextKit 2 container row (declared tk2)" in notes_of(pair), True)

# Owner geometry (O3, O4, O6, O8).
code, pair = owner_case("o-code-row", "container:positive", container_pos,
                        owner_log("own-code-row", geo=geometry(ROW_040.replace("|root|", "|code|").replace("|-", "|4"),
                                                               visible="0.3,0.4")))
check("the owner's only row is a code row -> INVALID (container proof counts no code row)", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "owner 0.4.0: its TextKit 2 row is a code row" in notes_of(pair), True)
code, pair = owner_case("o-off", "container:positive", container_pos,
                        owner_log("own-off", geo=geometry("0.4.0|root|36,500,264,545|-|-", visible="0.3,0.4")))
check("the owner's row is live but off screen -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "owner 0.4.0: its row is clipped off screen" in notes_of(pair), True)
code, pair = owner_case("o-no-row", "container:positive", container_pos,
                        owner_log("own-no-row", geo=geometry("-", visible="0.3,0.4")))
check("no TextKit 2 row for the owner in the window -> INVALID", (code, pair["verdict"]), 1, "INVALID")
code, pair = owner_case("o-blank", "container:positive", container_pos,
                        owner_log("own-blank", geo=geometry("0.4.0|root|36,330,264,380|36,330,264,380|-",
                                                            visible="0.3,0.4")))
check("the owner's row is shown over no text in either image -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "no text ink inside owner 0.4.0's on-screen frame in either image" in notes_of(pair), True)
code, pair = owner_case("o-band", "container:positive", container_pos, owner_log("own-band"), "--top-band", "150")
check("the owner's row under the top band (no scorable pixel) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... no owner text crop for a positive capture", "positive container capture without an owner text crop" in notes_of(pair), True)

fallback_pos = "0.4.0=swiftui;land=0.3"
fallback_log = owner_log("own-fallback", container=(0, 0), container_rows="-", geo=geometry("-", visible="0.3,0.4"))
code, pair = owner_case("o-fallback", "container:fallback", fallback_pos, fallback_log)
check("container fallback, the owner has no TextKit 2 row -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... no owner crop on a fallback capture", pair.get("owner_crops"), 0)
code, pair = owner_case("o-fallback-row", "container:fallback", fallback_pos,
                        owner_log("own-fallback-row", container_rows="-"))
check("container fallback, the swiftui owner has a TextKit 2 row in the window (O6) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "owner 0.4.0 (declared swiftui) has a TextKit 2 row in the window (on screen)" in notes_of(pair), True)
other_on_screen = geometry("0.4.1|list|36,150,264,190|36,150,264,190|-", visible="0.3,0.4")
code, pair = owner_case("o-fallback-other", "container:fallback", fallback_pos,
                        owner_log("own-fallback-other", container_rows="0.4.1:2", geo=other_on_screen))
check("container fallback, an undeclared container row on screen (O4) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "TextKit 2 container row 0.4.1 is on screen (a fallback capture)" in notes_of(pair), True)
code, pair = owner_case("o-positive-other", "container:positive", container_pos,
                        owner_log("own-positive-other", container_rows="0.4.0:4,0.4.1:2",
                                  geo=geometry(ROW_040 + ";0.4.1|list|36,150,264,190|36,150,264,190|-",
                                               visible="0.3,0.4")))
check("container positive, an undeclared container row on screen -> PASS (information, not coverage)",
      (code, pair["verdict"]), 0, "PASS")
expect("... noted", "undeclared native owner 0.4.1 (not coverage)" in pair.get("owner_geometry", ""), True)
code, pair = owner_case("o-fallback-absent", "container:fallback", fallback_pos,
                        owner_log("own-fallback-absent", container=(0, 0), container_rows="-",
                                  geo=geometry("-", visible="0.3,0.5")))
check("container fallback, the owner's top-level block 0.4 not visible (O8) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
# F-R7: container and caption captures are held to the fill limit. The
# candidate's panel band is 12 levels lighter (y 160-198): under the
# tolerant threshold, away from ink, a fill difference.
band_cand = container_page("panel-band", band_tint=(236, 253, 255))
check("panel band 12 levels lighter, undeclared pair -> PASS (fill is information only)",
      run("o-fill-undeclared", "tolerant", panel_ref, band_cand), 0, "PASS")
code, pair = owner_case("o-fill", "container:positive", container_pos, owner_log("own-fill"), cand=band_cand)
check("panel band 12 levels lighter, container positive -> FAIL (fill)", (code, pair["verdict"]), 1, "FAIL")
expect("... the note gives the fill's box", "fill 9880 px (8.2333%) > 0.01%, bbox 20,160,280,198" in notes_of(pair), True)
expect("... and the owner text crop still passes", owner_crops_of(pair), [("0.4.0", "PASS")])
code, pair = owner_case("o-fill-fallback", "container:fallback", fallback_pos, fallback_log, cand=band_cand)
check("panel band 12 levels lighter, container fallback -> FAIL (fill, whatever the class)",
      (code, pair["verdict"]), 1, "FAIL")
code, pair = owner_case("o-fill-same", "container:fallback", fallback_pos, fallback_log)
check("... the same fallback pair without the band -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... fill 0", pair.get("fill_px"), 0)
fill_b_log = owner_log("own-fill-b", renderer="swiftui", container=(0, 0), container_rows="-",
                       geo=geometry("-", visible="0.3,0.4"))
code, pair = owner_case("o-fill-b", "container:positive", container_pos, fill_b_log, engine="swiftui", cand=band_cand)
check("panel band 12 levels lighter on arm B (swiftui, tolerant) -> FAIL (fill)", (code, pair["verdict"]), 1, "FAIL")

code, pair = owner_case("o-fallback-land", "container:fallback", fallback_pos,
                        owner_log("own-fallback-land", container=(0, 0), container_rows="-", landed="0.2",
                                  geo=geometry("-", visible="0.3,0.4")))
check("container fallback on arm C, the jump went to another block -> INVALID", (code, pair["verdict"]), 1, "INVALID")

# The SwiftUI arm and the reference.
b_log = owner_log("own-b", renderer="swiftui", container=(0, 0), container_rows="-", geo=geometry("-", visible="0.3,0.4"))
code, pair = owner_case("o-b", "container:positive", container_pos, b_log, engine="swiftui", kind="exact")
check("arm B (swiftui) container capture with zero container counters -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... no owner crop on an exact pair", pair.get("owner_crops"), 0)
code, pair = owner_case("o-b-native", "container:positive", container_pos,
                        owner_log("own-b-native", renderer="swiftui", container=(1, 3), container_rows="0.4.0:3",
                                  geo=geometry("-", visible="0.3,0.4")), engine="swiftui", kind="exact")
check("arm B reporting TextKit 2 container rows -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... says so", "SwiftUI arm lists live TextKit 2 container rows (0.4.0)" in notes_of(pair), True)
code, pair = owner_case("o-b-row", "container:positive", container_pos,
                        owner_log("own-b-row", renderer="swiftui", container=(0, 0), container_rows="-"),
                        engine="swiftui", kind="exact")
check("arm B whose geometry lists a TextKit 2 row (G9) -> INVALID", (code, pair["verdict"]), 1, "INVALID")
code, pair = owner_case("o-a", "container:positive", container_pos, "-", engine="none", kind="noise")
check("reference build (engine none) on the noise pair -> PASS", (code, pair["verdict"]), 0, "PASS")
code, pair = owner_case("o-none", "container:positive", container_pos, "-", engine="none")
check("engine none on a tolerant pair -> INVALID (no engine proof)", (code, pair["verdict"]), 1, "INVALID")

# The same image described at 2x: the crop follows the geometry's scale.
code, pair = owner_case("o-2x", "container:positive", container_pos,
                        owner_log("own-2x", geo=geometry("0.4.0|root|18,48,132,70.5|18,48,132,70.5|-", scale=2,
                                                         screen=(150, 200), visible="0.3,0.4")))
check("2x geometry (150x200 pt) of the same image -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... the crop is in image pixels", (pair.get("owner_details") or [{}])[0].get("box"), "36,96,264,141")

# A nested list's continuation row (<item id>#cont<n>) is an owner like any other.
code, pair = owner_case("o-cont", "container:positive", "0.4.0#cont1=tk2;land=0.3",
                        owner_log("own-cont", container_rows="0.4.0#cont1:2",
                                  geo=geometry(ROW_040.replace("0.4.0|", "0.4.0#cont1|"), visible="0.3,0.4")))
check("a continuation row's owner id (0.4.0#cont1) -> PASS", (code, pair["verdict"]), 0, "PASS")

# Captions: their own keys and line.
caption_pos = "0.6.0=tk2;land=0.3"
caption_good = owner_log("cap-good", caption=(1, 2), caption_rows="0.6.0:2", container=(0, 0), container_rows="-",
                         geo=geometry(ROW_060, visible="0.3,0.4,0.5,0.6"))
code, pair = owner_case("c-same", "caption:positive", caption_pos, caption_good)
check("caption capture, identical, 0.6.0's row over the caption -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... read from the caption keys", pair.get("owner_proof", "").startswith(
    "caption: owner-level: tk2CaptionLive=1 tk2CaptionNativeDraws=2 rows 0.6.0:2"), True)
code, pair = owner_case("c-dx", "caption:positive", caption_pos, owner_log(
    "cap-dx", caption=(1, 2), caption_rows="0.6.0:2", geo=geometry(ROW_060, visible="0.3,0.4,0.5,0.6")),
    cand=container_page("panel-caption-1px-right", caption_dx=1))
check("caption 1 px right -> FAIL", (code, pair["verdict"]), 1, "FAIL")
code, pair = owner_case("c-container-keys", "caption:positive", caption_pos,
                        owner_log("cap-container-keys", caption=None, caption_rows=None, container_rows="0.6.0:2",
                                  geo=geometry(ROW_060, visible="0.3,0.4,0.5,0.6")))
check("a caption proved only by container keys -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... a build without the caption keys", "a build without the caption keys" in notes_of(pair), True)

# Two kinds on one pair: each proved on its own.
both_log = owner_log("own-both", caption=(1, 2), caption_rows="0.6.0:2",
                     geo=geometry(ROW_040 + ";" + ROW_060, visible="0.3,0.4,0.5,0.6"))
code, pair = run_pair("o-both", "tolerant", panel_ref, panel_cand,
                      *code_capture("o-both", "container:positive", container_pos, "textkit2", both_log),
                      *code_capture("o-both", "caption:positive", caption_pos, "textkit2", both_log))
check("container and caption declared on one pair, both proved -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... both classes and both crops", (pair.get("owner_class"), owner_crops_of(pair)),
       ("container:positive+caption:positive", [("0.4.0", "PASS"), ("0.6.0", "PASS")]))
code, pair = run_pair("o-both-bad", "tolerant", panel_ref, panel_cand,
                      *code_capture("o-both-bad", "container:positive", container_pos, "textkit2", both_log),
                      *code_capture("o-both-bad", "caption:positive", "0.6.1=tk2;land=0.3", "textkit2", both_log))
check("... and one kind's failing proof makes the pair INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... naming the kind", "caption engine proof: owner 0.6.1 has no live TextKit 2 caption row" in notes_of(pair), True)
# Code and container on one pair: each proof stands on its own.
def mixed_log(name: str, container_keys: bool) -> str:
    """proof_log's code capture plus a container owner 0.11.0 (the page text
    line at y 30-40) on screen, with (or without) the container keys."""
    path = proof_log(name, geo=geometry(ROW_012 + ";0.11.0|root|20,30,220,40|20,30,220,40|-"))
    lines_ = open(path, newline="").read().split("\r\n")
    landed_at = next(i for i, line in enumerate(lines_) if line.startswith("SCROLL_LANDED"))
    if container_keys:
        lines_[landed_at + 1] += " tk2ContainerLive=1 tk2ContainerNativeDraws=3 tk2CaptionLive=0 tk2CaptionNativeDraws=0"
    lines_.insert(landed_at + 3, "TK2_CONTAINER_ROWS live=1 owners=0.11.0:3")
    with open(path, "w", newline="") as handle:
        handle.write("\r\n".join(lines_))
    return path


mixed_owners = "0.11.0=tk2;land=0.10"
code, pair = run_pair("o-code-mixed", "tolerant", code_a, code_b,
                      *code_capture("o-code-mixed", "positive", positive, "textkit2", mixed_log("proof-mixed", True)),
                      *code_capture("o-code-mixed", "container:positive", mixed_owners, "textkit2",
                                    mixed_log("proof-mixed-2", True)))
check("a code and a container declaration on one pair, both proved -> PASS", (code, pair["verdict"]), 0, "PASS")
expect("... both classes, the code box and the owner crop",
       (pair.get("code_class"), pair.get("owner_class"), owners_of(pair), owner_crops_of(pair)),
       ("positive", "container:positive", ["tk2:0.12"], [("0.11.0", "PASS")]))
nokeys = mixed_log("proof-mixed-nokeys", False)
code, pair = run_pair("o-code-mixed-nokeys", "tolerant", code_a, code_b,
                      *code_capture("o-code-mixed-nokeys", "positive", positive, "textkit2", nokeys),
                      *code_capture("o-code-mixed-nokeys", "container:positive", mixed_owners, "textkit2", nokeys))
check("... the same from a build without the container keys -> INVALID", (code, pair["verdict"]), 1, "INVALID")
expect("... the code proof still passes on its own", pair.get("code_proof", "").startswith("owner-level"), True)
expect("... the container proof names the missing keys",
       "container engine proof: RENDERER_STATS has no tk2ContainerLive" in notes_of(pair), True)

# Coverage per kind.
code, scored = run_pairs(
    "o-coverage", [("noise", "ocov-AA", panel_ref, panel_cand), ("tolerant", "ocov-pos-AC", panel_ref, panel_cand),
                   ("tolerant", "ocov-fb-AC", panel_ref, panel_cand)],
    *code_capture("ocov-pos-AC", "container:positive", container_pos, "textkit2", container_good),
    *code_capture("ocov-fb-AC", "container:fallback", fallback_pos, "textkit2", fallback_log))
try:
    scores_json = json.load(open(os.path.join(work, "o-coverage", "scores.json")))
except (OSError, ValueError):
    scores_json = {}
expect("container coverage counts the positive capture only",
       (code, scores_json.get("owner_coverage", {}).get("container"), scores_json.get("code_coverage", {}).get("positive_pairs")),
       (0, {"positive_pairs": 1, "positive_pass": 1, "fallback_pairs": 1, "fallback_pass": 1}, 0))
expect("scores.json records the declarations by kind",
       scores_json.get("settings", {}).get("owner_captures", {}).get("ocov-pos-AC", {}).get("container", {}).get("class"),
       "positive")
try:
    coverage_md = open(os.path.join(work, "o-coverage", "summary.md")).read()
except OSError:
    coverage_md = ""
expect("summary.md has the owner columns and the container coverage line",
       ("| owner geometry |" in coverage_md, "Container coverage (candidate on TextKit 2): 1/1 positive" in coverage_md),
       (True, True))

# Usage errors.
check("an unknown kind -> usage error",
      run("o-usage-kind", "tolerant", panel_ref, panel_cand,
          *code_capture("o-usage-kind", "table:positive", container_pos, "textkit2", container_good)), 2, "(no scores.json)")
check("two container declarations for one pair -> usage error",
      run("o-usage-twice", "tolerant", panel_ref, panel_cand,
          *code_capture("o-usage-twice", "container:positive", container_pos, "textkit2", container_good),
          *code_capture("o-usage-twice", "container:fallback", fallback_pos, "textkit2", container_good)), 2, "(no scores.json)")
check("a container positive without a tk2 owner -> usage error",
      run("o-usage-positive", "tolerant", panel_ref, panel_cand,
          *code_capture("o-usage-positive", "container:positive", fallback_pos, "textkit2", container_good)),
      2, "(no scores.json)")
check("code: as an explicit kind is the code kind",
      run("o-usage-code", "tolerant", code_a, code_b,
          *code_capture("o-usage-code", "code:positive", positive, "textkit2", good_log)), 0, "PASS")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
