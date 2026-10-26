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
                     pixel rule
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

OUTPUTS (in --out)
    <name>.sbs.png          reference | candidate | difference map
    crops/<name>-cNN.png    each failing crop: reference | candidate | diff
    scores.csv              one row per pair
    scores.json             every pair with its crops
    summary.md              pair table + failing-crop table

EXIT STATUS  0 every pair PASS, 1 any pair FAIL, 2 usage/input error
    (unreadable or missing image, bad mask, bands covering the image).
"""

from __future__ import annotations

import argparse
import csv
import json
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
    crops: int
    failing_crops: int
    max_crop_pct: float
    max_abs_offset: int
    last_offset: int
    max_residual: float
    verdict: str
    notes: str
    crop_details: list[Crop] = field(default_factory=list)


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


def score_pair(kind: str, name: str, ref_path: str, cand_path: str, out_dir: Path,
               rects: list[tuple[int, int, int, int]], exact_rects: list[tuple[int, int, int, int]],
               args: argparse.Namespace) -> Score:
    ref = load_rgb(ref_path)
    cand = load_rgb(cand_path)
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
    viewport_pct = float(diff.sum()) / valid_count * 100.0
    viewport_pct_aa = float(diff_aa.sum()) / valid_count * 100.0
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

    failing = [c for c in crops if c.verdict != "PASS"]
    max_crop_pct = max((c.pct for c in crops), default=0.0)
    max_abs_offset = max((abs(c.offset) for c in crops), default=0)
    last_offset = crops[-1].offset if crops else 0
    max_residual = max((c.residual for c in crops), default=0.0)
    if not crops:
        notes.append("no text blocks found in the unmasked viewport")

    verdict = "PASS"
    if not size_match:
        verdict = "FAIL"
    if viewport_pct > vp_limit:
        verdict = "FAIL"
        notes.append(f"viewport {viewport_pct:.4f}% > {vp_limit}%")
    if failing:
        verdict = "FAIL"
        notes.append(f"{len(failing)} crop(s) fail")

    overlay = diff_overlay(ref, diff, masked)
    draw_img = Image.fromarray(overlay)
    draw = ImageDraw.Draw(draw_img, "RGBA")
    for c in crops:
        colour = (40, 160, 60, 255) if c.verdict == "PASS" else (240, 150, 20, 255)
        draw.rectangle((c.x0, c.y0, c.x1 - 1, c.y1 - 1), outline=colour)
        if c.offset:
            draw.text((c.x0 + 2, c.y0), f"{c.offset:+d}", fill=colour)
    triptych([ref, cand, np.asarray(draw_img)],
             f"{kind} {name}: viewport {viewport_pct:.4f}%  max crop {max_crop_pct:.3f}%  "
             f"max|offset| {max_abs_offset}px  {verdict}    reference | candidate | difference",
             out_dir / f"{name}.sbs.png")

    return Score(kind, name, ref_path, cand_path, size_match, width, height,
                 round(float(masked.mean()) * 100.0, 2), round(viewport_pct, 4), round(viewport_pct_aa, 4),
                 len(crops), len(failing), max_crop_pct, max_abs_offset, last_offset, max_residual,
                 verdict, "; ".join(notes), crops)


CSV_FIELDS = ["kind", "name", "verdict", "viewport_pct", "viewport_pct_aa", "crops", "failing_crops",
              "max_crop_pct", "max_abs_offset", "last_offset", "max_residual", "masked_pct", "size_match",
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
    }
    failed = [s for s in scores if s.verdict != "PASS"]
    payload = {"overall": "FAIL" if failed else "PASS", "settings": settings,
               "pairs": [asdict(s) for s in scores]}
    (out_dir / "scores.json").write_text(json.dumps(payload, indent=2) + "\n")

    lines = [
        "# Visual parity",
        "",
        f"Pixel rule: noise/exact any channel |Δ| > {args.exact_threshold}; tolerant |Δ| > {args.threshold}. "
        f"Limits: noise ≤ {args.max_noise_pct}%, exact ≤ {args.max_exact_pct}%, tolerant viewport ≤ "
        f"{args.max_raw_pct}% and every crop ≤ {args.max_crop_pct}% with |offset| ≤ {args.max_offset_px}px. "
        f"Masks: {settings['masks'] or 'none'}; noise/exact-only masks: {settings['exact_masks'] or 'none'}; top band {args.top_band}px, bottom band {args.bottom_band}px. "
        f"No registration; shift search ±{args.search}px is diagnostic only.",
        "",
        "| kind | pair | verdict | viewport % | viewport % (aa) | crops (fail) | max crop % | "
        "max \\|offset\\| px | last px | notes |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for s in scores:
        lines.append(f"| {s.kind} | {s.name} | **{s.verdict}** | {s.viewport_pct:.4f} | {s.viewport_pct_aa:.4f} | "
                     f"{s.crops} ({s.failing_crops}) | {s.max_crop_pct:.3f} | {s.max_abs_offset} | "
                     f"{s.last_offset:+d} | {s.notes} |")
    bad_crops = [(s, c) for s in scores for c in s.crop_details if c.verdict != "PASS"]
    if bad_crops:
        lines += ["", "## Failing crops", "",
                  "| pair | crop | rows | cols | % | offset px | residual | notes |",
                  "|---|---:|---|---|---:|---:|---:|---|"]
        for s, c in bad_crops:
            lines.append(f"| {s.name} | {c.index} | {c.y0}–{c.y1} | {c.x0}–{c.x1} | {c.pct:.3f} | "
                         f"{c.offset:+d} | {c.residual:.2f} | {c.notes} |")
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
        rects = [parse_mask(m) for m in args.mask]
        exact_rects = [parse_mask(m) for m in args.exact_mask]
        out_dir = Path(args.out)
        out_dir.mkdir(parents=True, exist_ok=True)
        scores = [score_pair(kind, name, ref, cand, out_dir, rects, exact_rects, args) for kind, name, ref, cand in args.pair]
    except InputError as error:
        print(f"visual_diff: error: {error}", file=sys.stderr)
        return 2

    write_outputs(scores, out_dir, rects, exact_rects, args)
    for s in scores:
        print(f"{s.verdict}  {s.kind:8s} {s.name}: viewport {s.viewport_pct:.4f}% (aa {s.viewport_pct_aa:.4f}%)  "
              f"crops {s.crops} fail {s.failing_crops}  max crop {s.max_crop_pct:.3f}%  "
              f"max|offset| {s.max_abs_offset}px  {s.notes}")
    print(f"wrote {out_dir / 'scores.csv'}, {out_dir / 'scores.json'} and {out_dir / 'summary.md'}")
    return 1 if any(s.verdict != "PASS" for s in scores) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
