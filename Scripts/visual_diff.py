#!/usr/bin/env python3
"""Score screenshot pairs for visual parity (reference vs candidate).

USAGE
    python3 -I Scripts/visual_diff.py --out <dir>
        --pair <KIND> <NAME> <REF.png> <CAND.png> [--pair ...]
        [--mask x0,y0,x1,y1]... [--exact-mask x0,y0,x1,y1]...
        [--top-band 0] [--bottom-band 0]
        [--threshold 24] [--exact-threshold 0] [--search 100]
        [--max-noise-pct 0] [--max-exact-pct 0]
        [--max-raw-pct 0.5] [--max-crop-pct 0.5] [--max-offset-px 0]
        [--marker-gap 27] [--marker-max-width 180] [--max-position-px 0.5]
        [--list-pair NAME_PREFIX[:MIN_MARKERS]]...
        [--fill-threshold 6] [--fill-ink-radius 4] [--max-fill-pct 0.01]
        [--code-capture NAME [KIND:]CLASS OWNERS ENGINE LOG]...
        [--code-min-boxes 1] [--code-search 4]
        [--code-fill auto|R,G,B] [--code-fill-tolerance 1] [--pixel-scale 0]

    Driven by Scripts/visual-parity.sh; runs standalone on any two PNGs.
    Requires Pillow and numpy only. No image registration: a shifted block is
    reported as an offset, never aligned away.

PAIR KINDS
    noise     two captures of the same build (A–A'): establishes capture noise.
              Differing pixel = any channel |Δ| > --exact-threshold (default 0).
              PASS when viewport % <= --max-noise-pct (default 0).
    exact     reference vs a build that must be pixel-identical (A–B).
              Same pixel rule; PASS when viewport % <= --max-exact-pct
              (default 0).
    tolerant  reference vs the new renderer (A–C). Differing pixel = any
              channel |Δ| > --threshold (default 24; anti-aliasing ignored).
              PASS when viewport % <= --max-raw-pct (0.5) AND every crop
              <= --max-crop-pct (0.5) AND every crop |offset| <= --max-offset-px
              (0).
    For noise/exact the crop limit equals the viewport limit, and offsets are
    held to --max-offset-px too.

MASKS
    --mask x0,y0,x1,y1 (repeatable, device pixels, x1/y1 exclusive) and the
    convenience bands --top-band N / --bottom-band N (rows from the top /
    bottom edge) are excluded from every score: viewport %, crop detection,
    crop % and offset search (masked pixels are set to the background level in
    both images before the shift search).
    --exact-mask x0,y0,x1,y1 (repeatable) is excluded from noise and exact
    pairs only: chrome that legitimately differs at the 0 threshold but not
    at the tolerant one (e.g. the soft shadow a toolbar capsule of another
    width casts onto content) — tolerant pairs still score those pixels.

METRICS (per pair)
    viewport_pct     differing pixels / unmasked pixels × 100, at the kind's
                     pixel rule; viewport_px the count itself and diff_bbox
                     their bounding box (x0,y0,x1,y1, exclusive), so a diff
                     too small for the printed % is never shown as 0
    viewport_pct_aa  the same at --threshold (for information on every kind)
    crops            text blocks: rows holding ink (pixels far from the
                     dominant background grey) in the reference OR the
                     candidate, grouped into runs (gaps up to 4 rows), bounded
                     horizontally by the union ink columns. Using the union
                     means a block that exists in only one image is a crop too
                     (noted "missing in candidate" / "extra in candidate").
    per crop         pct (differing pixels in the crop box), offset (the
                     vertical shift in ±--search that best aligns the reference
                     rows with the candidate; minimum mean absolute grey
                     difference, nearest-to-zero wins ties), residual (that
                     minimum), verdict
    max_abs_offset   largest |offset| over the crops; last_offset = the last
                     crop's offset (cumulative drift shows up here)

MARKER AND CONTENT CROPS (every pair)
    A viewport or crop percentage can hide a marker that moved by a pixel (a
    bullet is ~300 px of a 100,000 px row crop). So every text crop whose
    first line starts with a narrow ink cluster (<= --marker-max-width px,
    default 180) followed by an ink-free gap >= --marker-gap px (default 27:
    the list row's 8 pt marker/content spacing at 3x plus side bearings;
    word spaces stay under it up to Dynamic Type step 3) is split into a
    marker crop and a content crop. Detection runs on the reference AND the
    candidate, so a marker present in only one image is a marker crop too.
    Per marker crop, measured in the same windows in both images:
      marker_dx/dy    shift of the marker's ink-weighted centroid
      content_dx/dy   shift of the content's first-line ink centroid
                      (first line = the content rows down to the first run
                      of >= 3 empty rows; dy is the first-baseline check)
      relative_dy     change of (marker cy - first-line cy): the marker's
                      position against the first baseline
      marker/content pct  differing pixels in each box at the kind's rule
    A marker crop PASSes when every |delta| <= --max-position-px (default
    0.5 px: sub-pixel, so anti-aliasing passes and a 1 px move fails) and
    both percentages are within the kind's crop limit; a marker with no ink
    in one image FAILs. Weights are ink above the ink threshold only, so a
    low-contrast row fill (a decision background) does not dilute them.

LIST PAIRS (--list-pair NAME_PREFIX[:MIN_MARKERS], repeatable)
    A pair whose name starts with a listed prefix is a list capture:
    - INVALID with fewer than MIN_MARKERS (default 1) marker crops: a list
      position that shows no markers did not land on its lists;
    - FAIL when its fill pixels exceed --max-fill-pct (default 0.01 %).
    Fill pixels: unmasked, outside every --exact-mask, farther than
    --fill-ink-radius px (default 4) from ink in either image, and differing
    by more than --fill-threshold (default 6) in any channel. That catches a
    missing or moved low-contrast fill (the decision row background is
    ~20 grey levels: below the tolerant threshold of 24) that the tolerant
    pixel rule cannot see. A pair with a container or caption declaration
    (CONTAINER AND CAPTION CAPTURES) is held to the same fill limit: a
    panel's tint, a quote's bar, an expand's frame and a column's gutter
    are low-contrast fills of the same kind. Other pairs report fill for
    information only. Markers and decision backgrounds are never masked by
    default.

CODE BOXES (every pair)
    A code block is a grey box: CodeBlockView fills a rounded rectangle with
    Color.gray.opacity(0.1), so its colour is the page background blended
    10 % toward system grey (142,142,147) - (244,244,244) on white,
    (14,14,15) on black (--code-fill overrides; +-1 per channel,
    --code-fill-tolerance). The page background is the commonest scorable
    colour, except on a viewport of mostly code (code-parity, code-dense),
    where the fill outnumbers the page: when the commonest colour is the
    code fill of a runner-up colour that fills a whole scorable row (the
    gap between two blocks), the runner-up is the page. A code box is
    found in the REFERENCE without any help from the app: a solid rectangle (no page-background pixel inside,
    at least 20 % of the image wide and 20 pt tall) of which at least half
    the pixels are that fill, whose first ink band is the header (ends
    within 40 pt of the top and reaches within 30 pt of the right edge: the
    Copy button is always there). Points are pixels / --pixel-scale (0 =
    round(width / 400): 3 on a 1206 px capture). Boxes are looked for
    outside every mask and every --exact-mask (in all pair kinds: the
    toolbar shadow band differs between renderer labels at threshold 0); a
    box cut by the top band is ignored, one cut by the bottom band is scored
    on what shows. A code block inside a panel sits on the panel's tint, has
    another fill and is not found.
    Per box, all in the reference's coordinates (the candidate is never
    registered, and a crop with no scorable pixel is INVALID, never 0 %):
      header strip   box top down to midway between the header ink and the
                     first code line (badge and Copy button);
      outline        2 pt outside the box edge and 8 pt (the corner radius)
                     inside it, except the inner right edge beside the code
                     lines (a long line is clipped there);
        both: ZERO pixels differing at channel threshold 0, in every pair
        kind. For exact and tolerant pairs the same regions of the noise
        pair with the same reference (A-A') are measured first: when they
        are not exactly stable the chrome rule is not evaluated and the
        pair is INVALID with the A-A' count - never loosened. Without
        that noise pair (or with an A' capture smaller than the
        reference) stability is not proven: the chrome rule is not
        evaluated either, and the pair is INVALID with its own chrome
        counts reported (box verdict UNMEASURED);
      geometry       the candidate must hold a code box at the same
                     rectangle (a moved, missing or extra box FAILs);
      code text      the union ink box below the header strip: differing
                     pixels <= the kind's crop limit (0.5 % for tolerant),
                     and per code line (ink row runs) a displacement of 0 px
                     in BOTH axes: the 2-D shift in +---code-search px that
                     best aligns the reference line with the candidate
                     (nearest to zero wins ties) must be (0, 0) within
                     --max-offset-px, and the line's ink centroid must move
                     <= --max-position-px in x and in y.
    A box without code ink (an empty code block) has no text crop and is
    accepted on geometry and chrome alone.

CODE CAPTURES (--code-capture NAME CLASS OWNERS ENGINE LOG, repeatable)
    Declares the pair NAME a code capture; nothing is inferred.
      CLASS    positive  the capture shows code TextKit 2 should draw
               fallback  every code block it names stays on SwiftUI
      OWNERS   <owner>=<tk2|swiftui>[,...];land=<block id>: the code
               owners (RenderBlock ids) the capture names and the engine
               each is expected on; positive needs a tk2 owner, fallback
               none. land= (required) is the block the position scrolls to.
      ENGINE   what the pair's candidate ran: textkit2 (arm C), swiftui
               (arm B) or none (the reference build, which prints nothing:
               valid only on a noise pair, A-A').
      LOG      the candidate's launch log (- with ENGINE none).
    A code capture is INVALID - not PASS - when
      - it has fewer than --code-min-boxes code boxes, or it is positive
        and no box has code ink in both images;
      - ENGINE is none on an exact or tolerant pair: a candidate run
        without -rendererStats has no engine proof and cannot PASS;
      - its engine proof fails. The proof is read from LOG after the line
        `SCROLL_LANDED ... block=<id>` (stats printed at READY predate the
        -scrollToFraction jump and prove nothing about the position): the
        block must be land= (the jump's target); the next `RENDERER_STATS`
        line must name ENGINE; textkit2 + positive needs tk2CodeLive > 0
        and tk2CodeDraws > 0, swiftui needs both 0; and the next
        `TK2_CODE_ROWS owners=<id>:<native draws>,...` line (- for none;
        always required) must list each tk2 owner with draws > 0 and no
        swiftui owner. That line says a row drew, not that it is on
        screen, so
      - its capture-time geometry fails. visual-parity.sh posts the app's
        capture-geometry hook right before and right after the screenshot;
        each post prints one line (Demo/ADFReader/RendererStats.swift):
          CAPTURE_GEOMETRY seq=<n> scale=<s> screen=<w>x<h> window=<rect>
              visibleRows=<id>[,...]|-|unavailable
              rows=<owner>|<root|list|code>|<frame>|<visible|->|<draws|->[;...]|-
        (points, rectangles x0,y0,x1,y1 in window coordinates; frame is
        where the row can draw, its bounds and canvas; visible is that
        frame clipped by the scroll views and the window; draws is the
        owner's native draws at that moment: always a number on a code
        row, a number on a root or list row whose owner is a live
        container or caption row, - otherwise or from a build before
        PR 4's review fixes). Points are
        converted to pixels at the line's scale: inner pixels (wholly
        inside, for containment) and outer pixels grown by 1 (every pixel
        it touches, for exclusion), so both errors fall on the strict
        side. Each scored code box is attributed on the candidate's code
        ink below its header strip: no TextKit 2 code row's frame over the
        box -> swiftui (the fallback Text and the TextKit 2 row are
        exclusive for one block); one row, shown, holding every code-ink
        pixel within 1 px of its visible frame -> tk2:<owner>; anything
        else (two rows, a hidden or clipped row, ink outside the row) ->
        mixed. The rules (G1-G9):
        G1 (B, C) seq=1 and seq=2 present after SCROLL_LANDED, well formed,
           no error=, no seq=3, equal (draws aside: the screen did not
           change across the screenshot); screen x scale equals the image
           size; the window is the whole screen;
        G2 (C) no box mixed;
        G3 (C, positive) every tk2 owner owns a box (tk2:<owner>) and its
           row has drawn natively (draws > 0 before the screenshot);
           otherwise the note says why: no row in the window, its row is
           clipped off screen, on screen but over no scored box, no draw;
        G4 (C) no box tk2:<owner> for an owner declared swiftui; for an
           undeclared owner INVALID on a fallback capture, information on
           a positive one (never coverage);
        G5 (C, fallback) every box with code ink is swiftui (G2 and G4);
        G6 (C) an owner declared swiftui has no row in the window at all;
        G7 (B, C) the landing is measured: visibleRows (the top-level rows
           the reader reports >= 95 % in the viewport) is available and
           holds land=, and no top-level block 0.<k> with k < land - 1
           (one short block of slack under the translucent bar); on C a
           TextKit 2 row of the land= block is shown below the top band;
        G8 (B, C, fallback) a named owner, or its top-level block for a
           nested id (0.30 for 0.30.0.1), is in visibleRows;
        G9 (B) no TextKit 2 row of any kind in the window.
      --require-owner-proof is accepted and changes nothing (always on).
    An expected-fallback capture never counts as native coverage, and a
    positive capture counts only when it PASSes (so with G3): the summary
    counts positive and fallback captures apart.

CONTAINER AND CAPTION CAPTURES (--code-capture NAME KIND:CLASS ..., PR 4)
    CLASS may carry a kind: code (the default, CODE CAPTURES above),
    container or caption (container:positive, caption:fallback). A pair
    holds at most one declaration per kind; each kind is proved on its
    own and any failing proof makes the pair INVALID. OWNERS, ENGINE and
    LOG are as for code; an owner is the text leaf's owner id: a block id
    inside a container, a nested list row's PreparedListRow id, or a
    caption's PreparedMedia id.
    Engine proof, read after SCROLL_LANDED as for code, with the kind's
    keys: container tk2ContainerLive, tk2ContainerNativeDraws and the line
    `TK2_CONTAINER_ROWS live=<n> owners=<id>:<native draws>,...|-` (live
    rows of context container whose owner kind is not code); caption
    tk2CaptionLive, tk2CaptionNativeDraws and `TK2_CAPTION_ROWS ...`. The
    rules are the code proof's: positive needs both counters > 0, every
    tk2 owner listed with draws > 0 (a TextKit 1-backed, linked row has 0
    native draws: never proof) and no swiftui owner listed; the SwiftUI
    arm needs both 0 and no owner listed.
    Capture-time geometry, from the same CAPTURE_GEOMETRY bracket (G1 and
    the landing G7 as for code; G9 on arm B):
      O3 (C, positive) every tk2 owner has a TextKit 2 row in the window
         that is not a code row (owner kind root or list: the container
         proof counts no code row) and is shown, with candidate ink inside
         its on-screen frame (inner pixels, scorable); and the bracket
         reports each shown row's draws as a number > 0 before the
         screenshot (G3's draw check: the TK2_*_ROWS line is read at the
         landing, and a row remade since then has drawn nothing yet). A
         live tk2 owner's row always reports a number, so draws - is
         INVALID: a reporter regression cannot switch the check off
         (review D-R8);
      O4 (C) an on-screen row of an owner the kind's line lists but the
         declaration does not name: INVALID on a fallback capture,
         information on a positive one (never coverage);
      O6 (C) an owner declared swiftui has no TextKit 2 row in the window;
      O8 (B, C, fallback) a named owner's top-level block is in visibleRows.
    Owner text crops (A-C pairs whose candidate ran textkit2): one per
    shown row of each tk2 owner, over every pixel of its on-screen frame
    (outer pixels, clamped to the image), scored like a code box's code
    text: differing pixels within the kind's crop limit, and per line
    (ink row runs) a 2-D displacement of 0 px within --max-offset-px
    (search +---code-search px) and an ink centroid move <= --max-position-px
    in x and in y. Ink in one image only FAILs ("missing in candidate",
    "extra in candidate"); a frame with no scorable pixel or no ink in
    either image is INVALID. A positive capture on arm C without an owner
    text crop holding ink in both images is INVALID. Noise and exact pairs
    have no owner crop: their whole viewport is held to the exact rule.
    Fill: the pair is held to --max-fill-pct as a list pair is (LIST
    PAIRS), whatever its kind and class.
    Coverage is counted per kind as for code (a fallback capture never
    counts).

EMPTY CONTENT
    A pair with zero text crops (no ink in either unmasked viewport) is
    INVALID: two blank captures prove nothing about text rendering. Pass
    --allow-empty only for pairs that are meant to be blank.

OUTPUTS (in --out)
    <name>.sbs.png          reference | candidate | difference map
    crops/<name>-cNN.png    each failing crop: reference | candidate | diff
    crops/<name>-mNN.png    each failing marker crop (marker + content)
    crops/<name>-kNN.png    each failing code box
    crops/<name>-oNN.png    each failing container or caption owner text crop
    scores.csv              one row per pair
    scores.json             every pair with its crops
    summary.md              pair table + failing-crop table

EXIT STATUS  0 every pair PASS, 1 any pair FAIL or INVALID, 2 usage/input
    error (unreadable or missing image, bad mask, bands covering the image).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

KINDS = ("noise", "exact", "tolerant")


class InputError(Exception):
    pass


@dataclass
class Crop:
    index: int
    y0: int
    y1: int
    x0: int
    x1: int
    pct: float
    offset: int
    residual: float
    ref_ink: bool
    cand_ink: bool
    verdict: str
    notes: str = ""


@dataclass
class MarkerCrop:
    index: int
    block: int
    y0: int
    y1: int
    marker_box: str
    content_box: str
    detected_in: str
    marker_dx: float
    marker_dy: float
    content_dx: float
    content_dy: float
    relative_dy: float
    marker_pct: float
    content_pct: float
    verdict: str
    notes: str = ""


@dataclass
class CodeCrop:
    """One code box, in reference coordinates (boxes are x0,y0,x1,y1)."""
    index: int
    box: str
    clipped: str            # "" or "bottom" (cut by the bottom band)
    geometry: str           # "same" | "moved <d>" | "missing in candidate"
    header_box: str
    header_px: int          # differing pixels at channel threshold 0
    outline_px: int
    stable_header_px: int   # the same regions in A-A' (-1: not measured)
    stable_outline_px: int
    text_box: str           # "" when the box shows no code ink
    text_pct: float
    lines: int
    dx: int                 # worst code line's shift (candidate right = +)
    dy: int                 # ... (candidate lower = +)
    centroid_dx: float
    centroid_dy: float
    ref_ink: bool
    cand_ink: bool
    verdict: str            # PASS | FAIL | UNSTABLE | UNMEASURED | INVALID
    notes: str = ""
    owner: str = ""         # capture-time attribution: swiftui | tk2:<owner> | mixed | covered:<owners> | ""
    owner_px: int = 0       # candidate code-ink pixels inside that owner's visible frame


@dataclass
class OwnerCrop:
    """One container or caption owner's text crop, over its TextKit 2 row's
    on-screen frame in the candidate's capture-time geometry (boxes are
    x0,y0,x1,y1 image pixels)."""
    index: int
    kind: str               # "container" | "caption"
    owner: str
    box: str                # the row's on-screen frame, outer pixels clamped to the image
    text_box: str           # union ink box inside it ("" when neither image has ink there)
    text_pct: float
    lines: int
    dx: int                 # worst line's shift (candidate right = +)
    dy: int                 # ... (candidate lower = +)
    centroid_dx: float
    centroid_dy: float
    ref_ink: bool
    cand_ink: bool
    owner_px: int           # candidate ink pixels inside the frame (inner pixels)
    verdict: str            # PASS | FAIL | INVALID
    notes: str = ""


@dataclass
class CodeRule:
    """A --code-capture declaration for one pair."""
    cls: str                # "positive" | "fallback"
    owners: list[tuple[str, str]]   # (owner id, "tk2" | "swiftui")
    land: str               # expected landing block id (required)
    engine: str             # "textkit2" | "swiftui" | "none"
    log: str
    kind: str = "code"      # "code" | "container" | "caption"

    @property
    def label(self) -> str:
        """The class with its kind, as declared (code has no prefix)."""
        return self.cls if self.kind == "code" else f"{self.kind}:{self.cls}"


@dataclass
class Score:
    kind: str
    name: str
    ref: str
    cand: str
    size_match: bool
    width: int
    height: int
    masked_pct: float
    viewport_pct: float
    viewport_pct_aa: float
    viewport_px: int
    viewport_px_aa: int
    diff_bbox: str
    crops: int
    failing_crops: int
    max_crop_pct: float
    max_abs_offset: int
    last_offset: int
    max_residual: float
    verdict: str
    notes: str
    marker_crops: int = 0
    failing_marker_crops: int = 0
    max_position_delta: float = 0.0
    fill_px: int = 0
    fill_pct: float = 0.0
    fill_bbox: str = ""
    list_pair: bool = False
    code_boxes: int = 0
    failing_code_boxes: int = 0
    code_text_crops: int = 0
    max_code_shift: int = 0
    chrome_px: int = 0
    code_class: str = ""
    code_proof: str = ""
    code_geometry: str = ""
    owner_class: str = ""          # container and caption declarations: "container:positive[+caption:...]"
    owner_proof: str = ""
    owner_geometry: str = ""
    owner_crops: int = 0
    failing_owner_crops: int = 0
    crop_details: list[Crop] = field(default_factory=list)
    marker_details: list[MarkerCrop] = field(default_factory=list)
    code_details: list[CodeCrop] = field(default_factory=list)
    owner_details: list[OwnerCrop] = field(default_factory=list)


def load_rgb(path: str) -> np.ndarray:
    if not Path(path).is_file():
        raise InputError(f"missing image: {path}")
    try:
        with Image.open(path) as image:
            return np.asarray(image.convert("RGB"))
    except Exception as error:  # Pillow raises several types for bad files
        raise InputError(f"unreadable image {path}: {error}") from error


def parse_mask(text: str) -> tuple[int, int, int, int]:
    try:
        x0, y0, x1, y1 = (int(v) for v in text.split(","))
    except ValueError as error:
        raise InputError(f"bad --mask '{text}' (want x0,y0,x1,y1 integers)") from error
    if x1 <= x0 or y1 <= y0:
        raise InputError(f"empty --mask '{text}' (x1 > x0 and y1 > y0 required)")
    return x0, y0, x1, y1


def build_mask(height: int, width: int, rects: list[tuple[int, int, int, int]], top: int, bottom: int) -> np.ndarray:
    """True where a pixel is EXCLUDED from scoring."""
    masked = np.zeros((height, width), dtype=bool)
    if top > 0:
        masked[: min(top, height)] = True
    if bottom > 0:
        masked[max(height - bottom, 0):] = True
    for x0, y0, x1, y1 in rects:
        masked[max(y0, 0): max(min(y1, height), 0), max(x0, 0): max(min(x1, width), 0)] = True
    if masked.all():
        raise InputError(f"masks cover the whole {width}x{height} image")
    return masked


def to_gray(rgb: np.ndarray) -> np.ndarray:
    return rgb.astype(np.float32) @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def diff_mask(a: np.ndarray, b: np.ndarray, threshold: int) -> np.ndarray:
    delta = np.abs(a.astype(np.int16) - b.astype(np.int16)).max(axis=2)
    return delta > threshold


def background_level(gray: np.ndarray, valid: np.ndarray) -> int:
    values = np.clip(gray[valid], 0, 255).astype(np.uint8)
    return int(np.bincount(values, minlength=256).argmax())


def ink_mask(gray: np.ndarray, background: int, valid: np.ndarray, ink_threshold: float = 40.0) -> np.ndarray:
    """Pixels far from the dominant (background) grey level — works for light
    and dark appearance alike."""
    return (np.abs(gray - background) > ink_threshold) & valid


def segment_rows(ink: np.ndarray, min_rows: int = 3, max_gap: int = 4, min_ink: int = 2) -> list[tuple[int, int]]:
    """Group rows that contain ink into [start, end) blocks."""
    rows = ink.sum(axis=1) >= min_ink
    blocks: list[tuple[int, int]] = []
    start = end = -1
    gap = 0
    for y, has_ink in enumerate(rows):
        if has_ink:
            if start < 0:
                start = y
            end = y
            gap = 0
        elif start >= 0:
            gap += 1
            if gap > max_gap:
                if end - start + 1 >= min_rows:
                    blocks.append((start, end + 1))
                start = -1
    if start >= 0 and end - start + 1 >= min_rows:
        blocks.append((start, end + 1))
    return blocks


def best_shift(ref_gray: np.ndarray, cand_gray: np.ndarray, y0: int, y1: int, search: int) -> tuple[int, float]:
    """The vertical shift in ±search that best aligns ref rows [y0, y1) with
    the candidate; ties go to the shift nearest zero."""
    band = ref_gray[y0:y1]
    height = cand_gray.shape[0]
    best_s, best_mad = 0, float("inf")
    for s in sorted(range(-search, search + 1), key=lambda v: (abs(v), v)):
        c0, c1 = y0 + s, y1 + s
        if c0 < 0 or c1 > height:
            continue
        mad = float(np.abs(band - cand_gray[c0:c1]).mean())
        if mad < best_mad:
            best_s, best_mad = s, mad
    return best_s, best_mad


def dilate(mask: np.ndarray, radius: int) -> np.ndarray:
    """Square dilation by `radius` px (separable; edges do not wrap)."""
    if radius <= 0:
        return mask.copy()
    height, width = mask.shape
    padded = np.pad(mask, radius)
    rows = np.zeros((height + 2 * radius, width), dtype=bool)
    for dx in range(2 * radius + 1):
        rows |= padded[:, dx: dx + width]
    out = np.zeros((height, width), dtype=bool)
    for dy in range(2 * radius + 1):
        out |= rows[dy: dy + height]
    return out


def first_line(ink: np.ndarray, empty_rows: int = 3) -> tuple[int, int] | None:
    """[start, end) of the first run of ink rows in `ink`, ended by
    `empty_rows` consecutive empty rows (or the end)."""
    rows = np.flatnonzero(ink.any(axis=1))
    if rows.size == 0:
        return None
    start = end = int(rows[0])
    for y in rows[1:]:
        if y - end > empty_rows:
            break
        end = int(y)
    return start, end + 1


def split_marker(ink: np.ndarray, gap: int, max_width: int) -> tuple[int, int, int] | None:
    """For one crop's ink (rows × cols, crop-relative), the (marker x0, marker
    x1, content x0) of its first line when it starts with a narrow cluster
    followed by an ink-free gap >= `gap`; otherwise None."""
    line = first_line(ink)
    if line is None:
        return None
    cols = np.flatnonzero(ink[line[0]: line[1]].any(axis=0))
    if cols.size < 2:
        return None
    breaks = np.flatnonzero(np.diff(cols) > gap)
    if breaks.size == 0:
        return None
    marker_end = int(cols[breaks[0]]) + 1
    content_start = int(cols[breaks[0] + 1])
    if marker_end - int(cols[0]) > max_width:
        return None
    return int(cols[0]), marker_end, content_start


def ink_centroid(weight: np.ndarray, y0: int, y1: int, x0: int, x1: int) -> tuple[float, float] | None:
    """Ink-weighted centroid (x, y) in absolute pixels of a window, or None
    when the window holds no ink."""
    window = weight[y0:y1, x0:x1]
    total = float(window.sum())
    if total <= 0:
        return None
    ys, xs = np.mgrid[y0:y1, x0:x1]
    return float((xs * window).sum() / total), float((ys * window).sum() / total)


# ------------------------------------------------------------ code boxes ----
# Geometry constants are in points (pixels / the capture's scale) and come
# from CodeBlockView and ADFTheme's defaults; the measured values are from
# iPhone 17 Pro captures (3x) of PR 2's final run.

SYSTEM_GRAY = (142, 142, 147)   # SwiftUI Color.gray, light and dark
CODE_FILL_ALPHA = 0.1           # CodeBlockView: Color.gray.opacity(0.1)
CHROME_THRESHOLD = 0            # header strip and outline: any channel |Δ| > 0 ...
MAX_CHROME_PX = 0               # ... and not one such pixel. Not options: never loosened.
CODE_MIN_WIDTH_FRACTION = 0.2   # of the image width
CODE_MIN_HEIGHT_PT = 20         # an empty code block is ~48 pt tall
CODE_MIN_FILL = 0.5             # share of fill pixels: code boxes 0.91-0.98, panels and chips 0.00
CODE_CORNER_SLACK_PT = 14       # corner rows are inset by up to the 8 pt radius
CODE_HEADER_MAX_PT = 40         # header ink ends ~24 pt below the top (~30 pt at +3 size steps)
CODE_COPY_INSET_MAX_PT = 30     # the Copy icon ends ~13 pt from the right edge
CODE_OUTLINE_OUTER_PT = 2       # blocks are 8 pt apart: stays clear of the neighbours
CODE_OUTLINE_INNER_PT = 8       # the corner radius; the padding inside the box is 8-12 pt
CODE_LINE_GAP = 2               # ink-free rows that end a code line (lines sit >= 5 pt apart)
CODE_PAGE_CANDIDATES = 4        # runner-up colours tried as the page when the fill is the commonest colour


def ranked_rgb(rgb: np.ndarray, valid: np.ndarray, count: int) -> list[tuple[int, int, int]]:
    """The `count` most common colours among the valid pixels, commonest
    first (every 5th pixel is counted)."""
    px = rgb[valid][::5].astype(np.uint32)
    keys = (px[:, 0] << 16) | (px[:, 1] << 8) | px[:, 2]
    values, counts = np.unique(keys, return_counts=True)
    order = np.argsort(-counts, kind="stable")[:count]
    return [(int(k) >> 16, (int(k) >> 8) & 255, int(k) & 255) for k in values[order]]


def code_fill_of(page: tuple[int, int, int], fill_override: tuple[int, int, int] | None) -> tuple[int, int, int]:
    """The code-box fill on a page colour: the page blended CODE_FILL_ALPHA
    toward system grey, unless --code-fill gives it."""
    return fill_override or tuple(int(round(b + CODE_FILL_ALPHA * (g - b))) for b, g in zip(page, SYSTEM_GRAY))


def page_background(rgb: np.ndarray, scorable: np.ndarray, fill_override: tuple[int, int, int] | None,
                    tolerance: int) -> tuple[int, int, int]:
    """The page colour the code boxes sit on: the most common scorable
    colour, unless that colour is the code fill of a runner-up colour that
    fills at least one whole scorable row - then the runner-up. A viewport
    of mostly code shows more fill than page (code-parity and code-dense:
    70-80 % fill, 13-25 % page), and the fill taken for the page hides
    every box. A whole row of one colour is the gap between two blocks,
    which no code box crosses; the fill alone never fills a row unless a
    full-width box does, and then it is not the runner-up's fill."""
    ranked = ranked_rgb(rgb, scorable, CODE_PAGE_CANDIDATES + 1)
    dominant = ranked[0]
    scored_rows = scorable.any(axis=1)
    for colour in ranked[1:]:
        fill = code_fill_of(colour, fill_override)
        if max(abs(f - d) for f, d in zip(fill, dominant)) > tolerance:
            continue   # the commonest colour is not this colour's code fill
        if max(abs(f - c) for f, c in zip(fill, colour)) <= tolerance:
            continue   # no fill depth on this colour
        near = np.abs(rgb.astype(np.int16) - np.array(colour, dtype=np.int16)).max(axis=2) <= tolerance
        if ((near | ~scorable).all(axis=1) & scored_rows).any():
            return colour
    return dominant


