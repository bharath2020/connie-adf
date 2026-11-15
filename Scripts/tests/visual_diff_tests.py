#!/usr/bin/env python3
"""Positive and negative cases for Scripts/visual_diff.py on synthetic PNGs.

USAGE
    python3 -I Scripts/tests/visual_diff_tests.py <workdir>

Draws small grey "text" bars on a light background, runs the comparator on
each pair and checks the verdict and exit status; then code boxes (the
grey box, header strip and code lines of a code block) with the negative
controls of the code crops, of the engine proof and of the capture-time
geometry (CAPTURE_GEOMETRY: which TextKit 2 row drew a scored box, the
measured landing). Needs Pillow and numpy (as visual_diff.py does). Exits
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

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
