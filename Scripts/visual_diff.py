#!/usr/bin/env python3
"""Score screenshot pairs for visual parity (reference vs candidate).

USAGE
    python3 -I Scripts/visual_diff.py --out <dir> --pair <name> <ref.png> <cand.png>
        [--pair ...] [--top-band 186] [--bottom-band 102] [--threshold 24]
        [--search 100] [--max-raw-pct 0.5] [--max-offset-px 0]

    Driven by Scripts/visual-parity.sh; runs standalone on any two PNGs.
    Requires Pillow and numpy only.

METRICS (per pair, both images cropped to the rows between the bands)
    raw_pct         % of pixels whose R, G or B differs by more than
                    --threshold (default 24, i.e. anti-aliasing noise is
                    ignored, a moved glyph is not)
    blocks          text blocks found in the reference: rows containing ink
                    (pixels far from the background colour) grouped into
                    runs, gaps of up to 4 rows allowed
    max_abs_offset  largest |vertical shift| (px) over all blocks, where a
                    block's shift is the s in ±--search that best aligns the
                    reference rows with the candidate (minimum mean absolute
                    grey difference, nearest-to-zero wins ties)
    last_offset     the shift of the last block — cumulative drift shows up
                    here even when every single block only moves a little
    residual        the mean absolute grey difference at the best shift for
                    the worst-aligned block (large = content changed, not
                    merely moved)

VERDICT  PASS when raw_pct <= --max-raw-pct and max_abs_offset <=
    --max-offset-px and the images have the same size; FAIL otherwise.

OUTPUTS (in --out)
    <name>.sbs.png   reference | candidate | difference map, side by side
    scores.csv       one row per pair
    summary.md       the same as a Markdown table with a PASS/FAIL per pair
Exit status 1 when any pair FAILs.
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


@dataclass
class Score:
    name: str
    ref: str
    cand: str
    size_match: bool
    raw_pct: float
    blocks: int
    max_abs_offset: int
    last_offset: int
    residual: float
    verdict: str
    notes: str


def load_rgb(path: str) -> np.ndarray:
    with Image.open(path) as image:
        return np.asarray(image.convert("RGB"))


def to_gray(rgb: np.ndarray) -> np.ndarray:
    return rgb.astype(np.float32) @ np.array([0.299, 0.587, 0.114], dtype=np.float32)


def raw_diff_mask(a: np.ndarray, b: np.ndarray, threshold: int) -> np.ndarray:
    delta = np.abs(a.astype(np.int16) - b.astype(np.int16)).max(axis=2)
    return delta > threshold


def ink_mask(gray: np.ndarray, ink_threshold: float = 40.0) -> np.ndarray:
    """Pixels far from the dominant (background) grey level — works for light
    and dark appearance alike."""
    histogram = np.bincount(np.clip(gray, 0, 255).astype(np.uint8).ravel(), minlength=256)
    background = int(histogram.argmax())
    return np.abs(gray - background) > ink_threshold


def segment_blocks(ink: np.ndarray, min_rows: int = 3, max_gap: int = 4, min_ink: int = 2) -> list[tuple[int, int]]:
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
    for s in sorted(range(-search, search + 1), key=abs):
        c0, c1 = y0 + s, y1 + s
        if c0 < 0 or c1 > height:
            continue
        mad = float(np.abs(band - cand_gray[c0:c1]).mean())
        if mad < best_mad:
            best_s, best_mad = s, mad
    return best_s, best_mad


def side_by_side(ref: np.ndarray, cand: np.ndarray, diff: np.ndarray, top: int, bottom: int,
                 blocks: list[tuple[int, int]], offsets: list[int], path: Path, caption: str) -> None:
    height, width = ref.shape[:2]
    gutter = 12
    canvas = Image.new("RGB", (width * 3 + gutter * 2, height + 48), (40, 40, 40))
    canvas.paste(Image.fromarray(ref), (0, 48))
    canvas.paste(Image.fromarray(cand), (width + gutter, 48))

    # Difference map: dimmed reference with differing pixels in red.
    base = (to_gray(ref) * 0.35 + 140).astype(np.uint8)
    diff_rgb = np.stack([base, base, base], axis=2)
    diff_rgb[diff] = (230, 30, 30)
    diff_image = Image.fromarray(diff_rgb)
    draw = ImageDraw.Draw(diff_image, "RGBA")
    draw.rectangle((0, 0, width, top), fill=(0, 0, 0, 90))
    draw.rectangle((0, height - bottom, width, height), fill=(0, 0, 0, 90))
    for (y0, y1), offset in zip(blocks, offsets):
        colour = (40, 160, 60, 255) if offset == 0 else (240, 150, 20, 255)
        draw.rectangle((2, y0 + top, 14, y1 + top), fill=colour)
        if offset:
            draw.text((18, y0 + top), f"{offset:+d}", fill=colour)
    canvas.paste(diff_image, (2 * (width + gutter), 48))

    header = ImageDraw.Draw(canvas)
    header.text((8, 14), f"{caption}    reference | candidate | difference (red = changed, bars = block offset)",
                fill=(255, 255, 255))
    canvas.save(path, optimize=True)


def score_pair(name: str, ref_path: str, cand_path: str, out_dir: Path, args: argparse.Namespace) -> Score:
    ref = load_rgb(ref_path)
    cand = load_rgb(cand_path)
    notes: list[str] = []
    size_match = ref.shape == cand.shape
    if not size_match:
        notes.append(f"size mismatch ref {ref.shape[1]}x{ref.shape[0]} vs cand {cand.shape[1]}x{cand.shape[0]}")
        h = min(ref.shape[0], cand.shape[0])
        w = min(ref.shape[1], cand.shape[1])
        ref, cand = ref[:h, :w], cand[:h, :w]

    height = ref.shape[0]
    top, bottom = args.top_band, args.bottom_band
    if top + bottom >= height:
        raise SystemExit(f"{name}: bands ({top}+{bottom}) cover the whole {height}px image")
    region = slice(top, height - bottom)
    ref_region, cand_region = ref[region], cand[region]

    diff = raw_diff_mask(ref_region, cand_region, args.threshold)
    raw_pct = float(diff.mean() * 100.0)

    ref_gray, cand_gray = to_gray(ref_region), to_gray(cand_region)
    blocks = segment_blocks(ink_mask(ref_gray))
    offsets: list[int] = []
    residual = 0.0
    for y0, y1 in blocks:
        shift, mad = best_shift(ref_gray, cand_gray, y0, y1, args.search)
        offsets.append(shift)
        residual = max(residual, mad)
    max_abs_offset = max((abs(o) for o in offsets), default=0)
    last_offset = offsets[-1] if offsets else 0
    if not blocks:
        notes.append("no text blocks found in reference")

    verdict = "PASS"
    if not size_match:
        verdict = "FAIL"
    if raw_pct > args.max_raw_pct:
        verdict = "FAIL"
        notes.append(f"raw {raw_pct:.3f}% > {args.max_raw_pct}%")
    if max_abs_offset > args.max_offset_px:
        verdict = "FAIL"
        notes.append(f"offset {max_abs_offset}px > {args.max_offset_px}px")

    side_by_side(ref, cand, np.pad(diff, ((top, bottom), (0, 0))), top, bottom, blocks, offsets,
                 out_dir / f"{name}.sbs.png", f"{name}: raw {raw_pct:.3f}%  max|offset| {max_abs_offset}px  {verdict}")

    return Score(name, ref_path, cand_path, size_match, round(raw_pct, 4), len(blocks),
                 max_abs_offset, last_offset, round(residual, 2), verdict, "; ".join(notes))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", required=True, help="output directory")
    parser.add_argument("--pair", nargs=3, action="append", metavar=("NAME", "REF", "CAND"), required=True)
    parser.add_argument("--top-band", type=int, default=186, help="rows excluded at the top (status + nav bar, 3x px)")
    parser.add_argument("--bottom-band", type=int, default=102, help="rows excluded at the bottom (home indicator, 3x px)")
    parser.add_argument("--threshold", type=int, default=24, help="per-channel |delta| above which a pixel differs")
    parser.add_argument("--search", type=int, default=100, help="vertical shift search range in px")
    parser.add_argument("--max-raw-pct", type=float, default=0.5)
    parser.add_argument("--max-offset-px", type=int, default=0)
    args = parser.parse_args(argv)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    scores = [score_pair(name, ref, cand, out_dir, args) for name, ref, cand in args.pair]

    fields = ["name", "verdict", "raw_pct", "blocks", "max_abs_offset", "last_offset", "residual",
              "size_match", "ref", "cand", "notes"]
    with (out_dir / "scores.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for s in scores:
            writer.writerow({f: getattr(s, f) for f in fields})

    lines = [
        "# Visual parity",
        "",
        f"Thresholds: raw ≤ {args.max_raw_pct}% of pixels (|Δ| > {args.threshold} on any channel), "
        f"max |offset| ≤ {args.max_offset_px}px; bands excluded: top {args.top_band}px, bottom {args.bottom_band}px; "
        f"shift search ±{args.search}px.",
        "",
        "| pair | verdict | raw % | blocks | max \\|offset\\| px | last block px | residual | notes |",
        "|---|---|---:|---:|---:|---:|---:|---|",
    ]
    for s in scores:
        lines.append(f"| {s.name} | **{s.verdict}** | {s.raw_pct:.3f} | {s.blocks} | {s.max_abs_offset} | "
                     f"{s.last_offset:+d} | {s.residual:.2f} | {s.notes} |")
    failed = [s for s in scores if s.verdict != "PASS"]
    lines += ["", f"**{'FAIL' if failed else 'PASS'}** — {len(scores) - len(failed)}/{len(scores)} pairs within thresholds.", ""]
    (out_dir / "summary.md").write_text("\n".join(lines))

    for s in scores:
        print(f"{s.verdict}  {s.name}: raw {s.raw_pct:.3f}%  blocks {s.blocks}  max|offset| {s.max_abs_offset}px  "
              f"last {s.last_offset:+d}px  residual {s.residual:.2f}  {s.notes}")
    print(f"wrote {out_dir / 'scores.csv'} and {out_dir / 'summary.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