def true_runs(row: np.ndarray, min_length: int) -> list[tuple[int, int]]:
    """[start, end) runs of True at least `min_length` long in a 1-D mask."""
    padded = np.concatenate(([False], row, [False]))
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    return [(int(s), int(e)) for s, e in zip(edges[::2], edges[1::2]) if e - s >= min_length]


def find_fill_boxes(rgb: np.ndarray, scorable: np.ndarray, fill_override: tuple[int, int, int] | None,
                    tolerance: int, scale: int) -> list[tuple[int, int, int, int]]:
    """Rectangles (x0, y0, x1, y1) filled with the code-box colour: solid
    (no page-background pixel in a row of the box), at least the minimum
    size, and mostly the fill colour. Sorted top to bottom."""
    height, width = scorable.shape
    if not scorable.any():
        return []
    background = page_background(rgb, scorable, fill_override, tolerance)
    fill = code_fill_of(background, fill_override)
    depth = max(abs(f - b) for f, b in zip(fill, background))
    if depth <= tolerance:
        return []
    work = rgb.astype(np.int16)
    solid = (np.abs(work - np.array(background, dtype=np.int16)).max(axis=2) >= depth - tolerance) & scorable
    is_fill = (np.abs(work - np.array(fill, dtype=np.int16)).max(axis=2) <= tolerance) & scorable
    min_width = max(int(width * CODE_MIN_WIDTH_FRACTION), 1)
    slack = CODE_CORNER_SLACK_PT * scale
    open_boxes: list[list[int]] = []   # [x0, y0, x1, y1], growing downwards
    closed: list[list[int]] = []
    previous = -2
    for y in np.flatnonzero(solid.sum(axis=1) >= min_width):
        y = int(y)
        if y != previous + 1:
            closed += open_boxes
            open_boxes = []
        previous = y
        row_runs = true_runs(solid[y], min_width)
        taken = [False] * len(row_runs)
        still_open = []
        for box in open_boxes:
            match = next((i for i, (s, e) in enumerate(row_runs)
                          if not taken[i] and abs(s - box[0]) <= slack and abs(e - box[2]) <= slack), None)
            if match is None:
                closed.append(box)
                continue
            taken[match] = True
            start, end = row_runs[match]
            box[0], box[2], box[3] = min(box[0], start), max(box[2], end), y + 1
            still_open.append(box)
        still_open += [[s, y, e, y + 1] for i, (s, e) in enumerate(row_runs) if not taken[i]]
        open_boxes = still_open
    closed += open_boxes
    boxes = [(x0, y0, x1, y1) for x0, y0, x1, y1 in closed
             if y1 - y0 >= CODE_MIN_HEIGHT_PT * scale and float(is_fill[y0:y1, x0:x1].mean()) >= CODE_MIN_FILL]
    return sorted(boxes, key=lambda b: (b[1], b[0]))


def code_box_split(ink: np.ndarray, box: tuple[int, int, int, int], scale: int) -> int | None:
    """For a fill box that is a code block - its first ink band is the header
    (badge and Copy button) - the row that separates the header strip from
    the code text; None for any other fill box (a media placeholder)."""
    x0, y0, x1, y1 = box
    bands = segment_rows(ink[y0:y1, x0:x1], max_gap=CODE_LINE_GAP)
    if not bands:
        return None
    top, bottom = bands[0]
    if bottom > CODE_HEADER_MAX_PT * scale:
        return None
    cols = np.flatnonzero(ink[y0 + top: y0 + bottom, x0:x1].any(axis=0))
    if (x1 - x0) - 1 - int(cols[-1]) > CODE_COPY_INSET_MAX_PT * scale:
        return None
    if len(bands) > 1:
        return y0 + (bottom + bands[1][0]) // 2
    return y0 + min(y1 - y0, bottom + top)   # no code ink: as much padding below the header ink as above


def outline_mask(shape: tuple[int, int], box: tuple[int, int, int, int], split: int, outer: int, inner: int,
                 open_bottom: bool) -> tuple[tuple[int, int, int, int], np.ndarray]:
    """The box outline as (window x0, y0, x1, y1; mask over that window):
    `outer` px outside the edge and `inner` px inside it, without the inner
    right edge beside the code lines (a long line is clipped there). With
    `open_bottom` (the box runs under the bottom band) the lower edge is not
    part of it."""
    height, width = shape
    x0, y0, x1, y1 = box
    wx0, wy0 = max(x0 - outer, 0), max(y0 - outer, 0)
    wx1, wy1 = min(x1 + outer, width), min(y1 if open_bottom else y1 + outer, height)
    ring = np.ones((wy1 - wy0, wx1 - wx0), dtype=bool)
    hole_bottom = y1 if open_bottom else y1 - inner

    def clear(ry0: int, ry1: int, rx0: int, rx1: int) -> None:
        if ry1 > ry0 and rx1 > rx0:
            ring[ry0 - wy0: ry1 - wy0, rx0 - wx0: rx1 - wx0] = False

    clear(y0 + inner, hole_bottom, x0 + inner, x1 - inner)
    clear(max(split, y0 + inner), hole_bottom, max(x1 - inner, x0), x1)
    return (wx0, wy0, wx1, wy1), ring


def best_shift_2d(ref_gray: np.ndarray, cand_gray: np.ndarray, y0: int, y1: int, x0: int, x1: int,
                  search: int) -> tuple[int, int, float]:
    """(dx, dy, residual): the shift in ±search px, in both axes, that best
    aligns the reference window with the candidate (minimum mean absolute
    grey difference; nearest to zero wins ties). dx > 0: the candidate's
    content sits further right; dy > 0: lower."""
    band = ref_gray[y0:y1, x0:x1]
    height, width = cand_gray.shape
    best = (0, 0, float(np.abs(band - cand_gray[y0:y1, x0:x1]).mean()))
    if best[2] == 0.0:
        return best
    shifts = [(dx, dy) for dy in range(-search, search + 1) for dx in range(-search, search + 1) if dx or dy]
    for dx, dy in sorted(shifts, key=lambda s: (abs(s[0]) + abs(s[1]), abs(s[1]), s)):
        if y0 + dy < 0 or y1 + dy > height or x0 + dx < 0 or x1 + dx > width:
            continue
        mad = float(np.abs(band - cand_gray[y0 + dy: y1 + dy, x0 + dx: x1 + dx]).mean())
        if mad < best[2]:
            best = (dx, dy, mad)
    return best


def box_text(box: tuple[int, int, int, int]) -> str:
    return ",".join(str(v) for v in box)


# ------------------------------------------------------- code engine proof ---

def log_lines(path: str) -> list[str] | None:
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return None
    return [line.strip("\r") for line in text.splitlines()]   # a PTY log has \r\n


def marker_index(lines: list[str], marker: str, start: int = 0) -> int:
    """Index of the first line at or after `start` that is `marker` or starts
    with `marker` + space; -1 when there is none."""
    for index in range(start, len(lines)):
        if lines[index] == marker or lines[index].startswith(marker + " "):
            return index
    return -1


def key_values(line: str) -> dict[str, str]:
    out = {}
    for token in line.split()[1:]:
        key, sep, value = token.partition("=")
        if sep:
            out[key] = value
    return out


def parse_code_rows(value: str | None) -> dict[str, int] | None:
    """`owners=` of a TK2_CODE_ROWS line: <owner>:<native draws>[,...] or -
    (no live TextKit 2 code row). None when malformed."""
    if value is None or value == "":
        return None
    if value == "-":
        return {}
    rows = {}
    for item in value.split(","):
        owner, sep, draws = item.rpartition(":")
        if not sep or not owner or not draws.isdigit():
            return None
        rows[owner] = int(draws)
    return rows


def read_proof_log(rule: CodeRule) -> tuple[list[str] | None, int, list[str]]:
    """(lines, index of the SCROLL_LANDED line, problems) of a code
    capture's candidate launch log, read once for the engine proof and the
    capture-time geometry."""
    lines = log_lines(rule.log)
    if lines is None:
        return None, -1, [f"launch log unreadable: {rule.log}"]
    landed_at = marker_index(lines, "SCROLL_LANDED")
    if landed_at < 0:
        return lines, -1, ["no SCROLL_LANDED line (stats printed at READY predate the -scrollToFraction jump)"]
    return lines, landed_at, []


# Per capture kind: the RENDERER_STATS live-row and native-draw keys and the
# per-owner line the engine proof reads after SCROLL_LANDED. The container
# and caption names are PR 4's (plan §6.4): the app prints them from its
# step 2 on; a build without them fails the proof ("a build without the
# container keys").
CAPTURE_KINDS = ("code", "container", "caption")
PROOF_KEYS = {
    "code": ("tk2CodeLive", "tk2CodeDraws", "TK2_CODE_ROWS"),
    "container": ("tk2ContainerLive", "tk2ContainerNativeDraws", "TK2_CONTAINER_ROWS"),
    "caption": ("tk2CaptionLive", "tk2CaptionNativeDraws", "TK2_CAPTION_ROWS"),
}


def kind_rows(rule: CodeRule, lines: list[str], landed_at: int) -> dict[str, int] | None:
    """The owners of the rule's kind's per-owner line after SCROLL_LANDED
    (owner -> native draws); None when the line is absent or malformed."""
    rows_at = marker_index(lines, PROOF_KEYS[rule.kind][2], landed_at + 1)
    return None if rows_at < 0 else parse_code_rows(key_values(lines[rows_at]).get("owners"))


def evaluate_code_proof(rule: CodeRule, lines: list[str], landed_at: int) -> tuple[list[str], str]:
    """(problems, summary) of a capture's engine proof, read from the
    candidate's launch log after the SCROLL_LANDED line (`landed_at`), with
    the keys of the rule's kind (PROOF_KEYS). The per-owner line
    (TK2_CODE_ROWS for code) is required: totals cannot say which block
    drew."""
    live_key, draws_key, rows_marker = PROOF_KEYS[rule.kind]
    noun = rule.kind
    problems = []
    landed = key_values(lines[landed_at])
    if landed.get("block") != rule.land:
        problems.append(f"landed on block {landed.get('block', '?')}, declared {rule.land}")
    stats_at = marker_index(lines, "RENDERER_STATS", landed_at + 1)
    if stats_at < 0:
        return problems + ["no RENDERER_STATS line after SCROLL_LANDED"], "absent"
    stats = key_values(lines[stats_at])
    if stats.get("renderer") != rule.engine:
        problems.append(f"renderer={stats.get('renderer', '?')}, expected {rule.engine}")
    counters = {key: int(stats[key]) for key in (live_key, draws_key) if stats.get(key, "").isdigit()}
    if len(counters) < 2:
        return problems + [f"RENDERER_STATS has no {live_key} / {draws_key} (a build without the {noun} keys)"], "absent"
    live, draws = counters[live_key], counters[draws_key]
    rows_at = marker_index(lines, rows_marker, landed_at + 1)
    if rows_at < 0:
        return problems + [f"no {rows_marker} line after SCROLL_LANDED (the owner-level proof is required)"], "absent"
    rows = parse_code_rows(key_values(lines[rows_at]).get("owners"))
    if rows is None:
        return problems + [f"malformed {rows_marker} line: '{lines[rows_at]}'"], "absent"
    summary = f"owner-level: {live_key}={live} {draws_key}={draws}"
    if rows:
        summary += " rows " + ",".join(f"{owner}:{count}" for owner, count in sorted(rows.items()))

    if rule.engine == "swiftui":
        if live or draws:
            problems.append(f"SwiftUI arm reports {live_key}={live} {draws_key}={draws} (want 0 and 0)")
        if rows:
            problems.append(f"SwiftUI arm lists live TextKit 2 {noun} rows ({','.join(sorted(rows))})")
        return problems, summary

    if rule.cls == "positive" and (live <= 0 or draws <= 0):
        problems.append(f"declared positive, but {live_key}={live} {draws_key}={draws}: no TextKit 2 {noun} row drew")
    for owner, engine in rule.owners:
        if engine == "tk2" and owner not in rows:
            problems.append(f"owner {owner} has no live TextKit 2 {noun} row (declared tk2)")
        elif engine == "tk2" and rows[owner] <= 0:
            problems.append(f"owner {owner} is a live TextKit 2 {noun} row with no native draw")
        elif engine == "swiftui" and owner in rows:
            problems.append(f"owner {owner} is drawn by TextKit 2 (declared swiftui)")
    return problems, summary


# ---- capture-time geometry (docstring "CODE CAPTURES", G1-G9) ----------------

Rect = tuple[float, float, float, float]
GEOMETRY_KINDS = ("root", "list", "code")
GEOMETRY_SLACK_PX = 0.01   # 4-decimal points times 3 can land 0.0003 px off an integer
WINDOW_SLACK_PT = 0.01


@dataclass
class GeometryRow:
    """One TextKit 2 row of a CAPTURE_GEOMETRY line (points, window coordinates)."""
    owner: str
    kind: str               # root | list | code
    frame: Rect             # where the row can draw: its bounds and canvas
    visible: Rect | None    # frame clipped by its scroll views and the window; None: not shown
    draws: int | None       # native draws: code rows always, root/list rows when reported (else None)


@dataclass
class CaptureGeometry:
    seq: int
    scale: float
    screen: tuple[float, float]
    window: Rect
    visible_rows: list[str] | None   # None: "unavailable" (no visibility feed before iOS 18)
    rows: list[GeometryRow]

    def stable_key(self) -> tuple:
        """What must not change across the screenshot (draws may)."""
        return (self.scale, self.screen, self.window, tuple(self.visible_rows or ()), self.visible_rows is None,
                tuple((r.owner, r.kind, r.frame, r.visible) for r in self.rows))


def parse_rect(text: str) -> Rect | None:
    try:
        x0, y0, x1, y1 = (float(v) for v in text.split(","))
    except ValueError:
        return None
    return (x0, y0, x1, y1) if x1 >= x0 and y1 >= y0 else None


def parse_geometry(line: str) -> CaptureGeometry | str:
    """A CAPTURE_GEOMETRY line, or why it is malformed (a str)."""
    values = key_values(line)
    if "error" in values:
        return f"error={values['error']}"
    seq, scale = values.get("seq", ""), values.get("scale", "")
    if not seq.isdigit():
        return f"bad seq '{seq}'"
    try:
        scale_value = float(scale)
        width, _, height = values.get("screen", "").partition("x")
        screen = (float(width), float(height))
    except ValueError:
        return f"bad scale '{scale}' or screen '{values.get('screen', '')}'"
    if scale_value <= 0 or screen[0] <= 0 or screen[1] <= 0:
        return f"bad scale '{scale}' or screen '{values.get('screen', '')}'"
    window = parse_rect(values.get("window", ""))
    if window is None:
        return f"bad window '{values.get('window', '')}'"
    visible_text = values.get("visibleRows")
    if not visible_text:
        return "no visibleRows="
    visible_rows = None if visible_text == "unavailable" else [] if visible_text == "-" else visible_text.split(",")
    rows_text = values.get("rows")
    if not rows_text:
        return "no rows="
    rows: list[GeometryRow] = []
    for item in [] if rows_text == "-" else rows_text.split(";"):
        parts = item.split("|")
        if len(parts) != 5 or not parts[0] or parts[1] not in GEOMETRY_KINDS:
            return f"bad row '{item}'"
        frame = parse_rect(parts[2])
        visible = None if parts[3] == "-" else parse_rect(parts[3])
        if frame is None or (parts[3] != "-" and visible is None):
            return f"bad row rectangle in '{item}'"
        if parts[1] == "code" and not parts[4].isdigit():
            return f"code row without its draws: '{item}'"
        if parts[1] != "code" and parts[4] != "-" and not parts[4].isdigit():
            return f"bad draws on a {parts[1]} row: '{item}'"
        rows.append(GeometryRow(parts[0], parts[1], frame, visible, int(parts[4]) if parts[4].isdigit() else None))
    return CaptureGeometry(int(seq), scale_value, screen, window, visible_rows, rows)


def geometry_bracket(lines: list[str], landed_at: int) -> tuple[CaptureGeometry | None, CaptureGeometry | None,
                                                                list[str]]:
    """(seq=1, seq=2, problems): the CAPTURE_GEOMETRY lines visual-parity.sh
    asks for right before and right after its screenshot (G1, protocol part)."""
    problems: list[str] = []
    found: dict[int, CaptureGeometry] = {}
    early = sum(1 for line in lines[:landed_at] if line.startswith("CAPTURE_GEOMETRY"))
    if early:
        problems.append(f"{early} CAPTURE_GEOMETRY line(s) before SCROLL_LANDED: the bracket must follow the landing")
    for line in lines[landed_at + 1:]:
        if not line.startswith("CAPTURE_GEOMETRY"):
            continue
        parsed = parse_geometry(line)
        if isinstance(parsed, str):
            seq = key_values(line).get("seq", "?")
            problems.append(f"CAPTURE_GEOMETRY seq={seq}: {parsed}")
            continue
        if parsed.seq in found:
            problems.append(f"CAPTURE_GEOMETRY seq={parsed.seq} printed twice")
        elif parsed.seq not in (1, 2):
            problems.append(f"CAPTURE_GEOMETRY seq={parsed.seq}: the driver posts exactly twice (before and after)")
        found.setdefault(parsed.seq, parsed)
    before, after = found.get(1), found.get(2)
    errored = {key_values(line).get("seq") for line in lines[landed_at + 1:]
               if line.startswith("CAPTURE_GEOMETRY") and isinstance(parse_geometry(line), str)}
    if before is None and "1" not in errored:
        problems.append("no CAPTURE_GEOMETRY seq=1 (the screen right before the screenshot)")
    if after is None and "2" not in errored:
        problems.append("no CAPTURE_GEOMETRY seq=2 (the screen right after the screenshot)")
    if before is not None and after is not None and before.stable_key() != after.stable_key():
        changed = [label for label, a, b in (
            ("scale/screen/window", (before.scale, before.screen, before.window), (after.scale, after.screen, after.window)),
            ("visibleRows", before.visible_rows, after.visible_rows),
            ("rows", [(r.owner, r.kind, r.frame, r.visible) for r in before.rows],
             [(r.owner, r.kind, r.frame, r.visible) for r in after.rows])) if a != b]
        problems.append(f"geometry changed across the screenshot ({', '.join(changed)}): seq=1 and seq=2 differ")
    return before, after, problems


def px_inner(r: Rect, s: float) -> tuple[int, int, int, int]:
    """The pixels wholly inside r (points at scale s): x0,y0,x1,y1, exclusive."""
    slack = GEOMETRY_SLACK_PX
    return (math.ceil(r[0] * s - slack), math.ceil(r[1] * s - slack),
            math.floor(r[2] * s + slack), math.floor(r[3] * s + slack))


def px_outer(r: Rect, s: float) -> tuple[int, int, int, int]:
    """Every pixel r touches (points at scale s)."""
    slack = GEOMETRY_SLACK_PX
    return (math.floor(r[0] * s + slack), math.floor(r[1] * s + slack),
            math.ceil(r[2] * s - slack), math.ceil(r[3] * s - slack))


def grow(r: tuple[int, int, int, int], d: int) -> tuple[int, int, int, int]:
    return (r[0] - d, r[1] - d, r[2] + d, r[3] + d)


def clamp(r: tuple[int, int, int, int], width: int, height: int) -> tuple[int, int, int, int]:
    x0, y0 = min(max(r[0], 0), width), min(max(r[1], 0), height)
    return (x0, y0, max(min(r[2], width), x0), max(min(r[3], height), y0))


def overlaps(a: tuple[int, int, int, int], b: tuple[int, int, int, int]) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def rect_mask(shape: tuple[int, int], rect: tuple[int, int, int, int], origin: tuple[int, int]) -> np.ndarray:
    """True inside `rect` (image pixels) for an array of `shape` whose (0, 0)
    is image pixel `origin` (x, y)."""
    mask = np.zeros(shape, dtype=bool)
    x0, y0 = rect[0] - origin[0], rect[1] - origin[1]
    x1, y1 = rect[2] - origin[0], rect[3] - origin[1]
    mask[max(y0, 0):max(min(y1, shape[0]), 0), max(x0, 0):max(min(x1, shape[1]), 0)] = True
    return mask


def top_level(owner: str) -> str:
    """The top-level block of a node-path id: 0.30 for 0.30.0.1."""
    parts = owner.split(".")
    return ".".join(parts[:2]) if len(parts) > 2 else owner


def root_index(block: str) -> int | None:
    """k of a top-level id 0.<k>, else None."""
    head, sep, tail = block.partition(".")
    return int(tail) if head == "0" and sep and tail.isdigit() else None


def attribute_code_boxes(geometry: CaptureGeometry, code_crops: list[CodeCrop], cand_ink: np.ndarray) -> None:
    """Sets each code crop's owner (docstring "CODE CAPTURES"): which
    TextKit 2 code row, if any, drew its code ink in the candidate."""
    height, width = cand_ink.shape
    s = geometry.scale
    code_rows = [r for r in geometry.rows if r.kind == "code"]
    for c in code_crops:
        bx0, by0, bx1, by1 = (int(v) for v in c.box.split(","))
        split = int(c.header_box.split(",")[3])
        over = [r for r in code_rows if overlaps(clamp(grow(px_outer(r.frame, s), 1), width, height), (bx0, by0, bx1, by1))]
        if not (c.text_box and c.cand_ink):   # an empty block, or text under the bottom band
            c.owner = ("covered:" + ",".join(r.owner for r in over)) if over else ""
            continue
        if not over:
            c.owner = "swiftui"
            continue
        if len(over) > 1 or over[0].visible is None:
            c.owner = "mixed"
            continue
        row = over[0]
        ink = cand_ink[split:by1, bx0:bx1]
        inner = clamp(px_inner(row.visible, s), width, height)
        inside = rect_mask(ink.shape, inner, (bx0, split))
        allowed = rect_mask(ink.shape, clamp(grow(px_inner(row.visible, s), 1), width, height), (bx0, split))
        c.owner_px = int((ink & inside).sum())
        outside = int((ink & ~allowed).sum())
        c.owner = f"tk2:{row.owner}" if c.owner_px > 0 and outside == 0 else "mixed"
        if c.owner == "mixed":
            c.notes = "; ".join(filter(None, [c.notes, f"{outside} px of code ink outside owner {row.owner}'s "
                                                       f"on-screen frame ({c.owner_px} px inside)"]))


def capture_geometry(lines: list[str], landed_at: int,
                     image_size: tuple[int, int]) -> tuple[CaptureGeometry | None, list[str]]:
    """(seq=1 geometry, problems): G1, the bracket, the image size and the
    whole-screen window. None (with the problems) when it cannot be used."""
    before, _, problems = geometry_bracket(lines, landed_at)
    if before is None or problems:
        return None, problems
    geo = before
    image_w, image_h = image_size
    want_w, want_h = round(geo.screen[0] * geo.scale), round(geo.screen[1] * geo.scale)
    if (want_w, want_h) != (image_w, image_h):
        return None, [f"geometry is {geo.screen[0]:g}x{geo.screen[1]:g} pt at {geo.scale:g}x, "
                      f"the image is {image_w}x{image_h} px"]
    full = (0.0, 0.0, geo.screen[0], geo.screen[1])
    if any(abs(a - b) > WINDOW_SLACK_PT for a, b in zip(geo.window, full)):
        return None, [f"the window {','.join(f'{v:g}' for v in geo.window)} is not the whole screen "
                      f"{geo.screen[0]:g}x{geo.screen[1]:g} pt"]
    return geo, []


def measure_landing(rule: CodeRule, geo: CaptureGeometry, top_band: int, problems: list[str],
                    summary: list[str]) -> None:
    """G7: the landing is measured (visibleRows), and on arm C the land
    block's TextKit 2 row is shown below the top band."""
    visible = geo.visible_rows
    if visible is None:
        problems.append("visibleRows unavailable (no visibility feed before iOS 18): the landing cannot be measured")
    else:
        found = len(problems)
        if rule.land not in visible:
            problems.append(f"land block {rule.land} is not fully visible at the screenshot "
                            f"(visibleRows {','.join(visible) or '-'})")
        land_k = root_index(rule.land)
        above = [block for block in visible
                 if land_k is not None and (k := root_index(block)) is not None and k < land_k - 1]
        if above:
            problems.append(f"block(s) {','.join(above)} above the land block {rule.land} fully visible: "
                            "the position landed higher than declared")
        tops = sorted((root_index(block), block) for block in visible if root_index(block) is not None)
        summary.append(f"land {rule.land} " + ("measured" if len(problems) == found else "NOT measured")
                       + f" (topmost {tops[0][1] if tops else '-'})")
    if rule.engine == "textkit2":
        for row in (r for r in geo.rows if r.owner == rule.land):
            if row.visible is None:
                problems.append(f"the land block {rule.land}'s TextKit 2 row is not on screen")
            elif row.visible[1] * geo.scale < top_band - 1:
                problems.append(f"the land block {rule.land}'s TextKit 2 row starts at "
                                f"{row.visible[1] * geo.scale:.1f} px, under the top band ({top_band} px)")


def check_no_rows(geo: CaptureGeometry, problems: list[str], summary: list[str]) -> None:
    """G9: the SwiftUI arm has no TextKit 2 row at all."""
    if geo.rows:
        problems.append("SwiftUI arm has TextKit 2 rows in the window: "
                        + ",".join(f"{r.owner}|{r.kind}" for r in geo.rows))
    summary.append("rows none" if not geo.rows else "rows present")


def check_presence(rule: CodeRule, geo: CaptureGeometry, problems: list[str], summary: list[str]) -> None:
    """G8 (O8): a fallback capture shows a named owner (or its top-level
    block, for a nested id) in visibleRows."""
    visible = geo.visible_rows
    if rule.cls != "fallback" or visible is None:
        return
    present = [owner for owner, _ in rule.owners if owner in visible or top_level(owner) in visible]
    if not present:
        problems.append(f"no declared owner is visibly present (visibleRows {','.join(visible) or '-'}; "
                        f"owners {','.join(owner for owner, _ in rule.owners)})")
    else:
        summary.append("present " + ",".join(present))


def evaluate_code_geometry(rule: CodeRule, lines: list[str], landed_at: int, code_crops: list[CodeCrop],
                           cand_ink: np.ndarray, image_size: tuple[int, int], box_scale: int,
                           top_band: int) -> tuple[list[str], str]:
    """(problems, summary) of a code capture's capture-time geometry
    (docstring "CODE CAPTURES", G1-G9). Sets each code crop's owner."""
    geo, problems = capture_geometry(lines, landed_at, image_size)
    if geo is None:
        return problems, "absent"
    image_w, image_h = image_size
    summary: list[str] = []
    if box_scale != round(geo.scale):
        summary.append(f"box detection at {box_scale}x, geometry at {geo.scale:g}x")
    native = rule.engine == "textkit2"
    if native:
        attribute_code_boxes(geo, code_crops, cand_ink)
    else:
        for c in code_crops:
            c.owner = "swiftui" if c.text_box and c.cand_ink else ""

    measure_landing(rule, geo, top_band, problems, summary)   # G7

    if rule.engine == "swiftui":
        check_no_rows(geo, problems, summary)   # G9
    else:
        declared = dict(rule.owners)
        rows_by_owner: dict[str, list[GeometryRow]] = {}
        for row in geo.rows:
            rows_by_owner.setdefault(row.owner, []).append(row)
        owned: dict[str, int] = {}
        mixed_under: set[str] = set()
        for c in code_crops:
            summary.append(f"k{c.index:02d} {c.owner or '-'}" + (f" ({c.owner_px} px)" if c.owner.startswith("tk2:") else ""))
            if c.owner == "mixed":   # G2
                over = [r.owner for r in geo.rows if r.kind == "code" and overlaps(
                    clamp(grow(px_outer(r.frame, geo.scale), 1), image_w, image_h),
                    tuple(int(v) for v in c.box.split(",")))]
                mixed_under.update(over)
                if len(over) > 1:
                    problems.append(f"code box {c.index}: two TextKit 2 rows over one box ({','.join(over)})")
                elif over and next(r for r in geo.rows if r.owner == over[0] and r.kind == "code").visible is None:
                    problems.append(f"code box {c.index}: owner {over[0]}'s row over it is hidden or clipped off screen")
                else:
                    problems.append(f"code box {c.index}: code ink outside owner {','.join(over)}'s on-screen frame")
            elif c.owner.startswith("tk2:"):   # G4
                owner = c.owner[4:]
                owned[owner] = owned.get(owner, 0) + c.owner_px
                if declared.get(owner) == "swiftui":
                    problems.append(f"code box {c.index} is drawn by TextKit 2 row {owner} (declared swiftui)")
                elif owner not in declared and rule.cls == "fallback":
                    problems.append(f"code box {c.index} is drawn by TextKit 2 row {owner} (a fallback capture)")
                elif owner not in declared:
                    summary.append(f"undeclared native owner {owner} (not coverage)")
            elif c.owner.startswith("covered:"):
                summary.append(f"k{c.index:02d}: a TextKit 2 row over a box without code ink")
        for owner, engine in rule.owners:
            rows = rows_by_owner.get(owner, [])
            code = [r for r in rows if r.kind == "code"]
            if engine == "tk2":   # G3
                if not code:
                    problems.append(f"owner {owner}: no TextKit 2 code row in the window at the screenshot")
                elif all(r.visible is None for r in code):
                    problems.append(f"owner {owner}: its row is clipped off screen (or hidden) at the screenshot")
                elif owner not in owned and owner in mixed_under:
                    problems.append(f"owner {owner}: the code box under its row is mixed (above)")
                elif owner not in owned:
                    problems.append(f"owner {owner}: on screen but over no scored code box")
                elif max(r.draws or 0 for r in code) <= 0:
                    problems.append(f"owner {owner}: its row has 0 native draws before the screenshot")
            elif rows:   # G6
                problems.append(f"owner {owner} (declared swiftui) has a TextKit 2 row in the window "
                                f"({'on screen' if any(r.visible for r in rows) else 'off screen'})")
    check_presence(rule, geo, problems, summary)   # G8
    return problems, "; ".join(summary)


# ---- container and caption captures (docstring "CONTAINER AND CAPTION CAPTURES")

def evaluate_owner_geometry(rule: CodeRule, lines: list[str], landed_at: int, image_size: tuple[int, int],
                            top_band: int) -> tuple[list[str], str, list[GeometryRow], float]:
    """(problems, summary, rows to crop, scale) of a container or caption
    capture's capture-time geometry: G1, G7, G9 as for code, and O3, O4, O6,
    O8. The rows to crop are the shown, non-code rows of the tk2 owners
    (arm C), in points at `scale`."""
    geo, problems = capture_geometry(lines, landed_at, image_size)
    if geo is None:
        return problems, "absent", [], 0.0
    summary: list[str] = []
    measure_landing(rule, geo, top_band, problems, summary)   # G7
    crop_rows: list[GeometryRow] = []
    if rule.engine == "swiftui":
        check_no_rows(geo, problems, summary)   # G9
    else:
        declared = dict(rule.owners)
        rows_by_owner: dict[str, list[GeometryRow]] = {}
        for row in geo.rows:
            rows_by_owner.setdefault(row.owner, []).append(row)
        for owner, engine in rule.owners:
            rows = rows_by_owner.get(owner, [])
            text = [r for r in rows if r.kind != "code"]
            shown = [r for r in text if r.visible is not None]
            if engine == "tk2":   # O3
                if not rows:
                    problems.append(f"owner {owner}: no TextKit 2 row in the window at the screenshot")
                elif not text:
                    problems.append(f"owner {owner}: its TextKit 2 row is a code row (the {rule.kind} proof "
                                    "counts no code row)")
                elif not shown:
                    problems.append(f"owner {owner}: its row is clipped off screen (or hidden) at the screenshot")
                elif any(r.draws is None for r in shown):
                    problems.append(f"owner {owner}: its shown row reports no draws at the screenshot (draws - in "
                                    "the geometry: a build whose reporter does not print a live container or "
                                    "caption row's draws proves nothing)")
                elif any(r.draws == 0 for r in shown):
                    problems.append(f"owner {owner}: its shown row has not drawn natively at the screenshot "
                                    "(draws 0 in the geometry)")
                else:
                    crop_rows += shown
                    summary.append(f"{owner} " + ",".join(f"{r.kind}@{','.join(f'{v:g}' for v in r.visible)}"
                                                          + ("" if r.draws is None else f" draws {r.draws}")
                                                          for r in shown))
            elif rows:   # O6
                problems.append(f"owner {owner} (declared swiftui) has a TextKit 2 row in the window "
                                f"({'on screen' if any(r.visible for r in rows) else 'off screen'})")
        # O4: rows of this kind on screen that the declaration does not name.
        listed = kind_rows(rule, lines, landed_at) or {}
        for owner in sorted(owner for owner in listed if owner not in declared):
            if not any(r.visible is not None for r in rows_by_owner.get(owner, [])):
                continue
            if rule.cls == "fallback":
                problems.append(f"TextKit 2 {rule.kind} row {owner} is on screen (a fallback capture)")
            else:
                summary.append(f"undeclared native owner {owner} (not coverage)")
    check_presence(rule, geo, problems, summary)   # O8
    return problems, "; ".join(summary), crop_rows, geo.scale


def score_owner_crops(rule: CodeRule, rows: list[GeometryRow], scale: float, name: str, first_index: int,
                      ref: np.ndarray, cand: np.ndarray, valid: np.ndarray, masked: np.ndarray,
                      diff: np.ndarray, crop_limit: float, ref_ink: np.ndarray, cand_ink: np.ndarray,
                      ref_weight: np.ndarray, cand_weight: np.ndarray, ref_search: np.ndarray,
                      cand_search: np.ndarray, out_dir: Path, args: argparse.Namespace) -> list[OwnerCrop]:
    """One text crop per shown TextKit 2 row of a tk2 owner (docstring
    "CONTAINER AND CAPTION CAPTURES"), scored with the code text rule."""
    height, width = valid.shape
    union_ink = ref_ink | cand_ink
    crops: list[OwnerCrop] = []
    for offset, row in enumerate(rows):
        index = first_index + offset
        x0, y0, x1, y1 = clamp(px_outer(row.visible, scale), width, height)
        ix0, iy0, ix1, iy1 = clamp(px_inner(row.visible, scale), width, height)
        problems: list[str] = []   # FAIL
        invalid: list[str] = []    # INVALID
        owner_px = int(cand_ink[iy0:iy1, ix0:ix1].sum())
        has_ref = bool(ref_ink[y0:y1, x0:x1].any())
        has_cand = bool(cand_ink[y0:y1, x0:x1].any())
        text_box, text_pct, lines = "", 0.0, 0
        worst, worst_centroid, one_sided = (0, 0), (0.0, 0.0), 0
        if int(valid[y0:y1, x0:x1].sum()) <= 0:
            invalid.append(f"owner {row.owner}'s on-screen frame has no scorable pixel (under the masks)")
        elif not (has_ref or has_cand):
            invalid.append(f"no text ink inside owner {row.owner}'s on-screen frame in either image")
        else:
            if owner_px <= 0:
                invalid.append(f"no candidate ink inside owner {row.owner}'s on-screen frame: its row's drawing "
                               "is not on screen")
            text_union = union_ink[y0:y1, x0:x1]
            rows_on = np.flatnonzero(text_union.any(axis=1))
            cols_on = np.flatnonzero(text_union.any(axis=0))
            ty0, ty1 = y0 + int(rows_on[0]), y0 + int(rows_on[-1]) + 1
            tx0, tx1 = x0 + int(cols_on[0]), x0 + int(cols_on[-1]) + 1
            text_box = box_text((tx0, ty0, tx1, ty1))
            area = int(valid[ty0:ty1, tx0:tx1].sum())
            text_pct = float(diff[ty0:ty1, tx0:tx1].sum()) / area * 100.0 if area else 0.0
            if text_pct > crop_limit:
                problems.append(f"{rule.kind} text {text_pct:.3f}% > {crop_limit}%")
            if not has_cand:
                problems.append(f"{rule.kind} text missing in candidate")
            if not has_ref:
                problems.append(f"{rule.kind} text extra in candidate")
            for by0, by1 in segment_rows(text_union, min_rows=1, max_gap=CODE_LINE_GAP):
                ay0, ay1 = y0 + by0, y0 + by1
                line_cols = np.flatnonzero(text_union[by0:by1].any(axis=0))
                lx0, lx1 = x0 + int(line_cols[0]), x0 + int(line_cols[-1]) + 1
                lines += 1
                dx, dy, _ = best_shift_2d(ref_search, cand_search, ay0, ay1, lx0, lx1, args.code_search)
                if max(abs(dx), abs(dy)) > max(abs(worst[0]), abs(worst[1])):
                    worst = (dx, dy)
                ref_c = ink_centroid(ref_weight, ay0, ay1, lx0, lx1)
                cand_c = ink_centroid(cand_weight, ay0, ay1, lx0, lx1)
                if ref_c is None or cand_c is None:
                    one_sided += 1
                    continue
                moved = (cand_c[0] - ref_c[0], cand_c[1] - ref_c[1])
                if max(abs(moved[0]), abs(moved[1])) > max(abs(worst_centroid[0]), abs(worst_centroid[1])):
                    worst_centroid = moved
            if max(abs(worst[0]), abs(worst[1])) > args.max_offset_px:
                problems.append(f"{rule.kind} line displaced {worst[0]:+d},{worst[1]:+d} px (x,y)")
            if max(abs(worst_centroid[0]), abs(worst_centroid[1])) > args.max_position_px:
                problems.append(f"{rule.kind} line ink centroid moved {worst_centroid[0]:+.2f},"
                                f"{worst_centroid[1]:+.2f} px (x,y)")
            if one_sided and has_ref and has_cand:
                problems.append(f"{one_sided} {rule.kind} line(s) with ink in one image only")
        verdict = "FAIL" if problems else "INVALID" if invalid else "PASS"
        crop = OwnerCrop(index, rule.kind, row.owner, box_text((x0, y0, x1, y1)), text_box, round(text_pct, 4),
                         lines, worst[0], worst[1], round(worst_centroid[0], 3), round(worst_centroid[1], 3),
                         has_ref, has_cand, owner_px, verdict, "; ".join(problems + invalid))
        crops.append(crop)
        if verdict != "PASS":
            (out_dir / "crops").mkdir(parents=True, exist_ok=True)
            py0, py1 = max(y0 - 12, 0), min(y1 + 12, height)
            px0, px1 = max(x0 - 12, 0), min(x1 + 12, width)
            overlay = diff_overlay(ref, diff, masked)
            triptych([ref[py0:py1, px0:px1], cand[py0:py1, px0:px1], overlay[py0:py1, px0:px1]],
                     f"{name} {rule.kind} owner {row.owner} {verdict}: {crop.notes}"[:300],
                     out_dir / "crops" / f"{name}-o{index:02d}.png")
    return crops


def parse_code_captures(items: list[list[str]], pair_names: set[str]) -> dict[str, CodeRule]:
    """The code-kind declarations of parse_captures: {pair name: rule}."""
    return {name: kinds["code"] for name, kinds in parse_captures(items, pair_names).items() if "code" in kinds}


def parse_captures(items: list[list[str]], pair_names: set[str]) -> dict[str, dict[str, CodeRule]]:
    """--code-capture NAME [KIND:]CLASS OWNERS ENGINE LOG -> {pair name:
    {kind: rule}}; at most one declaration per pair and kind."""
    rules: dict[str, dict[str, CodeRule]] = {}
    for name, label, owners_text, engine, log in items:
        where = f"--code-capture {name}"
        kind, sep, cls = label.rpartition(":")
        kind = kind if sep else "code"
        if kind not in CAPTURE_KINDS:
            raise InputError(f"{where}: kind '{kind}' (want {' | '.join(CAPTURE_KINDS)})")
        if kind != "code":
            where += f" ({kind})"
        if name not in pair_names:
            raise InputError(f"{where}: no --pair has that name")
        if kind in rules.get(name, {}):
            raise InputError(f"{where}: declared twice")
        if cls not in ("positive", "fallback"):
            raise InputError(f"{where}: class '{cls}' (want positive | fallback)")
        if engine not in ("textkit2", "swiftui", "none"):
            raise InputError(f"{where}: engine '{engine}' (want textkit2 | swiftui | none)")
        if engine != "none" and log in ("", "-"):
            raise InputError(f"{where}: engine {engine} needs the candidate's launch log")
        owner_part, _, rest = owners_text.partition(";")
        land = ""
        for option in filter(None, rest.split(";")):
            key, sep, value = option.partition("=")
            if key != "land" or not sep or not value:
                raise InputError(f"{where}: bad option '{option}' (want land=<block id>)")
            land = value
        owners: list[tuple[str, str]] = []
        for item in filter(None, owner_part.split(",")):
            owner, sep, expected = item.partition("=")
            if not owner or not sep or expected not in ("tk2", "swiftui"):
                raise InputError(f"{where}: bad owner '{item}' (want <owner>=<tk2|swiftui>)")
            owners.append((owner, expected))
        if not owners:
            raise InputError(f"{where}: names no {kind} owner")
        if len({owner for owner, _ in owners}) != len(owners):
            raise InputError(f"{where}: an owner is named twice")
        native = [owner for owner, expected in owners if expected == "tk2"]
        if cls == "positive" and not native:
            raise InputError(f"{where}: a positive capture needs an owner declared tk2")
        if cls == "fallback" and native:
            raise InputError(f"{where}: a fallback capture cannot declare {','.join(native)} tk2")
        if not land:
            raise InputError(f"{where}: needs ;land=<block id> (the landing is measured)")
        rules.setdefault(name, {})[kind] = CodeRule(cls, owners, land, engine, log, kind)
    return rules


def diff_overlay(ref: np.ndarray, diff: np.ndarray, masked: np.ndarray) -> np.ndarray:
    base = (to_gray(ref) * 0.35 + 140).astype(np.uint8)
    rgb = np.stack([base, base, base], axis=2)
    rgb[masked] = (rgb[masked] * 0.4).astype(np.uint8)
    rgb[diff] = (230, 30, 30)
    return rgb


def triptych(panels: list[np.ndarray], caption: str, path: Path) -> None:
    height, width = panels[0].shape[:2]
    gutter, header = 12, 48
    canvas = Image.new("RGB", (width * len(panels) + gutter * (len(panels) - 1), height + header), (40, 40, 40))
    for i, panel in enumerate(panels):
        canvas.paste(Image.fromarray(panel), (i * (width + gutter), header))
    ImageDraw.Draw(canvas).text((8, 14), caption, fill=(255, 255, 255))
    canvas.save(path, optimize=True)


def pct_limit(kind: str, args: argparse.Namespace) -> tuple[float, float]:
    """(viewport limit, crop limit) for a pair kind."""
    if kind == "noise":
        return args.max_noise_pct, args.max_noise_pct
    if kind == "exact":
        return args.max_exact_pct, args.max_exact_pct
    return args.max_raw_pct, args.max_crop_pct


def score_code_boxes(kind: str, name: str, ref: np.ndarray, cand: np.ndarray, stable: np.ndarray | None,
                     valid: np.ndarray, exact_only: np.ndarray, masked: np.ndarray, diff: np.ndarray,
                     crop_limit: float, ref_ink: np.ndarray, cand_ink: np.ndarray,
                     ref_weight: np.ndarray, cand_weight: np.ndarray,
                     ref_search: np.ndarray, cand_search: np.ndarray,
                     out_dir: Path, args: argparse.Namespace) -> tuple[list[CodeCrop], list[str], bool]:
    """The pair's code boxes (docstring "CODE BOXES"): (one CodeCrop per
    reference code box, pair notes, whether the candidate holds a code box
    the reference lacks). `stable` is the A' capture of the same reference,
    when the run has one; `diff` is the kind's pixel rule."""
    height, width = valid.shape
    scale = args.pixel_scale or max(1, round(width / 400))
    scorable = valid & ~exact_only
    outer, inner = CODE_OUTLINE_OUTER_PT * scale, CODE_OUTLINE_INNER_PT * scale

    def code_boxes(rgb: np.ndarray, ink: np.ndarray) -> tuple[list[tuple[tuple[int, int, int, int], int]], int]:
        found, cut = [], 0
        for box in find_fill_boxes(rgb, scorable, args.code_fill, args.code_fill_tolerance, scale):
            x0, y0, x1, _ = box
            if y0 == 0 or not scorable[y0 - 1, x0:x1].any():
                cut += 1   # runs under the top band: its header strip cannot be seen
                continue
            split = code_box_split(ink, box, scale)
            if split is not None:
                found.append((box, split))
        return found, cut

    ref_boxes, ref_cut = code_boxes(ref, ref_ink)
    cand_boxes, _ = code_boxes(cand, cand_ink)
    notes: list[str] = []
    if ref_cut:
        notes.append(f"{ref_cut} code-fill box(es) cut by the top band: not scored as code boxes")
    if not ref_boxes and not cand_boxes:
        return [], notes, False

    chrome = diff_mask(ref, cand, CHROME_THRESHOLD) & scorable
    steady = (diff_mask(ref, stable, CHROME_THRESHOLD) & scorable) if stable is not None else None
    if kind != "noise" and stable is None and ref_boxes:
        notes.append("code chrome: no A-A' pair with this reference in this run (stability not measured)")
    union_ink = ref_ink | cand_ink

    # Geometry: exact matches first, then the nearest leftover box.
    remaining = [box for box, _ in cand_boxes]
    geometry: dict[tuple[int, int, int, int], str] = {}
    for box, _ in ref_boxes:
        if box in remaining:
            remaining.remove(box)
            geometry[box] = "same"
    for box, _ in ref_boxes:
        if box in geometry:
            continue
        if remaining:
            nearest = min(remaining, key=lambda other: sum(abs(a - b) for a, b in zip(other, box)))
            remaining.remove(nearest)
            geometry[box] = "moved " + ",".join(f"{b - a:+d}" for a, b in zip(box, nearest))
        else:
            geometry[box] = "missing in candidate"

    crops: list[CodeCrop] = []
    crop_dir = out_dir / "crops"
    for index, (box, split) in enumerate(ref_boxes):
        x0, y0, x1, y1 = box
        problems: list[str] = []   # FAIL
        invalid: list[str] = []    # INVALID: a crop that cannot be scored
        info: list[str] = []
        open_bottom = y1 >= height or not scorable[y1, x0:x1].any()
        if geometry[box] != "same":
            problems.append(f"box {geometry[box]}" + (" (x0,y0,x1,y1)" if geometry[box].startswith("moved") else ""))

        # Chrome: header strip and outline, zero pixels at channel threshold 0.
        header_area = int(scorable[y0:split, x0:x1].sum())
        header_px = int(chrome[y0:split, x0:x1].sum())
        (wx0, wy0, wx1, wy1), ring = outline_mask((height, width), box, split, outer, inner, open_bottom)
        ring &= scorable[wy0:wy1, wx0:wx1]
        outline_area = int(ring.sum())
        outline_px = int((chrome[wy0:wy1, wx0:wx1] & ring).sum())
        stable_header = stable_outline = -1
        if steady is not None:
            stable_header = int(steady[y0:split, x0:x1].sum())
            stable_outline = int((steady[wy0:wy1, wx0:wx1] & ring).sum())
        if header_area <= 0:
            invalid.append("header strip has no scorable pixel")
        if outline_area <= 0:
            invalid.append("outline has no scorable pixel")
        unstable = kind != "noise" and (stable_header > 0 or stable_outline > 0)
        # No matching A-A' pair: stability is not proven, so exact chrome is
        # not judged either way (the counts stay in the output).
        unmeasured = kind != "noise" and steady is None
        if unstable:
            info.append(f"chrome not exactly stable in A-A' (header {stable_header} px, outline {stable_outline} px)"
                        f": chrome rule not evaluated (A-C header {header_px} px, outline {outline_px} px)")
        elif unmeasured:
            info.append(f"chrome stability not measured (no A-A' pair with this reference): chrome rule not "
                        f"evaluated (this pair: header {header_px} px, outline {outline_px} px)")
        else:
            if header_px > MAX_CHROME_PX:
                problems.append(f"header strip: {header_px} px differ at channel threshold {CHROME_THRESHOLD}")
            if outline_px > MAX_CHROME_PX:
                problems.append(f"outline: {outline_px} px differ at channel threshold {CHROME_THRESHOLD}")

        # Code text: percentage over the union ink box, displacement per line.
        text_box, text_pct, lines = "", 0.0, 0
        worst, worst_centroid, one_sided = (0, 0), (0.0, 0.0), 0
        has_ref = bool(ref_ink[split:y1, x0:x1].any())
        has_cand = bool(cand_ink[split:y1, x0:x1].any())
        text_union = union_ink[split:y1, x0:x1]
        if text_union.any():
            rows = np.flatnonzero(text_union.any(axis=1))
            cols = np.flatnonzero(text_union.any(axis=0))
            ty0, ty1 = split + int(rows[0]), split + int(rows[-1]) + 1
            tx0, tx1 = x0 + int(cols[0]), x0 + int(cols[-1]) + 1
            text_box = box_text((tx0, ty0, tx1, ty1))
            area = int(valid[ty0:ty1, tx0:tx1].sum())
            if area <= 0:
                invalid.append("code text crop has no scorable pixel")
            else:
                text_pct = float(diff[ty0:ty1, tx0:tx1].sum()) / area * 100.0
                if text_pct > crop_limit:
                    problems.append(f"code text {text_pct:.3f}% > {crop_limit}%")
            if not has_cand:
                problems.append("code text missing in candidate")
            if not has_ref:
                problems.append("code text extra in candidate")
            for by0, by1 in segment_rows(text_union, min_rows=1, max_gap=CODE_LINE_GAP):
                ay0, ay1 = split + by0, split + by1
                line_cols = np.flatnonzero(text_union[by0:by1].any(axis=0))
                lx0, lx1 = x0 + int(line_cols[0]), x0 + int(line_cols[-1]) + 1
                lines += 1
                dx, dy, _ = best_shift_2d(ref_search, cand_search, ay0, ay1, lx0, lx1, args.code_search)
                if max(abs(dx), abs(dy)) > max(abs(worst[0]), abs(worst[1])):
                    worst = (dx, dy)
                ref_c = ink_centroid(ref_weight, ay0, ay1, lx0, lx1)
                cand_c = ink_centroid(cand_weight, ay0, ay1, lx0, lx1)
                if ref_c is None or cand_c is None:
                    one_sided += 1
                    continue
                moved = (cand_c[0] - ref_c[0], cand_c[1] - ref_c[1])
                if max(abs(moved[0]), abs(moved[1])) > max(abs(worst_centroid[0]), abs(worst_centroid[1])):
                    worst_centroid = moved
            if max(abs(worst[0]), abs(worst[1])) > args.max_offset_px:
                problems.append(f"code line displaced {worst[0]:+d},{worst[1]:+d} px (x,y)")
            if max(abs(worst_centroid[0]), abs(worst_centroid[1])) > args.max_position_px:
                problems.append(f"code line ink centroid moved {worst_centroid[0]:+.2f},{worst_centroid[1]:+.2f} px (x,y)")
            if one_sided and has_ref and has_cand:
                problems.append(f"{one_sided} code line(s) with ink in one image only")
        elif open_bottom:
            info.append("code text under the bottom band: geometry and chrome only")
        else:
            info.append("no code ink (an empty block): geometry and chrome only")

        verdict = ("FAIL" if problems else "INVALID" if invalid else "UNSTABLE" if unstable
                   else "UNMEASURED" if unmeasured else "PASS")
        crop = CodeCrop(index, box_text(box), "bottom" if open_bottom else "", geometry[box],
                        box_text((x0, y0, x1, split)), header_px, outline_px, stable_header, stable_outline,
                        text_box, round(text_pct, 4), lines, worst[0], worst[1],
                        round(worst_centroid[0], 3), round(worst_centroid[1], 3), has_ref, has_cand,
                        verdict, "; ".join(problems + invalid + info))
        crops.append(crop)
        if verdict != "PASS":
            crop_dir.mkdir(parents=True, exist_ok=True)
            py0, py1 = max(y0 - 12, 0), min(y1 + 12, height)
            px0, px1 = max(x0 - 12, 0), min(x1 + 12, width)
            overlay = diff_overlay(ref, chrome, masked)
            triptych([ref[py0:py1, px0:px1], cand[py0:py1, px0:px1], overlay[py0:py1, px0:px1]],
                     f"{name} code box {index} {verdict}: {crop.notes}"[:300],
                     crop_dir / f"{name}-k{index:02d}.png")
    if remaining:
        notes.append(f"{len(remaining)} code box(es) only in the candidate: "
                     + " ".join(box_text(box) for box in remaining))
    return crops, notes, bool(remaining)


def score_pair(kind: str, name: str, ref_path: str, cand_path: str, out_dir: Path,
               rects: list[tuple[int, int, int, int]], exact_rects: list[tuple[int, int, int, int]],
               args: argparse.Namespace, code_rule: CodeRule | None = None,
               stable_path: str | None = None, owner_rules: tuple[CodeRule, ...] = ()) -> Score:
    ref = load_rgb(ref_path)
    cand = load_rgb(cand_path)
    cand_shape = cand.shape   # the candidate as captured: what its CAPTURE_GEOMETRY describes
    notes: list[str] = []
    size_match = ref.shape == cand.shape
    if not size_match:
        notes.append(f"size mismatch ref {ref.shape[1]}x{ref.shape[0]} vs cand {cand.shape[1]}x{cand.shape[0]}")
        h, w = min(ref.shape[0], cand.shape[0]), min(ref.shape[1], cand.shape[1])
        ref, cand = ref[:h, :w], cand[:h, :w]
    height, width = ref.shape[:2]
    masked = build_mask(height, width, rects + (exact_rects if kind != "tolerant" else []),
                        args.top_band, args.bottom_band)
    valid = ~masked
    valid_count = int(valid.sum())

    pixel_threshold = args.threshold if kind == "tolerant" else args.exact_threshold
    diff = diff_mask(ref, cand, pixel_threshold) & valid
    diff_aa = diff_mask(ref, cand, args.threshold) & valid
    viewport_px, viewport_px_aa = int(diff.sum()), int(diff_aa.sum())
    viewport_pct = viewport_px / valid_count * 100.0
    viewport_pct_aa = viewport_px_aa / valid_count * 100.0
    # Where the differing pixels are (x0,y0,x1,y1 exclusive): a count too
    # small for the 4-decimal % still has to be findable.
    ys, xs = np.nonzero(diff)
    diff_bbox = f"{xs.min()},{ys.min()},{xs.max() + 1},{ys.max() + 1}" if viewport_px else ""
    vp_limit, crop_limit = pct_limit(kind, args)

    ref_gray, cand_gray = to_gray(ref), to_gray(cand)
    background = background_level(ref_gray, valid)
    ref_ink = ink_mask(ref_gray, background, valid)
    cand_ink = ink_mask(cand_gray, background_level(cand_gray, valid), valid)
    union_ink = ref_ink | cand_ink
    # Masked pixels read as background in both images so the shift search
    # never matches on (or is thrown by) excluded chrome.
    ref_search = np.where(valid, ref_gray, float(background))
    cand_search = np.where(valid, cand_gray, float(background))

    crops: list[Crop] = []
    crop_dir = out_dir / "crops"
    for index, (y0, y1) in enumerate(segment_rows(union_ink)):
        cols = np.flatnonzero(union_ink[y0:y1].any(axis=0))
        x0, x1 = int(cols[0]), int(cols[-1]) + 1
        box_valid = valid[y0:y1, x0:x1]
        box_count = int(box_valid.sum())
        pct = float(diff[y0:y1, x0:x1].sum()) / box_count * 100.0 if box_count else 0.0
        offset, residual = best_shift(ref_search, cand_search, y0, y1, args.search)
        has_ref = bool(ref_ink[y0:y1].any())
        has_cand = bool(cand_ink[y0:y1].any())
        crop_notes = []
        if not has_cand:
            crop_notes.append("missing in candidate")
        if not has_ref:
            crop_notes.append("extra in candidate")
        ok = pct <= crop_limit and abs(offset) <= args.max_offset_px and has_ref and has_cand
        crop = Crop(index, y0, y1, x0, x1, round(pct, 4), offset, round(residual, 2), has_ref, has_cand,
                    "PASS" if ok else "FAIL", "; ".join(crop_notes))
        crops.append(crop)
        if not ok:
            crop_dir.mkdir(parents=True, exist_ok=True)
            pad = 12
            py0, py1 = max(y0 - pad, 0), min(y1 + pad, height)
            px0, px1 = max(x0 - pad, 0), min(x1 + pad, width)
            overlay = diff_overlay(ref, diff, masked)
            triptych([ref[py0:py1, px0:px1], cand[py0:py1, px0:px1], overlay[py0:py1, px0:px1]],
                     f"{name} crop {index}: rows {y0}-{y1} {pct:.3f}% offset {offset:+d}px {crop.notes}",
                     crop_dir / f"{name}-c{index:02d}.png")

    # Marker / content crops: positions a percentage cannot see.
    ink_floor = 40.0
    ref_weight = np.clip(np.abs(ref_gray - background) - ink_floor, 0, None) * valid
    cand_weight = np.clip(np.abs(cand_gray - background_level(cand_gray, valid)) - ink_floor, 0, None) * valid
    markers: list[MarkerCrop] = []
    pad = 6
    row_blocks = segment_rows(union_ink)
    for block, (y0, y1) in enumerate(row_blocks):
        cols = np.flatnonzero(union_ink[y0:y1].any(axis=0))
        bx0, bx1 = int(cols[0]), int(cols[-1]) + 1
        above = row_blocks[block - 1][1] if block > 0 else 0
        below = row_blocks[block + 1][0] if block + 1 < len(row_blocks) else height
        splits = {}
        for label, ink in (("ref", ref_ink), ("cand", cand_ink)):
            found = split_marker(ink[y0:y1, bx0:bx1], args.marker_gap, args.marker_max_width)
            if found:
                splits[label] = tuple(v + bx0 for v in found)
        if not splits:
            continue
        mx0 = min(v[0] for v in splits.values())
        mx1 = max(v[1] for v in splits.values())
        cx0 = min(v[2] for v in splits.values())
        gutter_mid = (mx1 + cx0) // 2
        wy0, wy1 = max(y0 - pad, (above + y0) // 2), min(y1 + pad, (y1 + below + 1) // 2)
        mwx0, mwx1 = max(mx0 - pad, 0), min(mx1 + pad, gutter_mid)
        cwx0, cwx1 = max(gutter_mid, cx0 - pad), bx1
        notes_m: list[str] = []
        ref_m = ink_centroid(ref_weight, wy0, wy1, mwx0, mwx1)
        cand_m = ink_centroid(cand_weight, wy0, wy1, mwx0, mwx1)

        def line_centroid(weight: np.ndarray, ink: np.ndarray) -> tuple[float, float] | None:
            line = first_line(ink[y0:y1, cwx0:cwx1])
            if line is None:
                return None
            return ink_centroid(weight, y0 + line[0], y0 + line[1], cwx0, cwx1)

        ref_c = line_centroid(ref_weight, ref_ink)
        cand_c = line_centroid(cand_weight, cand_ink)
        big = float("inf")
        if ref_m is None or cand_m is None:
            notes_m.append("marker missing in " + ("candidate" if cand_m is None else "reference"))
        if ref_c is None or cand_c is None:
            notes_m.append("content missing in " + ("candidate" if cand_c is None else "reference"))
        mdx = mdy = cdx = cdy = rdy = big
        if ref_m and cand_m:
            mdx, mdy = cand_m[0] - ref_m[0], cand_m[1] - ref_m[1]
        if ref_c and cand_c:
            cdx, cdy = cand_c[0] - ref_c[0], cand_c[1] - ref_c[1]
        if ref_m and cand_m and ref_c and cand_c:
            rdy = (cand_m[1] - cand_c[1]) - (ref_m[1] - ref_c[1])
        # A split found in one image only is information: a gap near the
        # threshold can flip with anti-aliasing. A real extra or missing
        # marker fails above (empty window) or below (position, percent).
        info = [] if set(splits) == {"ref", "cand"} else [
            "split detected only in " + ("reference" if "ref" in splits else "candidate")]

        def box_pct(x0: int, x1: int) -> float:
            box = valid[wy0:wy1, x0:x1]
            count = int(box.sum())
            return float(diff[wy0:wy1, x0:x1].sum()) / count * 100.0 if count else 0.0

        mpct, cpct = box_pct(mwx0, mwx1), box_pct(cwx0, cwx1)
        deltas = [mdx, mdy, cdx, cdy, rdy]
        ok = (all(abs(d) <= args.max_position_px for d in deltas)
              and mpct <= crop_limit and cpct <= crop_limit and not notes_m)
        rounded = [round(d, 3) if d != big else 9999.0 for d in deltas]
        mc = MarkerCrop(len(markers), block, wy0, wy1, f"{mwx0},{wy0},{mwx1},{wy1}", f"{cwx0},{wy0},{cwx1},{wy1}",
                        "+".join(sorted(splits)), *rounded, round(mpct, 4), round(cpct, 4),
                        "PASS" if ok else "FAIL", "; ".join(notes_m + info))
        markers.append(mc)
        if not ok:
            crop_dir.mkdir(parents=True, exist_ok=True)
            py0, py1 = max(wy0 - 12, 0), min(wy1 + 12, height)
            px0, px1 = max(mwx0 - 12, 0), min(cwx1 + 12, width)
            overlay = diff_overlay(ref, diff, masked)
            triptych([ref[py0:py1, px0:px1], cand[py0:py1, px0:px1], overlay[py0:py1, px0:px1]],
                     f"{name} marker {mc.index}: marker d=({mc.marker_dx:+.2f},{mc.marker_dy:+.2f}) "
                     f"content d=({mc.content_dx:+.2f},{mc.content_dy:+.2f}) rel {mc.relative_dy:+.2f}px {mc.notes}",
                     crop_dir / f"{name}-m{mc.index:02d}.png")

    # Fill: low-contrast differences away from ink (row backgrounds).
    exact_only = build_mask(height, width, exact_rects, 0, 0) if exact_rects else np.zeros((height, width), dtype=bool)
    near_ink = dilate(union_ink, args.fill_ink_radius)
    fill = diff_mask(ref, cand, args.fill_threshold) & valid & ~exact_only & ~near_ink
    fill_px = int(fill.sum())
    fill_pct = fill_px / valid_count * 100.0
    fys, fxs = np.nonzero(fill)
    fill_bbox = f"{fxs.min()},{fys.min()},{fxs.max() + 1},{fys.max() + 1}" if fill_px else ""

    # Code boxes: chrome exact, geometry, code text percentage and displacement.
    stable = None
    if stable_path is not None and kind != "noise":
        stable = load_rgb(stable_path)
        if stable.shape[0] < height or stable.shape[1] < width:
            notes.append("code chrome: the A-A' capture is smaller than the reference (stability not measured)")
            stable = None
        else:
            stable = stable[:height, :width]
    code_crops, code_notes, code_extra = score_code_boxes(
        kind, name, ref, cand, stable, valid, exact_only, masked, diff, crop_limit, ref_ink, cand_ink,
        ref_weight, cand_weight, ref_search, cand_search, out_dir, args)
    notes += code_notes

    list_rule = next((rule for rule in args.list_pair if name.startswith(rule[0])), None)

    failing = [c for c in crops if c.verdict != "PASS"]
    max_crop_pct = max((c.pct for c in crops), default=0.0)
    max_abs_offset = max((abs(c.offset) for c in crops), default=0)
    last_offset = crops[-1].offset if crops else 0
    max_residual = max((c.residual for c in crops), default=0.0)
    verdict = "PASS"
    if not crops:
        notes.append("no text blocks found in the unmasked viewport")
        if not args.allow_empty:
            verdict = "INVALID"
    if not size_match:
        verdict = "FAIL"
    if viewport_pct > vp_limit:
        verdict = "FAIL"
        notes.append(f"viewport {viewport_px} px ({viewport_pct:.6f}%) > {vp_limit}%, bbox {diff_bbox}")
    if failing:
        verdict = "FAIL"
        notes.append(f"{len(failing)} crop(s) fail")
    failing_markers = [m for m in markers if m.verdict != "PASS"]
    if failing_markers:
        verdict = "FAIL"
        notes.append(f"{len(failing_markers)} marker crop(s) fail")
    if (list_rule is not None or owner_rules) and fill_pct > args.max_fill_pct:
        verdict = "FAIL"
        notes.append(f"fill {fill_px} px ({fill_pct:.4f}%) > {args.max_fill_pct}%, bbox {fill_bbox}")
    if list_rule is not None:
        if len(markers) < list_rule[1] and verdict != "FAIL":
            verdict = "INVALID"
            notes.append(f"list capture with {len(markers)} marker crop(s) < {list_rule[1]} required")
        elif len(markers) < list_rule[1]:
            notes.append(f"list capture with {len(markers)} marker crop(s) < {list_rule[1]} required")
    failing_code = [c for c in code_crops if c.verdict == "FAIL"]
    if failing_code or code_extra:
        verdict = "FAIL"
        if failing_code:
            notes.append(f"{len(failing_code)} code box(es) fail")
    # What makes a pair INVALID rather than PASS: a code crop that cannot be
    # judged, a code capture without its crops, a failed engine proof.
    unproven: list[str] = []
    unstable_code = [c for c in code_crops if c.verdict == "UNSTABLE"]
    if unstable_code:
        unproven.append(f"code chrome not exactly stable in A-A' in {len(unstable_code)} box(es) "
                        f"(header {sum(c.stable_header_px for c in unstable_code)} px, "
                        f"outline {sum(c.stable_outline_px for c in unstable_code)} px): "
                        "chrome rule not evaluated, not loosened")
    unmeasured_code = [c for c in code_crops if c.verdict == "UNMEASURED"]
    if unmeasured_code:
        unproven.append(f"code chrome stability not measured in {len(unmeasured_code)} box(es): no matching A-A' "
                        f"pair (this pair: header {sum(c.header_px for c in unmeasured_code)} px, "
                        f"outline {sum(c.outline_px for c in unmeasured_code)} px): chrome rule not evaluated")
    unscorable = [c for c in code_crops if c.verdict == "INVALID"]
    if unscorable:
        unproven.append(f"{len(unscorable)} code box(es) with a crop that has no scorable pixel")
    code_proof = code_geometry = ""
    if code_rule is not None:
        if len(code_crops) < args.code_min_boxes:
            unproven.append(f"code capture with {len(code_crops)} code box(es) < {args.code_min_boxes} required")
        if code_rule.cls == "positive" and not any(c.text_box and c.ref_ink and c.cand_ink for c in code_crops):
            unproven.append("positive code capture without a code text crop")
        if code_rule.engine == "none":
            if kind == "noise":
                code_proof = code_geometry = "not required (reference build: A-A')"
            else:
                code_proof = code_geometry = "absent"
                unproven.append("engine proof: candidate arm ran without -rendererStats; a declared code capture "
                                "cannot PASS without engine proof")
        else:
            lines, landed_at, log_problems = read_proof_log(code_rule)
            if log_problems:
                code_proof = code_geometry = "absent"
                unproven += [f"engine proof: {problem}" for problem in log_problems]
            else:
                proof_problems, code_proof = evaluate_code_proof(code_rule, lines, landed_at)
                unproven += [f"engine proof: {problem}" for problem in proof_problems]
                geometry_problems, code_geometry = evaluate_code_geometry(
                    code_rule, lines, landed_at, code_crops, cand_ink, (cand_shape[1], cand_shape[0]),
                    args.pixel_scale or max(1, round(width / 400)), args.top_band)
                unproven += [f"geometry: {problem}" for problem in geometry_problems]
    # Container and caption captures: the kind's engine proof, the
    # capture-time geometry and, on the candidate that ran TextKit 2, a text
    # crop over each tk2 owner's on-screen row.
    owner_crops: list[OwnerCrop] = []
    owner_proofs: list[str] = []
    owner_geometries: list[str] = []
    for rule in owner_rules:
        if rule.engine == "none":
            if kind == "noise":
                owner_proofs.append(f"{rule.kind}: not required (reference build: A-A')")
                owner_geometries.append(f"{rule.kind}: not required")
            else:
                owner_proofs.append(f"{rule.kind}: absent")
                owner_geometries.append(f"{rule.kind}: absent")
                unproven.append(f"{rule.kind} engine proof: candidate arm ran without -rendererStats; a declared "
                                f"{rule.kind} capture cannot PASS without engine proof")
            continue
        lines, landed_at, log_problems = read_proof_log(rule)
        if log_problems:
            owner_proofs.append(f"{rule.kind}: absent")
            owner_geometries.append(f"{rule.kind}: absent")
            unproven += [f"{rule.kind} engine proof: {problem}" for problem in log_problems]
            if rule.cls == "positive" and rule.engine == "textkit2":
                unproven.append(f"positive {rule.kind} capture without an owner text crop")
            continue
        proof_problems, proof = evaluate_code_proof(rule, lines, landed_at)
        unproven += [f"{rule.kind} engine proof: {problem}" for problem in proof_problems]
        geometry_problems, geometry, crop_rows, geo_scale = evaluate_owner_geometry(
            rule, lines, landed_at, (cand_shape[1], cand_shape[0]), args.top_band)
        unproven += [f"{rule.kind} geometry: {problem}" for problem in geometry_problems]
        owner_proofs.append(f"{rule.kind}: {proof}")
        owner_geometries.append(f"{rule.kind}: {geometry}")
        if rule.engine == "textkit2":
            owner_crops += score_owner_crops(
                rule, crop_rows, geo_scale, name, len(owner_crops), ref, cand, valid, masked, diff, crop_limit,
                ref_ink, cand_ink, ref_weight, cand_weight, ref_search, cand_search, out_dir, args)
            if rule.cls == "positive" and not any(c.kind == rule.kind and c.ref_ink and c.cand_ink
                                                  for c in owner_crops):
                unproven.append(f"positive {rule.kind} capture without an owner text crop")
    failing_owner = [c for c in owner_crops if c.verdict == "FAIL"]
    if failing_owner:
        verdict = "FAIL"
        notes.append(f"{len(failing_owner)} owner text crop(s) fail")
    unscorable_owner = [c for c in owner_crops if c.verdict == "INVALID"]
    if unscorable_owner:
        unproven.append(f"{len(unscorable_owner)} owner text crop(s) cannot be scored: "
                        + "; ".join(c.notes for c in unscorable_owner))
    if unproven:
        notes += unproven
        if verdict != "FAIL":
            verdict = "INVALID"
    position_values = [abs(v) for m in markers
                       for v in (m.marker_dx, m.marker_dy, m.content_dx, m.content_dy, m.relative_dy)]
    max_position = max(position_values, default=0.0)

    overlay = diff_overlay(ref, diff, masked)
    draw_img = Image.fromarray(overlay)
    draw = ImageDraw.Draw(draw_img, "RGBA")
    for c in crops:
        colour = (40, 160, 60, 255) if c.verdict == "PASS" else (240, 150, 20, 255)
        draw.rectangle((c.x0, c.y0, c.x1 - 1, c.y1 - 1), outline=colour)
        if c.offset:
            draw.text((c.x0 + 2, c.y0), f"{c.offset:+d}", fill=colour)
    for m in markers:
        colour = (40, 110, 220, 255) if m.verdict == "PASS" else (220, 40, 200, 255)
        x0, y0, x1, y1 = (int(v) for v in m.marker_box.split(","))
        draw.rectangle((x0, y0, x1 - 1, y1 - 1), outline=colour, width=2)
    for c in code_crops:
        colour = (0, 150, 170, 255) if c.verdict == "PASS" else (230, 90, 0, 255)
        x0, y0, x1, y1 = (int(v) for v in c.box.split(","))
        draw.rectangle((x0, y0, x1 - 1, y1 - 1), outline=colour, width=3)
        split = int(c.header_box.split(",")[3])
        draw.line((x0, split, x1 - 1, split), fill=colour, width=1)
    for c in owner_crops:
        colour = (150, 80, 220, 255) if c.verdict == "PASS" else (230, 90, 0, 255)
        x0, y0, x1, y1 = (int(v) for v in c.box.split(","))
        draw.rectangle((x0, y0, max(x1 - 1, x0), max(y1 - 1, y0)), outline=colour, width=2)
    triptych([ref, cand, np.asarray(draw_img)],
             f"{kind} {name}: viewport {viewport_pct:.4f}%  max crop {max_crop_pct:.3f}%  "
             f"max|offset| {max_abs_offset}px  markers {len(markers)} max|pos| {max_position:.2f}px  "
             f"code boxes {len(code_crops)}  "
             + (f"owner crops {len(owner_crops)}  " if owner_rules else "")
             + f"{verdict}    reference | candidate | difference",
             out_dir / f"{name}.sbs.png")

    return Score(kind, name, ref_path, cand_path, size_match, width, height,
                 round(float(masked.mean()) * 100.0, 2), round(viewport_pct, 6), round(viewport_pct_aa, 6),
                 viewport_px, viewport_px_aa, diff_bbox,
                 len(crops), len(failing), max_crop_pct, max_abs_offset, last_offset, max_residual,
                 verdict, "; ".join(notes), len(markers), len(failing_markers), round(max_position, 3),
                 fill_px, round(fill_pct, 6), fill_bbox, list_rule is not None,
                 code_boxes=len(code_crops),
                 failing_code_boxes=sum(1 for c in code_crops if c.verdict != "PASS"),
                 code_text_crops=sum(1 for c in code_crops if c.text_box),
                 max_code_shift=max((max(abs(c.dx), abs(c.dy)) for c in code_crops), default=0),
                 chrome_px=sum(c.header_px + c.outline_px for c in code_crops),
                 code_class=code_rule.cls if code_rule is not None else "",
                 code_proof=code_proof, code_geometry=code_geometry,
                 owner_class="+".join(rule.label for rule in owner_rules),
                 owner_proof=" | ".join(owner_proofs), owner_geometry=" | ".join(owner_geometries),
                 owner_crops=len(owner_crops), failing_owner_crops=sum(1 for c in owner_crops if c.verdict != "PASS"),
                 crop_details=crops, marker_details=markers, code_details=code_crops, owner_details=owner_crops)


CSV_FIELDS = ["kind", "name", "verdict", "viewport_pct", "viewport_pct_aa", "viewport_px", "viewport_px_aa",
              "diff_bbox", "crops", "failing_crops",
              "max_crop_pct", "max_abs_offset", "last_offset", "max_residual",
              "marker_crops", "failing_marker_crops", "max_position_delta", "list_pair",
              "fill_px", "fill_pct", "fill_bbox",
              "code_boxes", "failing_code_boxes", "code_text_crops", "max_code_shift", "chrome_px",
              "code_class", "code_proof", "code_geometry",
              "owner_class", "owner_crops", "failing_owner_crops", "owner_proof", "owner_geometry",
              "masked_pct", "size_match",
              "width", "height", "ref", "cand", "notes"]


def write_outputs(scores: list[Score], out_dir: Path, rects: list[tuple[int, int, int, int]],
                  exact_rects: list[tuple[int, int, int, int]], args: argparse.Namespace) -> None:
    with (out_dir / "scores.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for s in scores:
            writer.writerow({f: getattr(s, f) for f in CSV_FIELDS})

    settings = {
        "masks": [list(r) for r in rects], "exact_masks": [list(r) for r in exact_rects], "top_band": args.top_band, "bottom_band": args.bottom_band,
        "threshold": args.threshold, "exact_threshold": args.exact_threshold, "search": args.search,
        "max_noise_pct": args.max_noise_pct, "max_exact_pct": args.max_exact_pct,
        "max_raw_pct": args.max_raw_pct, "max_crop_pct": args.max_crop_pct, "max_offset_px": args.max_offset_px,
        "marker_gap": args.marker_gap, "marker_max_width": args.marker_max_width,
        "max_position_px": args.max_position_px,
        "list_pairs": [f"{prefix}:{count}" for prefix, count in args.list_pair],
        "fill_threshold": args.fill_threshold, "fill_ink_radius": args.fill_ink_radius,
        "max_fill_pct": args.max_fill_pct,
        "chrome_threshold": CHROME_THRESHOLD, "max_chrome_px": MAX_CHROME_PX,
        "code_search": args.code_search, "code_min_boxes": args.code_min_boxes,
        "code_fill": list(args.code_fill) if args.code_fill else "auto",
        "code_fill_tolerance": args.code_fill_tolerance, "pixel_scale": args.pixel_scale or "auto",
        "require_owner_proof": True,   # always on (the flag is accepted for old command lines)
        "code_captures": {name: {"class": rule.cls, "owners": [f"{owner}={engine}" for owner, engine in rule.owners],
                                 "land": rule.land, "engine": rule.engine, "log": rule.log}
                          for name, rule in args.code_rules.items()},
        "owner_captures": {name: {kind: {"class": rule.cls,
                                         "owners": [f"{owner}={engine}" for owner, engine in rule.owners],
                                         "land": rule.land, "engine": rule.engine, "log": rule.log}
                                  for kind, rule in kinds.items() if kind != "code"}
                           for name, kinds in args.capture_rules.items() if set(kinds) - {"code"}},
    }
    failed = [s for s in scores if s.verdict != "PASS"]
    # Native coverage: positive code captures whose candidate ran TextKit 2,
    # counted only when they PASS, which needs each tk2 owner's row to own a
    # scored code box at the screenshot (G3). Expected-fallback captures are
    # counted apart and never as coverage.
    on_textkit2 = [s for s in scores if s.name in args.code_rules and args.code_rules[s.name].engine == "textkit2"]
    positive = [s for s in on_textkit2 if s.code_class == "positive"]
    fallback = [s for s in on_textkit2 if s.code_class == "fallback"]
    coverage = {
        "positive_pairs": len(positive), "positive_pass": sum(1 for s in positive if s.verdict == "PASS"),
        "positive_geometry": sum(1 for s in positive if s.verdict == "PASS"),
        "fallback_pairs": len(fallback), "fallback_pass": sum(1 for s in fallback if s.verdict == "PASS"),
    }
    # The same per container and caption kind.
    owner_coverage: dict[str, dict[str, int]] = {}
    for owner_kind in CAPTURE_KINDS[1:]:
        declared = {name: kinds[owner_kind] for name, kinds in args.capture_rules.items() if owner_kind in kinds}
        native = [s for s in scores if s.name in declared and declared[s.name].engine == "textkit2"]
        if not declared:
            continue
        kind_positive = [s for s in native if declared[s.name].cls == "positive"]
        kind_fallback = [s for s in native if declared[s.name].cls == "fallback"]
        owner_coverage[owner_kind] = {
            "positive_pairs": len(kind_positive), "positive_pass": sum(1 for s in kind_positive if s.verdict == "PASS"),
            "fallback_pairs": len(kind_fallback), "fallback_pass": sum(1 for s in kind_fallback if s.verdict == "PASS"),
        }
    payload = {"overall": "FAIL" if failed else "PASS", "settings": settings, "code_coverage": coverage,
               "owner_coverage": owner_coverage, "pairs": [asdict(s) for s in scores]}
    (out_dir / "scores.json").write_text(json.dumps(payload, indent=2) + "\n")

    lines = [
        "# Visual parity",
        "",
        f"Pixel rule: noise/exact any channel |Δ| > {args.exact_threshold}; tolerant |Δ| > {args.threshold}. "
        f"Limits: noise ≤ {args.max_noise_pct}%, exact ≤ {args.max_exact_pct}%, tolerant viewport ≤ "
        f"{args.max_raw_pct}% and every crop ≤ {args.max_crop_pct}% with |offset| ≤ {args.max_offset_px}px. "
        f"Masks: {settings['masks'] or 'none'}; noise/exact-only masks: {settings['exact_masks'] or 'none'}; top band {args.top_band}px, bottom band {args.bottom_band}px. "
        f"No registration; shift search ±{args.search}px is diagnostic only. "
        f"Marker crops: first-line cluster <= {args.marker_max_width}px then a gap >= {args.marker_gap}px; "
        f"marker/content/relative position |Δ| <= {args.max_position_px}px. "
        f"List pairs ({', '.join(settings['list_pairs']) or 'none'}): need their minimum marker crops and "
        f"fill (|Δ| > {args.fill_threshold}, > {args.fill_ink_radius}px from ink) <= {args.max_fill_pct}%. "
        f"Code boxes (every pair): header strip and outline {MAX_CHROME_PX} px differing at channel threshold "
        f"{CHROME_THRESHOLD} (after A–A′ is exactly stable there); same box rectangle; code text within the "
        f"kind's crop limit with every line displaced <= {args.max_offset_px}px in x and in y (2-D search "
        f"±{args.code_search}px) and its ink centroid <= {args.max_position_px}px. "
        f"Code captures ({len(args.code_rules)} declared): >= {args.code_min_boxes} code box(es), a code text "
        f"crop when positive, the owner-level engine proof after SCROLL_LANDED, and the capture-time geometry "
        f"(CAPTURE_GEOMETRY before and after the screenshot: each tk2 owner's on-screen row holds a scored box's "
        f"code ink, no TextKit 2 code row over a fallback capture's boxes, the landing measured). "
        f"Container and caption captures ({sum(len(set(k) - {'code'}) for k in args.capture_rules.values())} "
        f"declared): the kind's owner-level engine proof after SCROLL_LANDED, the capture-time geometry (each "
        f"tk2 owner's non-code row shown with its ink, no TextKit 2 row for a swiftui owner, the landing "
        f"measured), on arm C a text crop over each tk2 owner's on-screen row, held to the code text rule, and "
        f"fill <= {args.max_fill_pct}% as for list pairs.",
        "",
        "| kind | pair | verdict | viewport % (px) | viewport % (aa) | crops (fail) | max crop % | "
        "max \\|offset\\| px | last px | markers (fail) | max \\|pos Δ\\| px | fill px | "
        "code boxes (fail) | code class: proof | code geometry | owner crops (fail) | owner class: proof | "
        "owner geometry | notes |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|---|---|---|",
    ]
    for s in scores:
        fill_cell = f"{s.fill_px}" + ("" if s.list_pair or s.owner_class else " (info)")
        lines.append(f"| {s.kind} | {s.name} | **{s.verdict}** | {s.viewport_pct:.4f} ({s.viewport_px}) | "
                     f"{s.viewport_pct_aa:.4f} ({s.viewport_px_aa}) | "
                     f"{s.crops} ({s.failing_crops}) | {s.max_crop_pct:.3f} | {s.max_abs_offset} | "
                     f"{s.last_offset:+d} | {s.marker_crops} ({s.failing_marker_crops}) | "
                     f"{s.max_position_delta:.2f} | {fill_cell} | "
                     f"{s.code_boxes} ({s.failing_code_boxes}) | "
                     f"{(s.code_class + ': ' + s.code_proof) if s.code_class else ''} | {s.code_geometry} | "
                     f"{f'{s.owner_crops} ({s.failing_owner_crops})' if s.owner_class else ''} | "
                     f"{(s.owner_class + ': ' + s.owner_proof) if s.owner_class else ''} | {s.owner_geometry} | "
                     f"{s.notes} |")
    bad_crops = [(s, c) for s in scores for c in s.crop_details if c.verdict != "PASS"]
    if bad_crops:
        lines += ["", "## Failing crops", "",
                  "| pair | crop | rows | cols | % | offset px | residual | notes |",
                  "|---|---:|---|---|---:|---:|---:|---|"]
        for s, c in bad_crops:
            lines.append(f"| {s.name} | {c.index} | {c.y0}–{c.y1} | {c.x0}–{c.x1} | {c.pct:.3f} | "
                         f"{c.offset:+d} | {c.residual:.2f} | {c.notes} |")
    bad_markers = [(s, m) for s in scores for m in s.marker_details if m.verdict != "PASS"]
    if bad_markers:
        lines += ["", "## Failing marker crops", "",
                  "| pair | marker | rows | marker Δx,Δy | content Δx,Δy | relative Δy | marker % | content % | notes |",
                  "|---|---:|---|---|---|---:|---:|---:|---|"]
        for s, m in bad_markers:
            lines.append(f"| {s.name} | {m.index} | {m.y0}–{m.y1} | {m.marker_dx:+.2f},{m.marker_dy:+.2f} | "
                         f"{m.content_dx:+.2f},{m.content_dy:+.2f} | {m.relative_dy:+.2f} | {m.marker_pct:.3f} | "
                         f"{m.content_pct:.3f} | {m.notes} |")
    bad_code = [(s, c) for s in scores for c in s.code_details if c.verdict != "PASS"]
    if bad_code:
        lines += ["", "## Failing code boxes", "",
                  "| pair | box | verdict | owner | rect | geometry | header px (A–A′) | outline px (A–A′) | "
                  "text % | lines | shift x,y px | centroid Δx,Δy | notes |",
                  "|---|---:|---|---|---|---|---:|---:|---:|---:|---|---|---|"]
        for s, c in bad_code:
            lines.append(f"| {s.name} | {c.index} | {c.verdict} | {c.owner or '-'} | {c.box} | {c.geometry} | "
                         f"{c.header_px} ({'n/a' if c.stable_header_px < 0 else c.stable_header_px}) | "
                         f"{c.outline_px} ({'n/a' if c.stable_outline_px < 0 else c.stable_outline_px}) | "
                         f"{c.text_pct:.3f} | {c.lines} | {c.dx:+d},{c.dy:+d} | "
                         f"{c.centroid_dx:+.2f},{c.centroid_dy:+.2f} | {c.notes} |")
    bad_owner = [(s, c) for s in scores for c in s.owner_details if c.verdict != "PASS"]
    if bad_owner:
        lines += ["", "## Failing owner text crops", "",
                  "| pair | crop | kind | owner | verdict | frame | text box | text % | lines | shift x,y px | "
                  "centroid Δx,Δy | notes |",
                  "|---|---:|---|---|---|---|---|---:|---:|---|---|---|"]
        for s, c in bad_owner:
            lines.append(f"| {s.name} | {c.index} | {c.kind} | {c.owner} | {c.verdict} | {c.box} | {c.text_box or '-'} | "
                         f"{c.text_pct:.3f} | {c.lines} | {c.dx:+d},{c.dy:+d} | "
                         f"{c.centroid_dx:+.2f},{c.centroid_dy:+.2f} | {c.notes} |")
    for owner_kind, counts in owner_coverage.items():
        lines += ["", f"{owner_kind.capitalize()} coverage (candidate on TextKit 2): {counts['positive_pass']}/"
                  f"{counts['positive_pairs']} positive {owner_kind} captures PASS (each tk2 owner's row shown with "
                  f"its ink and its text crop within the code text rule); {counts['fallback_pass']}/"
                  f"{counts['fallback_pairs']} expected-fallback captures PASS (never native coverage)."
                  + ("" if counts["positive_pairs"] else f" **No positive native {owner_kind} coverage in this run.**")]
    if args.code_rules:
        lines += ["", f"Code coverage (candidate on TextKit 2): {coverage['positive_pass']}/{coverage['positive_pairs']} "
                  f"positive code captures PASS (each with its owners' rows holding scored code pixels at the "
                  f"screenshot); "
                  f"{coverage['fallback_pass']}/{coverage['fallback_pairs']} expected-fallback captures PASS "
                  "(a fallback capture is never native coverage)."
                  + ("" if coverage["positive_pairs"] else " **No positive native code coverage in this run.**")]
    lines += ["", f"**{payload['overall']}** — {len(scores) - len(failed)}/{len(scores)} pairs within limits.", ""]
    (out_dir / "summary.md").write_text("\n".join(lines))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--pair", nargs=4, action="append", metavar=("KIND", "NAME", "REF", "CAND"), required=True,
                        help="KIND is noise | exact | tolerant")
    parser.add_argument("--mask", action="append", default=[], metavar="x0,y0,x1,y1")
    parser.add_argument("--exact-mask", action="append", default=[], metavar="x0,y0,x1,y1",
                        help="excluded from noise/exact pairs only")
    parser.add_argument("--top-band", type=int, default=0, help="rows excluded at the top")
    parser.add_argument("--bottom-band", type=int, default=0, help="rows excluded at the bottom")
    parser.add_argument("--threshold", type=int, default=24, help="tolerant pixel rule: per-channel |Δ| above this")
    parser.add_argument("--exact-threshold", type=int, default=0, help="noise/exact pixel rule (default 0)")
    parser.add_argument("--search", type=int, default=100, help="vertical shift search range in px")
    parser.add_argument("--max-noise-pct", type=float, default=0.0)
    parser.add_argument("--max-exact-pct", type=float, default=0.0)
    parser.add_argument("--max-raw-pct", type=float, default=0.5)
    parser.add_argument("--max-crop-pct", type=float, default=0.5)
    parser.add_argument("--max-offset-px", type=int, default=0)
    parser.add_argument("--allow-empty", action="store_true",
                        help="a pair with no text crops may PASS (default: INVALID)")
    parser.add_argument("--marker-gap", type=int, default=27,
                        help="min ink-free gap (px) between a first-line marker cluster and its content")
    parser.add_argument("--marker-max-width", type=int, default=180, help="max marker cluster width (px)")
    parser.add_argument("--max-position-px", type=float, default=0.5,
                        help="max |shift| of marker / first-line centroids and of their relative position")
    parser.add_argument("--list-pair", action="append", default=[], metavar="NAME_PREFIX[:MIN_MARKERS]",
                        help="pairs named with this prefix need MIN_MARKERS marker crops (default 1) and pass the fill check")
    parser.add_argument("--fill-threshold", type=int, default=6, help="fill pixel rule: per-channel |Δ| above this")
    parser.add_argument("--fill-ink-radius", type=int, default=4, help="fill ignores pixels this close to ink")
    parser.add_argument("--max-fill-pct", type=float, default=0.01, help="list pairs and container/caption captures: max fill %% of the viewport")
    parser.add_argument("--code-capture", nargs=5, action="append", default=[],
                        metavar=("NAME", "CLASS", "OWNERS", "ENGINE", "LOG"),
                        help="declare pair NAME a capture: CLASS [code|container|caption:]positive | fallback "
                             "(no kind: code); OWNERS <owner>=<tk2|swiftui>[,...];land=<block id>; ENGINE "
                             "textkit2 | swiftui | none (noise pairs only); LOG the candidate's launch log (- with "
                             "none). One declaration per pair and kind")
    parser.add_argument("--require-owner-proof", action="store_true",
                        help="accepted for old command lines; the owner-level proof (TK2_CODE_ROWS) and the "
                             "capture-time geometry are always required")
    parser.add_argument("--code-min-boxes", type=int, default=1, help="code boxes a code capture must show")
    parser.add_argument("--code-search", type=int, default=4, help="code line shift search range in px, both axes")
    parser.add_argument("--code-fill", default="auto", metavar="auto|R,G,B",
                        help="code box fill colour (auto: the page background blended 10 %% toward system grey)")
    parser.add_argument("--code-fill-tolerance", type=int, default=1, help="per-channel tolerance of the fill colour")
    parser.add_argument("--pixel-scale", type=int, default=0,
                        help="pixels per point (0: round(width / 400), 3 for a 1206 px capture)")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exit_:
        return 0 if exit_.code == 0 else 2

    try:
        for kind, name, ref, cand in args.pair:
            if kind not in KINDS:
                raise InputError(f"pair {name}: unknown kind '{kind}' (want {' | '.join(KINDS)})")
            load_rgb(ref)
            load_rgb(cand)
        if args.top_band < 0 or args.bottom_band < 0:
            raise InputError("bands must be >= 0")
        rules = []
        for item in args.list_pair:
            prefix, _, count = item.partition(":")
            if not prefix or (count and not count.isdigit()):
                raise InputError(f"bad --list-pair '{item}' (want NAME_PREFIX[:MIN_MARKERS])")
            rules.append((prefix, int(count) if count else 1))
        args.list_pair = rules
        args.capture_rules = parse_captures(args.code_capture, {name for _, name, _, _ in args.pair})
        args.code_rules = {name: kinds["code"] for name, kinds in args.capture_rules.items() if "code" in kinds}
        if args.code_fill == "auto":
            args.code_fill = None
        else:
            try:
                args.code_fill = tuple(int(v) for v in args.code_fill.split(","))
            except ValueError:
                args.code_fill = ()
            if len(args.code_fill) != 3 or not all(0 <= v <= 255 for v in args.code_fill):
                raise InputError("bad --code-fill (want auto or R,G,B in 0-255)")
        if args.code_min_boxes < 0 or args.code_search < 0 or args.code_fill_tolerance < 0 or args.pixel_scale < 0:
            raise InputError("--code-min-boxes, --code-search, --code-fill-tolerance and --pixel-scale must be >= 0")
        # The A' capture of each reference: code chrome is exact between A
        # and C only where A-A' is exactly stable.
        stable_for = {ref: cand for kind, _, ref, cand in args.pair if kind == "noise"}
        rects = [parse_mask(m) for m in args.mask]
        exact_rects = [parse_mask(m) for m in args.exact_mask]
        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        scores = [score_pair(kind, name, ref, cand, out_dir, rects, exact_rects, args,
                             args.code_rules.get(name), stable_for.get(ref),
                             tuple(rule for rule_kind, rule in sorted(args.capture_rules.get(name, {}).items(),
                                                                       key=lambda item: CAPTURE_KINDS.index(item[0]))
                                   if rule_kind != "code"))
                  for kind, name, ref, cand in args.pair]
    except InputError as error:
        print(f"visual_diff: error: {error}", file=sys.stderr)
        return 2

    write_outputs(scores, out_dir, rects, exact_rects, args)
    for s in scores:
        print(f"{s.verdict}  {s.kind:8s} {s.name}: viewport {s.viewport_pct:.4f}% / {s.viewport_px} px "
              f"(aa {s.viewport_pct_aa:.4f}% / {s.viewport_px_aa} px)  "
              f"crops {s.crops} fail {s.failing_crops}  max crop {s.max_crop_pct:.3f}%  "
              f"max|offset| {s.max_abs_offset}px  markers {s.marker_crops} fail {s.failing_marker_crops}  "
              f"max|pos| {s.max_position_delta:.2f}px  fill {s.fill_px} px  "
              f"code boxes {s.code_boxes} fail {s.failing_code_boxes}"
              f"{'  ' + s.code_class + ' [' + s.code_proof + '] {' + s.code_geometry + '}' if s.code_class else ''}"
              f"{'  ' + s.owner_class + ' [' + s.owner_proof + '] {' + s.owner_geometry + '}' if s.owner_class else ''}"
              f"  {s.notes}")
    print(f"wrote {out_dir / 'scores.csv'}, {out_dir / 'scores.json'} and {out_dir / 'summary.md'}")
    return 1 if any(s.verdict != "PASS" for s in scores) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
