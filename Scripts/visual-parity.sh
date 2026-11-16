#!/usr/bin/env bash
# Scripts/visual-parity.sh — document-level visual gate: captures screenshots
# of a reference ADFReader build (a Release build of main) and of this
# branch's build on ONE iOS Simulator, then scores them with
# Scripts/visual_diff.py (content viewport only; chrome masked).
#
# USAGE
#   Scripts/visual-parity.sh --udid <UDID> --ref-app <main ADFReader.app>
#       --app <branch ADFReader.app> [--out <dir>]
#       [--fixture <name>[@<f1>,<f2>...]]... [--appearances "light dark"]
#       [--list-fixture <name>[:<min markers>]]... [--allow-other-booted]
#       [--code-capture <declaration>]... [--no-code-captures]
#       [--require-owner-proof (accepted; always on)]
#       [--size-steps "0 3"] [--arms "A A2 B C"] [--content-size large]
#       [--settle 3] [--scroll-wait 2] [--ready-timeout 90]
#       [--mask x0,y0,x1,y1]... [--top-band 330] [--bottom-band 102]
#       [--exact-mask x0,y0,x1,y1]... [--no-exact-mask]
#       [--threshold 24] [--max-noise-pct 0] [--max-exact-pct 0]
#       [--max-raw-pct 0.5] [--max-crop-pct 0.5] [--max-offset-px 0]
#       [--no-renderer-stats] [--keep-booted] [--skip-capture] [--dry-run]
#
# ARMS (per fixture × position × appearance × size step)
#   A   --ref-app, plain launch                          (reference)
#   A2  --ref-app again, same procedure                  (capture noise)
#   B   --app with -rendererReset                        (SwiftUI text)
#   C   --app with -rendererReset -textkit2              (TextKit 2 text)
#   B and C also get -rendererStats -captureGeometryHook and must print
#   `RENDERER_STATS renderer=swiftui|textkit2 …` matching the arm (proof of
#   which renderer ran). --no-renderer-stats drops both flags and the check,
#   and is refused while any code capture is declared (every declared code
#   capture needs the engine proof): add --no-code-captures with it.
#   Every arm gets `-fixture <f> -scrollToFraction <pos> -fontSizeStep <n>`.
#   Arms are .app directories: --ref-app for A/A2 (main, or "main +
#   fixtures" when a fixture is newer than main), --app for B/C (required
#   only when B or C runs; an A–A' run needs --ref-app alone).
#
# PAIRS SCORED (Scripts/visual_diff.py kinds)
#   <cfg>-AA  noise     A vs A2: viewport % must be <= --max-noise-pct (0)
#   <cfg>-AB  exact     A vs B:  viewport % must be <= --max-exact-pct (0)
#   <cfg>-AC  tolerant  A vs C:  viewport <= --max-raw-pct (0.5) AND every
#                       text-block crop <= --max-crop-pct (0.5) with vertical
#                       offset <= --max-offset-px (0)
#   <cfg> = <fixture>-p<position>-<appearance>-s<step>
#   Every pair, every kind: marker/content crops (visual_diff.py "MARKER AND
#   CONTENT CROPS"): each text row that starts with a marker is split into
#   a marker crop and a content crop, and the marker centroid, the content's
#   first-line centroid and their relative position must match within
#   0.5 px — a one-pixel marker move cannot hide inside a percentage.
#   List captures (pairs of a --list-fixture): INVALID with fewer than
#   <min markers> marker crops (default 3), FAIL on low-contrast fill
#   differences (decision row backgrounds) the tolerant rule cannot see.
#   Every pair, every kind: code boxes (visual_diff.py "CODE BOXES"): each
#   code block's grey box is found in the reference screenshot; its header
#   strip (badge, Copy button) and its outline must not differ by one pixel
#   at channel threshold 0, where A–A' is exactly stable (else the pair is
#   INVALID, never loosened); the candidate must hold the same box; the
#   code text must stay within the kind's crop limit with every code line
#   displaced 0 px horizontally and vertically.
#
# CODE CAPTURES (--code-capture, repeatable; added to the default set, a
#   declaration for the same position and step replaces the default one;
#   --no-code-captures drops the defaults)
#     <fixture>@<position>[#s<step>]=<positive|fallback>;<owner>=<tk2|swiftui>[,...];land=<block id>
#   declares what a position shows, per size step when #s<step> is given
#   (nothing is inferred from the screenshot or the stats):
#     positive  the code owners marked tk2 are drawn by TextKit 2 on arm C
#               (owners marked swiftui beside them stay on SwiftUI); name
#               only tk2 owners whose code box is scored (a box whose header
#               is under the --exact-mask band is not);
#     fallback  every named owner stays on SwiftUI on arm C too (over the
#               canvas budget, outside the admitted cohort, nested code). A
#               fallback capture never counts as native coverage.
#   <owner> is the code block's RenderBlock id (0.<n> at top level); land=
#   (required) is the id of the block the position scrolls to. Each pair of
#   a declared capture is INVALID - not PASS - without a code box (and, when
#   positive, a code text crop), and without its engine proof, read from
#   the arm's launch log AFTER the app's `SCROLL_LANDED ... block=<id>` line
#   (the RENDERER_STATS line at READY predates the jump): arm C
#   renderer=textkit2 with tk2CodeLive > 0 and tk2CodeDraws > 0 when
#   positive; arm B renderer=swiftui with both 0; the `TK2_CODE_ROWS
#   owners=<id>:<native draws>,...` line (always required) listing each tk2
#   owner with draws > 0 and no swiftui owner; and the capture-time
#   geometry: the two `CAPTURE_GEOMETRY` lines the app prints when this
#   script posts com.connie.adfreader.geometry right before and right after
#   the screenshot (CAPTURE PROCEDURE). visual_diff.py ("CODE CAPTURES")
#   requires the two lines to agree and to describe the image, ties each
#   scored code box to the TextKit 2 code row whose on-screen frame holds
#   its code ink (a box under no code row is SwiftUI's), and then requires
#   on arm C each tk2 owner to own a scored box, no box of a fallback
#   capture under a TextKit 2 code row, no row at all for a swiftui owner;
#   on arm B no TextKit 2 row at all; on both the land= block measured on
#   screen (in the reader's fully visible rows, nothing more than one block
#   above it, below the top band) and, for a fallback capture, a named owner
#   visibly present.
#
# CAPTURE KINDS (PR 4; the same --code-capture declaration with a kind)
#     <fixture>@<position>[#s<step>]=[<kind>:]<positive|fallback>;<owner>=<tk2|swiftui>[,...];land=<block id>
#   <kind> is code (the default: a declaration without a kind, as every
#   PR 3 declaration is), container or caption. A position may carry one
#   declaration per kind; a declaration replaces the one for the same
#   position, step and kind only. The owners of a kind are:
#     code       a code block's RenderBlock id (CODE CAPTURES above);
#     container  the owner of a text leaf inside a panel, quote, expand,
#                layout column or extension body: its block id (a node
#                path such as 0.5.1) or, for a nested list's leader, the
#                PreparedListRow id (0.5.1.0, 0.5.1.0#cont1);
#     caption    a mediaSingle caption's owner, the PreparedMedia id.
#   Positive: every owner marked tk2 is drawn by TextKit 2 on arm C, with
#   context container (not a code row) or caption; fallback: every named
#   owner stays on SwiftUI. visual_diff.py ("CONTAINER AND CAPTION
#   CAPTURES") reads the kind's counters and per-owner line after
#   SCROLL_LANDED (tk2ContainerLive, tk2ContainerNativeDraws and
#   `TK2_CONTAINER_ROWS owners=<id>:<native draws>,...`; tk2CaptionLive,
#   tk2CaptionNativeDraws and `TK2_CAPTION_ROWS ...`), ties each tk2 owner
#   to its TextKit 2 row in the capture-time geometry (a root or list row
#   on screen, with ink inside its frame) and, on the A-C pair, scores a
#   text crop over that row's on-screen frame with the code text rule:
#   the kind's crop limit, every line displaced 0 px in x and y, its ink
#   centroid <= 0.5 px. Arms B and C of a declared capture of any kind get
#   the SCROLL_LANDED wait and the geometry bracket.
#   Adding a capture is one line: append its declaration to
#   CONTAINER_CAPTURES_DEFAULT below; its fixture@position joins the
#   default plan by itself when no --fixture is given.
#
# CAPTURE PROCEDURE (identical for every arm)
#   terminate + uninstall + install the arm's .app (no persisted renderer key
#   or text size leaks), verify the installed binary sha256 equals the .app's,
#   pin the status bar (9:41, charged, full bars), `simctl ui appearance`,
#   `simctl ui content_size` (--content-size, default large), launch
#   `simctl launch --console-pty` logged to captures/<cfg>-<arm>.log, wait
#   for `READY fixture=<f> `, then wait --scroll-wait (default 2 s: the app
#   starts the -scrollToFraction jump 300 ms after READY with a .snappy
#   animation and re-jumps without animation ~1.5 s after READY, which makes
#   the landing exact — the animated one alone varied by up to 26 px between
#   launches of one build; applied at position 0 too so every capture has
#   the same timeline) plus --settle (default 3 s), `simctl io screenshot`,
#   terminate. A reference built from a commit that predates the re-jump
#   needs it patched into Demo/ADFReader/ReaderView.swift, or arm A lands
#   nondeterministically. Arms B and C of a declared capture (any kind)
#   also wait (up to 15 s more, normally not at all) for the app's
#   `SCROLL_LANDED` line, printed about 2.6 s after READY with the
#   RENDERER_STATS, TK2_CODE_ROWS, TK2_CONTAINER_ROWS and TK2_CAPTION_ROWS
#   lines the proofs read: the screenshot is never taken before the log
#   describes it. A build that never prints the line is captured anyway
#   and its declared pairs score INVALID. Those arms then
#   bracket the screenshot: `simctl spawn notifyutil -p
#   com.connie.adfreader.geometry`, wait (up to 5 s) for the app's
#   `CAPTURE_GEOMETRY seq=1` line, `simctl io screenshot`, post again and
#   wait for `seq=2`. A missing line is logged, not a capture failure: the
#   pair scores INVALID.
#
# DEFAULTS
#   fixtures   kitchen-sink@0,0.5 (H1, every-mark paragraph, centered and
#              indented text, H2–H6; then later blocks) and stress-5k@0,0.5,
#              plus the list positions (block = Int(position × blocks); the
#              block's top lands under the toolbar unless the document end
#              clamps the scroll, and READY block counts are a gate
#              invariant, so a position names the same block in every arm —
#              no sentinel search needed). lists-parity positions land on
#              the section heading above a list, so the list's first marker
#              sits below the --exact-mask band (rows 330–460), which noise
#              and exact pairs do not score:
#              lists-parity (21 blocks)
#                @0      block 0: S1 heading, nesting chain depth 0–4 with
#                        • ◦ ▪ and 1. a. markers, same-type bullet chain
#                @0.119  block 2: S2 heading, ordered starts, 9→10, y z aa,
#                        viii ix x, 99→100; then S3 and the task list
#                @0.214  block 4: S3 heading, tasks done/undone/nested/
#                        empty, atom and linked tasks, decisions (row
#                        background, status atom, link, hard break)
#                @0.357  block 7: S4 heading, wrapping leader, marks, link,
#                        hard breaks, Unicode, RTL, atom leaders
#                @0.405  block 8: the same list from its top (its first
#                        line is under the band), reaching the mention/
#                        status/date/emoji atoms, empty leader and the
#                        code-block first child at step 0
#                @0.452  block 9: S5 heading, multi-paragraph item, nested
#                        → continuation → nested → continuation + heading,
#                        embedded code/panel/quote/expand/table
#                @0.548  block 11: S6 heading, trailing lists (sync block,
#                        malformed item), S7, lists in panel/quote/table
#                @0.643  block 13: S7 heading, lists in a panel, quote,
#                        table cells, collapsed expand, layout columns,
#                        LP-END (end-clamped at step 0)
#              list-dense (600 blocks)
#                @0.761  block 456: deep in the document — task list,
#                        decision lists (backgrounds, atoms, links),
#                        nested bullets (its first row is under the band)
#              plus the code positions (PR 3; the constants and their
#              arithmetic are below, "Code captures"). A code position
#              lands on the block ABOVE the code it is about, so the code
#              box clears the --exact-mask band:
#              kitchen-sink (38 blocks)
#                @0.275  block 10: the bullet list; the ordered list and
#                        the code block 0.12 (breakout wide) follow
#              code-parity (34 blocks)
#                @0      block 0: CP-S1, plain code CP-01…CP-05
#                @0.19   block 6: CP-S2, breakout wide and full-width
#                @0.28   block 9: CP-S3, blank lines, trailing newlines
#                @0.515  block 17: CP-S4, the 300-column line (SwiftUI at
#                        3x), then the block just under the canvas budget
#                        (TextKit 2 at step 0, SwiftUI at step 3)
#                @0.66   block 22: CP-S5, tabs, emoji/CJK, combining marks,
#                        RTL, "" and "\n" (all SwiftUI: expected fallback)
#                @0.78   block 26: CP-22 (its header under the band), CP-23,
#                        CP-24, then CP-S6, nested code (all SwiftUI;
#                        lands three blocks above CP-S6 because the
#                        document end clamps a landing on CP-S6 itself)
#              code-dense (600 blocks, code only)
#                @0      block 0 (its header under the band), blocks 1, 2
#                @0.5    block 300 (its header under the band), then 301
#                        and on
#   code captures  one declaration per code position (CODE_CAPTURES_DEFAULT)
#   container and caption captures  CONTAINER_CAPTURES_DEFAULT (each PR 4
#              step that enables a family declares its own; a declared
#              position not in the fixture defaults above is captured too).
#              --no-code-captures drops every default declaration, of every
#              kind. Step 3 (panels, quotes, extension bodies):
#              containers-parity (87 prepared blocks)
#                @0      block 0, KP-S1: panels 0.1-0.6 (one paragraph each)
#                @0.1321 block 11: panels 0.11 and 0.12 (headings), whose
#                        bodies stay on SwiftUI (the panel shape rule)
#                @0.3045 block 26, KP-S3: quotes 0.27-0.29 (three deep)
#                @0.362  block 31, KP-S4: panel in quote, quote in panel,
#                        panel in and quote in an extension body
#                @0.4425 block 38, KP-S5: extension body 0.39
#                @0.8103 block 70, KP-S10: panel 0.71, prose beside a code
#                        block, stays on SwiftUI (the panel shape rule)
#              Step 8 (captions): captions-parity (25 prepared blocks)
#                @0.14   block 3: CAP-03 plain, CAP-04 marks
#                @0.30   block 7: CAP-07 colour/highlight, CAP-08 placeholder
#                @0.38   block 9: CAP-09 atoms (SwiftUI), CAP-10 wrapping
#                @0.46   block 11: CAP-11 mixed scripts and emoji
#                @0.54   block 13: CAP-12 in a panel, CAP-13 in a column
#                        (SwiftUI until step 4)
#                @0.70, @0.78, @0.86  blocks 17, 19, 21: one caption per
#                        media layout
#   list fixtures  lists-parity:3 list-dense:3 list-tall:3 (--list-fixture
#              replaces the set; pairs of other fixtures are not list pairs)
#   masks      --top-band 330 (status bar + inline nav bar/toolbar, where the
#              renderer label lives) and --bottom-band 102 (home indicator),
#              in pixels of an iPhone 17 Pro screenshot (1206x2622, 3x). When
#              no band/mask flag is given and a screenshot has another size,
#              the run stops: pass masks for that device explicitly.
#              Noise/exact pairs also mask --exact-mask 0,330,1206,460: the
#              soft shadows the toolbar's glass capsules cast below the band,
#              plus the scroll-edge effect over scrolled content. They follow
#              the capsules' widths, which follow the renderer label (main
#              has none): measured A–B |Δ| <= 7 over rows 330–436 at p0 and
#              <= 14 over rows 330–450, cols 314–1198 at p0.5 (A–A' 0).
#              Tolerant pairs (threshold 24) still score these rows.
#              --exact-mask replaces that default; --no-exact-mask drops it.
#   --out      $TMPDIR/adfreader-parity/<timestamp>
#
# OUTPUTS (<out>/)
#   captures/<cfg>-<arm>.png|.log   screenshots + launch logs
#   manifest.tsv     one row per capture: arm, fixture, position, appearance,
#                    size step, content size, app path + sha256, installed
#                    sha256, argv, device, runtime, locale, READY and
#                    RENDERER_STATS lines, png sha256, time, status, and the
#                    SCROLL_LANDED line with the RENDERER_STATS and
#                    TK2_CODE_ROWS lines printed after it (the code proof),
#                    the TK2_CONTAINER_ROWS and TK2_CAPTION_ROWS lines
#                    printed after it (the container and caption proofs;
#                    landed_container_rows, landed_caption_rows; empty for
#                    a build without them),
#                    and the CAPTURE_GEOMETRY seq=1 and seq=2 lines
#                    (geometry_before, geometry_after; empty for arms
#                    without the bracket)
#   env.txt          host, Xcode, device, settings, git head of this checkout
#   scores.csv, scores.json, summary.md, *.sbs.png, crops/   (visual_diff.py)
#
# DEVICE  --udid is required for capture. The script never creates a
#   simulator, refuses to run while a different device is booted (unless
#   --allow-other-booted: captures do not depend on other devices, and env.txt
#   records which were booted), and shuts down only a device it booted
#   itself (never with --keep-booted). It
#   restores the device's appearance and content size, and clears the status
#   bar override, on exit.
#   --skip-capture re-scores existing captures in --out (no simulator).
#   --dry-run prints the capture plan and the visual_diff invocation and
#   touches no simulator.
#
# EXIT STATUS  0 all pairs PASS; 1 a capture failed or any pair (including a
#   noise pair) FAILed; 2 usage/input error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/sim.sh
. "$SCRIPT_DIR/lib/sim.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="com.connie.adfreader"
EXPECTED_SIZE="1206x2622"

UDID=""
REF_APP=""
APP=""
OUT=""
FIXTURE_SPECS=()
APPEARANCES="light dark"
SIZE_STEPS="0 3"
ARMS="A A2 B C"
CONTENT_SIZE="large"
SETTLE_SECONDS=3
SCROLL_WAIT_SECONDS=2
READY_TIMEOUT=90
LANDED_WAIT_SECONDS=15   # extra wait for SCROLL_LANDED on a declared capture (any kind)
GEOMETRY_NOTIFICATION="com.connie.adfreader.geometry"   # CaptureGeometryHook (-captureGeometryHook)
GEOMETRY_WAIT_SECONDS=5  # per CAPTURE_GEOMETRY line of the screenshot bracket
MASKS=()
TOP_BAND=330
BOTTOM_BAND=102
MASKS_EXPLICIT=0
EXACT_MASKS=("0,330,1206,460")
EXACT_MASKS_DEFAULT=1
THRESHOLD=24
MAX_NOISE_PCT=0
MAX_EXACT_PCT=0
MAX_RAW_PCT=0.5
MAX_CROP_PCT=0.5
MAX_OFFSET_PX=0
RENDERER_STATS=1
KEEP_BOOTED=0
SKIP_CAPTURE=0
DRY_RUN=0
ALLOW_OTHER_BOOTED=0
LIST_FIXTURES=()
LIST_FIXTURES_DEFAULT=("lists-parity:3" "list-dense:3" "list-tall:3")

# ---- Code captures (PR 3) ----------------------------------------------------
# A position lands blocks[Int(position × blocks)] with its top under the
# toolbar. A code position names the block ABOVE the code it is about (a
# section heading or a list), never the code block itself: a box whose top
# is under the toolbar has its header strip inside the --exact-mask band
# (rows 330–460, the toolbar capsules' shadows), where nothing can be
# compared at threshold 0, and visual_diff.py does not score such a box.
# (code-parity@0.78 lands on CP-22 itself: CP-22 is not what it is about;
# the nested code of CP-S6 below it is.)
#
# TEAM LEAD: confirm every fraction, land= block and owner below against
# the final fixtures' READY block counts and the generator's summary before
# the gate run. The run checks the landing twice: the app's SCROLL_LANDED
# line must name the land= block (the jump went where it was told), and the
# capture-time geometry must show it landed there (the land= block fully
# visible, below the top band, nothing more than one block above it on
# screen), or the pair is INVALID. A tk2 owner must own a scored code box
# at the screenshot: name only owners whose box is below the band, and use
# a #s<step> declaration where one step moves an owner out of the scored
# region (never a looser rule).
#
# kitchen-sink: 37 top-level nodes prepare to 38 blocks. The code block is
# node 12 = block id 0.12 = blocks[12]: nodes 0–11 (headings, paragraphs,
# a quote, two lists) prepare to exactly one block each, so the 38th block
# comes from a later node. 0.275 × 38 = 10.45 → blocks[10], the bullet list
# two blocks above the code block (blocks[11] is a two-item ordered list),
# which puts the code box about a third of a screen below the band. 0.275
# lands blocks[10] for 37 and 39 blocks as well. To land ON the code block
# instead: 0.33 (12.54 of 38) — its header strip is then under the band and
# the capture can only be INVALID.
KITCHEN_SINK_CODE_POSITION="0.275"
KITCHEN_SINK_CODE_LAND="0.10"
KITCHEN_SINK_CODE_OWNER="0.12"
# code-parity: 34 top-level nodes, one block each (Tools/make-fixtures.swift,
# "Fixture 10": block id = 0.<node index>). One position per CP-S heading:
#   CP-S1 blocks[0]  → 0        CP-S2 blocks[6]  → 0.19  (6.46 of 34)
#   CP-S3 blocks[9]  → 0.28  (9.52)    CP-S4 blocks[17] → 0.515 (17.51)
#   CP-S5 blocks[22] → 0.66  (22.44)   CP-S6: blocks[26] → 0.78 (26.52)
# CP-S6 is the end of the document. Landing on its heading (blocks[29],
# 0.87) is end-clamped: the scroll stops about 867 px short at step 0 and
# 339 px at step 3, and the clamped offset differed by 1-2 px between
# launches of the same build (smoke 8fb1e14: A against A' -2 px at step 3).
# blocks[26] (CP-22) is 943 px above blocks[29] at step 0, so 0.78 lands
# unclamped with about 76 px (25 pt) to spare; at step 3 the margin is
# about 800 px. CP-25 (list) and CP-26 (panel) stay on screen. If 0.78 is
# ever end-clamped (A-A' shows a uniform offset), use 0.75 (blocks[25],
# CP-21, about 400 px to spare at step 0).
CODE_PARITY_POSITIONS="0,0.19,0.28,0.515,0.66,0.78"
# code-dense: 600 code blocks and nothing else (block id 0.<i>, first line
# "// CD-<iii>"). Block 0 and block 300 land with their header strip under
# the band: they are live, drawn rows but not scored as boxes, so they are
# the land= blocks and not named as owners (a tk2 owner must own a scored
# box); the boxes scored are the blocks below them. Blocks 0–2 are pinned
# by the generator to 3–8 lines of at most 40 columns. Blocks 300 (5 x 28)
# and 301 (10 x 65) are predicted admitted at steps 0 and 3 by the
# generator's Python port (fixture notes, section 6; neither is in the
# "kept over budget" list). TEAM LEAD: confirm 300 and 301 against the
# generator log; when a named owner is gated the pair is INVALID and says
# which owner has no live TextKit 2 row.
CODE_DENSE_POSITIONS="0,0.5"
CODE_CAPTURES_DEFAULT=(
    "kitchen-sink@$KITCHEN_SINK_CODE_POSITION=positive;$KITCHEN_SINK_CODE_OWNER=tk2;land=$KITCHEN_SINK_CODE_LAND"
    # CP-S1: CP-01 (one line) and CP-02 (eight lines), plain ASCII.
    "code-parity@0=positive;0.1=tk2,0.2=tk2;land=0.0"
    # CP-S2: CP-06 breakout wide, CP-07 breakout full-width.
    "code-parity@0.19=positive;0.7=tk2,0.8=tk2;land=0.6"
    # CP-S3: CP-08 and CP-09, blank lines in the middle (LF only: admitted).
    "code-parity@0.28=positive;0.10=tk2,0.11=tk2;land=0.9"
    # CP-S4: CP-15, one 300-column line, is over 8,192 px wide at 3x
    # (SwiftUI); CP-16 is the block just under the canvas budget: TextKit 2
    # at step 0, over the budget and on SwiftUI from step 1; CP-17 below it
    # is over the budget at every size (off screen at step 3).
    "code-parity@0.515=positive;0.18=swiftui,0.19=tk2,0.20=swiftui;land=0.17"
    "code-parity@0.515#s3=fallback;0.18=swiftui,0.19=swiftui;land=0.17"
    # CP-S5: tabs (CP-19) and non-ASCII (CP-20, CP-21, CP-22) are outside
    # the admitted cohort.
    "code-parity@0.66=fallback;0.23=swiftui,0.24=swiftui,0.25=swiftui,0.26=swiftui;land=0.22"
    # CP-S6: nested code stays on SwiftUI (CP-25 in a bullet item, CP-26 in
    # a panel; CP-27 is in a collapsed expand and not on screen). The
    # landing block CP-22 (non-ASCII) is outside the admitted cohort, and
    # CP-23 ("") and CP-24 ("\n") below it hold no drawable text (fallback
    # .empty), so none of the five may have a TextKit 2 row (G6).
    "code-parity@0.78=fallback;0.26=swiftui,0.27=swiftui,0.28=swiftui,0.30.0.1=swiftui,0.31.1=swiftui;land=0.26"
    "code-dense@0=positive;0.1=tk2,0.2=tk2;land=0.0"
    "code-dense@0.5=positive;0.301=tk2;land=0.300"
)
# ---- Container and caption captures (PR 4) -----------------------------------
# One line per capture, in the step that enables its family (plan §7.4):
#   "<fixture>@<position>[#s<step>]=<container|caption>:<positive|fallback>;<owner>=<tk2|swiftui>[,...];land=<block id>"
# for example (not declared):
#   "containers-parity@0.1=container:positive;0.4.0=tk2,0.4.1=tk2;land=0.3"
# A positive capture names its TextKit 2 owners (tk2) and may name owners
# that stay on SwiftUI beside them; a fallback capture names SwiftUI owners
# only. Name only owners whose text is below the top band at the
# screenshot (a tk2 owner must own a scored text crop), and confirm every
# fraction, land= block and owner against the fixture's READY block count
# and owner table, as for the code captures above. The position is
# captured by default (DEFAULT_FIXTURE_SPECS needs no edit).
CONTAINER_CAPTURES_DEFAULT=(
    # Step 3, panels, quotes and extension bodies (containers-parity, 87
    # prepared blocks; owners from the fixture's owner table). Landings and
    # owner frames measured on an iPhone 17 Pro (iOS 26.3) at -fontSizeStep
    # 0 and 3: every named owner is on screen below the top band and above
    # the bottom band at both steps. None of them is linked (a linked row
    # draws through TextKit 1: 0 native draws, never proof).
    # KP-S1: the palette panels, one paragraph each (0.7.0 and 0.8.0 run
    # into the bottom band).
    "containers-parity@0=container:positive;0.1.0=tk2,0.2.0=tk2,0.3.0=tk2,0.4.0=tk2,0.5.0=tk2,0.6.0=tk2;land=0.0"
    # Panels 0.11 (H2 and H5 among three paragraphs) and 0.12 (H1) hold
    # headings, so their bodies stay on SwiftUI. Landing on 0.11 keeps
    # panel 0.8 (TextKit 2) off screen; at 0.10 it sits under the top band
    # and a fallback capture would see it.
    "containers-parity@0.1321=container:fallback;0.11.0=swiftui,0.11.1=swiftui,0.11.2=swiftui,0.11.4=swiftui,0.12.0=swiftui;land=0.11"
    # KP-S3: a one-paragraph quote, a quote with a heading between two
    # paragraphs, and quotes three deep.
    "containers-parity@0.3045=container:positive;0.27.0=tk2,0.28.0=tk2,0.28.1=tk2,0.28.2=tk2,0.29.0=tk2,0.29.1.0=tk2,0.29.1.1.0=tk2,0.29.2=tk2;land=0.26"
    # KP-S4: panel in quote, quote in panel, panel in an extension body,
    # quote in an extension body (0.36, quote > panel > quote, runs into
    # the bottom band at step 3).
    "containers-parity@0.362=container:positive;0.32.0=tk2,0.32.1.0=tk2,0.33.0=tk2,0.33.1.0=tk2,0.34.0=tk2,0.34.1.0=tk2,0.35.0.0=tk2;land=0.31"
    # KP-S5: an extension body with a heading between two paragraphs (the
    # bodied sync block's paragraph 0.43.0 below it is root text).
    "containers-parity@0.4425=container:positive;0.39.0=tk2,0.39.1=tk2,0.39.2=tk2;land=0.38"
    # KP-S10: panel 0.71's paragraph sits beside a code block, so the panel
    # stays on SwiftUI; no TextKit 2 container row is on screen (the quote,
    # panel and extension below it hold only code).
    "containers-parity@0.8103=container:fallback;0.71.0=swiftui;land=0.70"
    # Captions (step 8): captions-parity, 25 prepared blocks (`Int(f x 25)`).
    # Each landing, owner and live caption row was checked on the enabled
    # build at 3x (SCROLL_LANDED and TK2_CAPTION_ROWS). Linked captions
    # (CAP-05 0.5.0, CAP-06 0.6.0) are TextKit 1-backed rows with no native
    # draws, never proof: they are not named.
    # CAP-03 plain, CAP-04 bold, italic, inline code, strike, underline,
    # sub/superscript.
    "captions-parity@0.14=caption:positive;0.3.0=tk2,0.4.0=tk2;land=0.3"
    # CAP-07 author colour and highlight, CAP-08 placeholder.
    "captions-parity@0.30=caption:positive;0.7.0=tk2,0.8.0=tk2;land=0.7"
    # CAP-09 (mention, date, status: atoms) stays on SwiftUI beside CAP-10
    # (wrapping, hard break).
    "captions-parity@0.38=caption:positive;0.9.0=swiftui,0.10.0=tk2;land=0.9"
    # CAP-11 accents, CJK, emoji, Hebrew and Arabic in one caption.
    "captions-parity@0.46=caption:positive;0.11.0=tk2;land=0.11"
    # CAP-12 in a panel (TextKit 2: panels and media are in the allow list
    # from steps 3 and 8) and CAP-13 in a column (stacked at phone width;
    # SwiftUI until step 4 adds layout columns, which flips it to tk2).
    "captions-parity@0.54=caption:positive;0.13.1.0=tk2,0.14.0.0.0=swiftui;land=0.13"
    # CAP-S3, one caption per layout: center, wrap-left; wrap-right,
    # align-start; align-end, wide, full-width. The document ends below
    # CAP-L-FULL-WIDTH: 0.86 is the last landing with at most one block
    # above it (0.90 lands on the same screen).
    "captions-parity@0.70=caption:positive;0.17.0=tk2,0.18.0=tk2;land=0.17"
    "captions-parity@0.78=caption:positive;0.19.0=tk2,0.20.0=tk2;land=0.19"
    "captions-parity@0.86=caption:positive;0.21.0=tk2,0.22.0=tk2,0.23.0=tk2;land=0.21"
)
CODE_CAPTURES=()
CODE_CAPTURES_EXPLICIT=()
NO_CODE_CAPTURES=0
DEFAULT_FIXTURE_SPECS=("kitchen-sink@0,0.5" "stress-5k@0,0.5"
    "lists-parity@0,0.119,0.214,0.357,0.405,0.452,0.548,0.643" "list-dense@0.761"
    "kitchen-sink@$KITCHEN_SINK_CODE_POSITION" "code-parity@$CODE_PARITY_POSITIONS"
    "code-dense@$CODE_DENSE_POSITIONS")

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; }
log() { printf '[visual-parity] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 2; }

need_value() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --udid) need_value "$@"; UDID="$2"; shift 2 ;;
        --ref-app) need_value "$@"; REF_APP="$2"; shift 2 ;;
        --app) need_value "$@"; APP="$2"; shift 2 ;;
        --out) need_value "$@"; OUT="$2"; shift 2 ;;
        --fixture) need_value "$@"; FIXTURE_SPECS+=("$2"); shift 2 ;;
        --appearances) need_value "$@"; APPEARANCES="$2"; shift 2 ;;
        --size-steps) need_value "$@"; SIZE_STEPS="$2"; shift 2 ;;
        --arms) need_value "$@"; ARMS="$2"; shift 2 ;;
        --content-size) need_value "$@"; CONTENT_SIZE="$2"; shift 2 ;;
        --settle) need_value "$@"; SETTLE_SECONDS="$2"; shift 2 ;;
        --scroll-wait) need_value "$@"; SCROLL_WAIT_SECONDS="$2"; shift 2 ;;
        --ready-timeout) need_value "$@"; READY_TIMEOUT="$2"; shift 2 ;;
        --mask) need_value "$@"; MASKS+=("$2"); MASKS_EXPLICIT=1; shift 2 ;;
        --top-band) need_value "$@"; TOP_BAND="$2"; MASKS_EXPLICIT=1; shift 2 ;;
        --bottom-band) need_value "$@"; BOTTOM_BAND="$2"; MASKS_EXPLICIT=1; shift 2 ;;
        --exact-mask) need_value "$@"
            [[ $EXACT_MASKS_DEFAULT -eq 1 ]] && EXACT_MASKS=()
            EXACT_MASKS+=("$2"); EXACT_MASKS_DEFAULT=0; MASKS_EXPLICIT=1; shift 2 ;;
        --no-exact-mask) EXACT_MASKS=(); EXACT_MASKS_DEFAULT=0; MASKS_EXPLICIT=1; shift ;;
        --threshold) need_value "$@"; THRESHOLD="$2"; shift 2 ;;
        --max-noise-pct) need_value "$@"; MAX_NOISE_PCT="$2"; shift 2 ;;
        --max-exact-pct) need_value "$@"; MAX_EXACT_PCT="$2"; shift 2 ;;
        --max-raw-pct) need_value "$@"; MAX_RAW_PCT="$2"; shift 2 ;;
        --max-crop-pct) need_value "$@"; MAX_CROP_PCT="$2"; shift 2 ;;
        --max-offset-px) need_value "$@"; MAX_OFFSET_PX="$2"; shift 2 ;;
        --no-renderer-stats) RENDERER_STATS=0; shift ;;
        --keep-booted) KEEP_BOOTED=1; shift ;;
        --allow-other-booted) ALLOW_OTHER_BOOTED=1; shift ;;
        --list-fixture) need_value "$@"; LIST_FIXTURES+=("$2"); shift 2 ;;
        --code-capture) need_value "$@"; CODE_CAPTURES_EXPLICIT+=("$2"); shift 2 ;;
        --no-code-captures) NO_CODE_CAPTURES=1; shift ;;
        # Accepted for old command lines: visual_diff.py always demands the
        # owner-level proof now.
        --require-owner-proof) shift ;;
        --skip-capture) SKIP_CAPTURE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ ${#LIST_FIXTURES[@]} -gt 0 ]] || LIST_FIXTURES=("${LIST_FIXTURES_DEFAULT[@]}")
for rule in "${LIST_FIXTURES[@]}"; do
    [[ "$rule" =~ ^[A-Za-z0-9_.-]+(:[0-9]+)?$ ]] || die "--list-fixture '$rule': want <name>[:<min markers>]"
done
# Captures: the defaults (unless --no-code-captures), then the explicit
# ones; code_rule_for reads the list from the end, so a later declaration
# for the same position, step and kind wins.
DEFAULT_CAPTURES=("${CODE_CAPTURES_DEFAULT[@]}"
    ${CONTAINER_CAPTURES_DEFAULT[@]+"${CONTAINER_CAPTURES_DEFAULT[@]}"})
[[ $NO_CODE_CAPTURES -eq 1 ]] || CODE_CAPTURES=("${DEFAULT_CAPTURES[@]}")
for decl in ${CODE_CAPTURES_EXPLICIT[@]+"${CODE_CAPTURES_EXPLICIT[@]}"}; do CODE_CAPTURES+=("$decl"); done
# An owner is a node path, or a list continuation row's id (<item id>#cont<n>).
CAPTURE_OWNER_RE='[0-9][0-9.]*(#cont[0-9]+)?=(tk2|swiftui)'
CODE_CAPTURE_RE="^[A-Za-z0-9_.-]+@(0|1|0?[.][0-9]+|1[.]0*)(#s-?[0-9]+)?=((code|container|caption):)?(positive|fallback);$CAPTURE_OWNER_RE(,$CAPTURE_OWNER_RE)*(;land=[0-9.]+)\$"
for decl in ${CODE_CAPTURES[@]+"${CODE_CAPTURES[@]}"}; do
    [[ "$decl" =~ $CODE_CAPTURE_RE ]] ||
        die "--code-capture '$decl': want <fixture>@<position>[#s<step>]=[<code|container|caption>:]<positive|fallback>;<owner>=<tk2|swiftui>[,...];land=<block id> (land= is required: the landing is measured)"
    case "$decl" in
        *"=positive;"*|*":positive;"*) [[ "$decl" == *=tk2* ]] || die "--code-capture '$decl': a positive capture needs an owner marked tk2" ;;
        *) [[ "$decl" != *=tk2* ]] || die "--code-capture '$decl': a fallback capture cannot mark an owner tk2" ;;
    esac
done
# The fixture positions: --fixture's, or the defaults plus the position of
# every default declaration they do not capture yet (so a new declaration
# is one line), in declaration order.
if [[ ${#FIXTURE_SPECS[@]} -eq 0 ]]; then
    FIXTURE_SPECS=("${DEFAULT_FIXTURE_SPECS[@]}")
    [[ $NO_CODE_CAPTURES -eq 0 ]] || DEFAULT_CAPTURES=()
    for decl in ${DEFAULT_CAPTURES[@]+"${DEFAULT_CAPTURES[@]}"}; do
        key="${decl%%=*}"
        key="${key%%#*}"
        captured=0
        for spec in "${FIXTURE_SPECS[@]}"; do
            [[ "$spec" == *@* ]] || spec="$spec@0"
            case ",${spec#*@}," in *",${key#*@},"*) [[ "${spec%%@*}" != "${key%%@*}" ]] || captured=1 ;; esac
        done
        [[ $captured -eq 1 ]] || FIXTURE_SPECS+=("$key")
    done
fi
# Every declared code capture needs the engine proof and the capture-time
# geometry, which only -rendererStats and -captureGeometryHook print.
[[ $RENDERER_STATS -eq 1 || ${#CODE_CAPTURES[@]} -eq 0 ]] ||
    die "--no-renderer-stats drops the engine proof every declared code capture needs: add --no-code-captures, or keep the stats"
for arm in $ARMS; do
    case "$arm" in A|A2|B|C) ;; *) die "--arms: unknown arm '$arm' (A A2 B C)" ;; esac
done
case " $ARMS " in *" A "*) ;; *) die "--arms must include A (the reference)" ;; esac
for number in "$SETTLE_SECONDS" "$SCROLL_WAIT_SECONDS" "$READY_TIMEOUT"; do
    [[ "$number" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "not a number of seconds: $number"
done

has_arm() { case " $ARMS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}/adfreader-parity"
[[ -n "$OUT" ]] || OUT="$TMP_BASE/$(date +%Y%m%d-%H%M%S)"
CAPTURES="$OUT/captures"
MANIFEST="$OUT/manifest.tsv"

if [[ $SKIP_CAPTURE -eq 0 ]]; then
    [[ -n "$UDID" ]] || die "--udid is required (the script never picks or creates a simulator)"
    if [[ $DRY_RUN -eq 0 ]]; then
        [[ -n "$REF_APP" && -x "$REF_APP/ADFReader" ]] || die "--ref-app must be an ADFReader.app (got '${REF_APP:-}')"
        if has_arm B || has_arm C; then
            [[ -n "$APP" && -x "$APP/ADFReader" ]] || die "--app must be an ADFReader.app (got '${APP:-}')"
        fi
    fi
fi

# ------------------------------------------------------------------ plan -----

# Fills POSITIONS with "<fixture>\t<position>" per capture position of every
# --fixture spec (in the main shell, so a bad spec stops the run).
POSITIONS=()
for spec in "${FIXTURE_SPECS[@]}"; do
    name="${spec%%@*}"
    positions="0"
    [[ "$spec" == *@* ]] && positions="${spec#*@}"
    [[ -n "$name" ]] || die "--fixture '$spec': empty name"
    for pos in ${positions//,/ }; do
        [[ "$pos" =~ ^(0|1|0?[.][0-9]+|1[.]0*)$ ]] || die "--fixture '$spec': position '$pos' not in [0, 1]"
        POSITIONS+=("$name"$'\t'"$pos")
    done
done

# arm_args <arm> <fixture> <position> <step>: one argv word per line.
arm_args() {
    local arm="$1" fixture="$2" pos="$3" step="$4"
    printf '%s\n' -fixture "$fixture" -scrollToFraction "$pos" -fontSizeStep "$step"
    case "$arm" in
        B|C)
            printf '%s\n' -rendererReset
            [[ $RENDERER_STATS -eq 0 ]] || printf '%s\n' -rendererStats -captureGeometryHook
            [[ "$arm" != "C" ]] || printf '%s\n' -textkit2
            ;;
    esac
}

arm_app() { case "$1" in A|A2) echo "$REF_APP" ;; *) echo "$APP" ;; esac; }
expected_renderer() { case "$1" in B) echo swiftui ;; C) echo textkit2 ;; *) echo "" ;; esac; }

PLAN=()   # entries: "<cfg>\t<fixture>\t<position>\t<appearance>\t<step>"
for fixture_pos in "${POSITIONS[@]}"; do
    IFS=$'\t' read -r fixture pos <<<"$fixture_pos"
    for appearance in $APPEARANCES; do
        for step in $SIZE_STEPS; do
            [[ "$step" =~ ^-?[0-9]+$ ]] || die "--size-steps: '$step' is not an integer"
            PLAN+=("$fixture-p$pos-$appearance-s$step"$'\t'"$fixture"$'\t'"$pos"$'\t'"$appearance"$'\t'"$step")
        done
    done
done
[[ ${#PLAN[@]} -gt 0 ]] || die "empty capture plan (check --appearances / --size-steps)"

# code_rule_for <fixture> <position> <step>: one line "<class>\t<owners[;land=…]>"
# per capture kind declared for that configuration (code, then container,
# then caption), or nothing. <class> is the declaration's class field in
# canonical form: a code capture's without a kind ("positive"; "code:" is
# dropped), the other kinds' with it ("container:positive"). Per kind, a
# declaration with #s<step> beats one without; among equals the last wins.
code_rule_for() {
    local fixture="$1" pos="$2" step="$3" kind index decl key value cls decl_kind found general
    for kind in code container caption; do
        index=${#CODE_CAPTURES[@]}
        found=""
        general=""
        while (( index > 0 )); do
            index=$(( index - 1 ))
            decl="${CODE_CAPTURES[$index]}"
            key="${decl%%=*}"
            value="${decl#*=}"
            cls="${value%%;*}"
            decl_kind="code"
            [[ "$cls" != *:* ]] || decl_kind="${cls%%:*}"
            [[ "$decl_kind" == "$kind" ]] || continue
            if [[ "$key" == "$fixture@$pos#s$step" ]]; then
                found="$value"
                break
            fi
            [[ -n "$general" || "$key" != "$fixture@$pos" ]] || general="$value"
        done
        [[ -n "$found" ]] || found="$general"
        [[ -n "$found" ]] || continue
        cls="${found%%;*}"
        printf '%s\t%s\n' "${cls#code:}" "${found#*;}"
    done
}

# An explicit declaration that matches no planned position is a typo.
for decl in ${CODE_CAPTURES_EXPLICIT[@]+"${CODE_CAPTURES_EXPLICIT[@]}"}; do
    key="${decl%%=*}"
    planned=0
    for fixture_pos in "${POSITIONS[@]}"; do
        IFS=$'\t' read -r fixture pos <<<"$fixture_pos"
        [[ "${key%%#*}" != "$fixture@$pos" ]] || planned=1
    done
    [[ $planned -eq 1 ]] || die "--code-capture '$decl': no --fixture position ${key%%#*} in this run"
done

DIFF_ARGS=(--top-band "$TOP_BAND" --bottom-band "$BOTTOM_BAND" --threshold "$THRESHOLD"
    --max-noise-pct "$MAX_NOISE_PCT" --max-exact-pct "$MAX_EXACT_PCT"
    --max-raw-pct "$MAX_RAW_PCT" --max-crop-pct "$MAX_CROP_PCT" --max-offset-px "$MAX_OFFSET_PX")
for mask in ${MASKS[@]+"${MASKS[@]}"}; do DIFF_ARGS+=(--mask "$mask"); done
for mask in ${EXACT_MASKS[@]+"${EXACT_MASKS[@]}"}; do DIFF_ARGS+=(--exact-mask "$mask"); done
# List captures: pair names are <fixture>-p<position>-…, so the prefix
# "<fixture>-p" names exactly that fixture's pairs.
for rule in "${LIST_FIXTURES[@]}"; do
    list_name="${rule%%:*}"
    list_min="1"
    [[ "$rule" == *:* ]] && list_min="${rule#*:}"
    DIFF_ARGS+=(--list-pair "$list_name-p:$list_min")
done

# The engine a pair's candidate arm ran, for the code proof: none for the
# reference build (it prints no stats) and under --no-renderer-stats (then
# no code capture is declared: refused above).
arm_engine() {
    [[ $RENDERER_STATS -eq 1 ]] || { echo none; return 0; }
    case "$1" in B) echo swiftui ;; C) echo textkit2 ;; *) echo none ;; esac
}

# pair_args <require-files:0|1>: the --pair arguments for every configuration,
# and the --code-capture declaration of each pair of a declared capture, one
# per kind (the class argument carries a kind other than code:
# container:positive).
PAIR_ARGS=()
CODE_ARGS=()
PAIR_COUNT=0
build_pairs() {
    local require="$1" entry cfg a fixture pos appearance step rules
    PAIR_ARGS=()
    CODE_ARGS=()
    PAIR_COUNT=0
    for entry in "${PLAN[@]}"; do
        IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
        a="$CAPTURES/$cfg-A.png"
        rules="$(code_rule_for "$fixture" "$pos" "$step")"
        add_pair() {   # <kind> <suffix> <arm>
            local cand="$CAPTURES/$cfg-$3.png" engine log="-" rule
            if [[ $require -eq 0 ]] || [[ -f "$a" && -f "$cand" ]]; then
                PAIR_ARGS+=(--pair "$1" "$cfg-$2" "$a" "$cand")
                PAIR_COUNT=$(( PAIR_COUNT + 1 ))
                if [[ -n "$rules" ]]; then
                    engine="$(arm_engine "$3")"
                    [[ "$engine" == "none" ]] || log="$CAPTURES/$cfg-$3.log"
                    while IFS= read -r rule; do
                        CODE_ARGS+=(--code-capture "$cfg-$2" "${rule%%$'\t'*}" "${rule#*$'\t'}" "$engine" "$log")
                    done <<<"$rules"
                fi
            fi
        }
        if has_arm A2; then add_pair noise AA A2; fi
        if has_arm B; then add_pair exact AB B; fi
        if has_arm C; then add_pair tolerant AC C; fi
    done
}

if [[ $DRY_RUN -eq 1 ]]; then
    echo "visual-parity dry run (no simulator is touched)"
    echo "device:       ${UDID:-(none: --skip-capture)}"
    echo "out:          $OUT"
    echo "ref app (A):  ${REF_APP:-(unset)}"
    echo "app (B, C):   ${APP:-(unset)}"
    echo "settings:     content_size=$CONTENT_SIZE settle=${SETTLE_SECONDS}s scroll_wait=${SCROLL_WAIT_SECONDS}s ready_timeout=${READY_TIMEOUT}s renderer_stats=$RENDERER_STATS"
    echo "captures:     ${#PLAN[@]} configurations x arms ($ARMS)"
    if [[ $SKIP_CAPTURE -eq 0 ]]; then
        for entry in "${PLAN[@]}"; do
            IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
            for arm in $ARMS; do
                args="$(arm_args "$arm" "$fixture" "$pos" "$step" | tr '\n' ' ')"
                echo "  $cfg-$arm  appearance=$appearance  app=$(arm_app "$arm")"
                echo "      xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${args% }"
                if [[ "$(arm_engine "$arm")" != "none" && -n "$(code_rule_for "$fixture" "$pos" "$step")" ]]; then
                    echo "      geometry: notifyutil -p $GEOMETRY_NOTIFICATION before and after the screenshot"
                fi
            done
        done
    fi
    echo "code captures (configuration: [kind:]class; owners; landing block):"
    declared=0
    for entry in "${PLAN[@]}"; do
        IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
        rules="$(code_rule_for "$fixture" "$pos" "$step")"
        [[ -n "$rules" ]] || continue
        while IFS= read -r rule; do
            declared=$(( declared + 1 ))
            echo "  $cfg: ${rule%%$'\t'*}; ${rule#*$'\t'}"
        done <<<"$rules"
    done
    [[ $declared -gt 0 ]] || echo "  (none)"
    build_pairs 0
    echo "score:"
    printf '  python3 -I %q --out %q' "$SCRIPT_DIR/visual_diff.py" "$OUT"
    printf ' %q' "${DIFF_ARGS[@]}" "${PAIR_ARGS[@]}" ${CODE_ARGS[@]+"${CODE_ARGS[@]}"}
    echo
    exit 0
fi

mkdir -p "$CAPTURES"

# ---------------------------------------------------------------- simulator --

BOOTED_BY_US=0
DEVICE_READY=0
ORIG_APPEARANCE=""
ORIG_CONTENT_SIZE=""
LAUNCH_PID=""

prepare_device() {
    local record state other
    record="$(sim_device_record "$UDID")"
    [[ -n "$record" ]] || die "no simulator with udid $UDID (the script never creates devices)"
    IFS=$'\t' read -r state DEVICE_NAME DEVICE_RUNTIME <<<"$record"
    log "device: $DEVICE_NAME ($UDID) $DEVICE_RUNTIME, state $state"
    OTHER_BOOTED="$(sim_other_booted "$UDID" | tr '\n' ' ')"
    other="${OTHER_BOOTED%% *}"
    if [[ -n "$other" && $ALLOW_OTHER_BOOTED -eq 0 ]]; then
        die "another simulator is already booted ($other); shut it down first (or pass --allow-other-booted)"
    fi
    [[ -z "$other" ]] || log "other booted simulators (allowed): $OTHER_BOOTED"
    if [[ "$state" != "Booted" ]]; then
        log "booting $UDID"
        xcrun simctl boot "$UDID"
        BOOTED_BY_US=1
    fi
    xcrun simctl bootstatus "$UDID" -b >/dev/null
    DEVICE_READY=1
    ORIG_APPEARANCE="$(xcrun simctl ui "$UDID" appearance 2>/dev/null || true)"
    ORIG_CONTENT_SIZE="$(xcrun simctl ui "$UDID" content_size 2>/dev/null || true)"
    LOCALE="$(xcrun simctl spawn "$UDID" defaults read -g AppleLocale 2>/dev/null || echo unknown)"
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$LAUNCH_PID" ]] && kill -0 "$LAUNCH_PID" 2>/dev/null; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        kill "$LAUNCH_PID" 2>/dev/null || true
    fi
    if [[ $DEVICE_READY -eq 1 ]]; then
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl status_bar "$UDID" clear >/dev/null 2>&1 || true
        [[ -z "$ORIG_APPEARANCE" || "$ORIG_APPEARANCE" == "unsupported" ]] ||
            xcrun simctl ui "$UDID" appearance "$ORIG_APPEARANCE" >/dev/null 2>&1 || true
        [[ -z "$ORIG_CONTENT_SIZE" || "$ORIG_CONTENT_SIZE" == "unknown" ]] ||
            xcrun simctl ui "$UDID" content_size "$ORIG_CONTENT_SIZE" >/dev/null 2>&1 || true
        if [[ $BOOTED_BY_US -eq 1 && $KEEP_BOOTED -eq 0 ]]; then
            log "shutting down $UDID (booted by this run)"
            xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}

# ----------------------------------------------------------------- capture ---

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

image_size() {
    python3 -I -c 'import sys; from PIL import Image; im = Image.open(sys.argv[1]); print(f"{im.width}x{im.height}")' "$1"
}

# First line of $2 starting with marker $1 (PTY \r stripped), or "".
marker_line() { tr -d '\r' <"$2" | grep -m1 -E "^$1( |\$)" || true; }

# Line `CAPTURE_GEOMETRY seq=<$1> …` of log $2 (PTY \r stripped), or "".
geometry_line() { tr -d '\r' <"$2" | grep -m1 -E "^CAPTURE_GEOMETRY seq=$1( |\$)" || true; }

# request_geometry <launch_log> <seq>: post the capture-geometry hook and wait
# (up to GEOMETRY_WAIT_SECONDS) for the app's line with that sequence number.
request_geometry() {
    local deadline=$(( SECONDS + GEOMETRY_WAIT_SECONDS ))
    xcrun simctl spawn "$UDID" notifyutil -p "$GEOMETRY_NOTIFICATION" >/dev/null 2>&1 || return 1
    while [[ -z "$(geometry_line "$2" "$1")" ]]; do
        (( SECONDS < deadline )) && kill -0 "$LAUNCH_PID" 2>/dev/null || return 1
        sleep 0.1
    done
}

# First line of $2 starting with marker $1 AFTER the SCROLL_LANDED line (what
# the app prints once the -scrollToFraction jump has landed), or "".
landed_line() {
    tr -d '\r' <"$2" | awk -v marker="$1" '
        !landed { if ($1 == "SCROLL_LANDED") landed = 1; next }
        $1 == marker { print; exit }'
}

tsv() { local IFS=$'\t'; printf '%s\n' "$*"; }

# capture <cfg> <arm> <fixture> <position> <appearance> <step>
capture() {
    local cfg="$1" arm="$2" fixture="$3" pos="$4" appearance="$5" step="$6"
    local app png launch_log app_sha installed_sha container ready stats want blocks
    app="$(arm_app "$arm")"
    png="$CAPTURES/$cfg-$arm.png"
    launch_log="$CAPTURES/$cfg-$arm.log"
    local -a args=()
    while IFS= read -r word; do args+=("$word"); done < <(arm_args "$arm" "$fixture" "$pos" "$step")
    rm -f "$png"

    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl install "$UDID" "$app"
    app_sha="$(sha256 "$app/ADFReader")"
    container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app)"
    installed_sha="$(sha256 "$container/ADFReader")"
    if [[ "$installed_sha" != "$app_sha" ]]; then
        log "$cfg-$arm: installed sha256 $installed_sha != $app_sha"
        return 1
    fi
    xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged \
        --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
    xcrun simctl ui "$UDID" appearance "$appearance"
    xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE"

    {
        echo "APP: $app"
        echo "APP_SHA256: $app_sha"
        echo "LAUNCH_CMD: xcrun simctl launch --console-pty $UDID $BUNDLE_ID ${args[*]}"
    } >"$launch_log"
    xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" "${args[@]}" >>"$launch_log" 2>&1 &
    LAUNCH_PID=$!

    local deadline=$(( SECONDS + ${READY_TIMEOUT%.*} ))
    while [[ -z "$(marker_line READY "$launch_log")" ]]; do
        if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
            log "$cfg-$arm: app exited before READY (see $launch_log)"
            LAUNCH_PID=""
            return 1
        fi
        if (( SECONDS > deadline )); then
            log "$cfg-$arm: no READY after ${READY_TIMEOUT}s (see $launch_log)"
            xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
            wait "$LAUNCH_PID" 2>/dev/null || true
            LAUNCH_PID=""
            return 1
        fi
        sleep 0.2
    done
    ready="$(marker_line READY "$launch_log")"
    sleep "$SCROLL_WAIT_SECONDS"
    sleep "$SETTLE_SECONDS"
    # The proof of a declared capture is what the app prints once the
    # jump has landed. It is there by now (about 2.6 s after READY); on a
    # slow host, wait for it rather than capture a screen the log does not
    # describe yet.
    if [[ "$(arm_engine "$arm")" != "none" && -n "$(code_rule_for "$fixture" "$pos" "$step")" &&
        -z "$(marker_line SCROLL_LANDED "$launch_log")" ]]; then
        local landed_deadline=$(( SECONDS + LANDED_WAIT_SECONDS ))
        while [[ -z "$(marker_line SCROLL_LANDED "$launch_log")" ]] && (( SECONDS < landed_deadline )) &&
            kill -0 "$LAUNCH_PID" 2>/dev/null; do
            sleep 0.2
        done
        if [[ -n "$(marker_line SCROLL_LANDED "$launch_log")" ]]; then
            sleep 1   # the two lines printed with it, and the frame
        else
            log "$cfg-$arm: no SCROLL_LANDED line ${LANDED_WAIT_SECONDS}s after the settle: its code proof will be INVALID"
        fi
    fi
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then
        log "$cfg-$arm: app exited during settle (see $launch_log)"
        LAUNCH_PID=""
        return 1
    fi
    # Arms B and C of a declared capture: what is on screen right before
    # and right after the screenshot (CAPTURE_GEOMETRY seq=1 and seq=2), so
    # visual_diff.py can tie each scored code box to the row that drew it.
    local bracket=0 geometry_note=""
    [[ "$(arm_engine "$arm")" == "none" || -z "$(code_rule_for "$fixture" "$pos" "$step")" ]] || bracket=1
    if (( bracket )); then
        request_geometry "$launch_log" 1 || geometry_note="no CAPTURE_GEOMETRY seq=1 before the screenshot"
    fi
    xcrun simctl io "$UDID" screenshot --type=png "$png" >/dev/null 2>&1
    if (( bracket )); then
        request_geometry "$launch_log" 2 ||
            geometry_note="${geometry_note:+$geometry_note; }no CAPTURE_GEOMETRY seq=2 after the screenshot"
    fi
    [[ -z "$geometry_note" ]] || log "$cfg-$arm: $geometry_note: its code proof will be INVALID"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    wait "$LAUNCH_PID" 2>/dev/null || true
    LAUNCH_PID=""

    local problems=""
    case "$ready" in
        "READY fixture=$fixture "*) ;;
        *) problems="READY names another fixture: '$ready'" ;;
    esac
    stats="$(marker_line RENDERER_STATS "$launch_log")"
    want="$(expected_renderer "$arm")"
    if [[ $RENDERER_STATS -eq 1 && -n "$want" ]]; then
        case " $stats " in
            *" renderer=$want "*) ;;
            *) problems="${problems:+$problems; }RENDERER_STATS missing or not renderer=$want: '${stats:-absent}'" ;;
        esac
    fi
    [[ -s "$png" ]] || problems="${problems:+$problems; }no screenshot written"
    # A position names blocks[Int(position × blocks)]: it is the same block in
    # every arm only while every arm reports the same READY block count.
    blocks="$(printf '%s\n' "$ready" | tr ' ' '\n' | grep -m1 '^blocks=' || true)"
    if [[ -z "$CFG_BLOCKS" ]]; then
        CFG_BLOCKS="$blocks"
    elif [[ "$blocks" != "$CFG_BLOCKS" ]]; then
        problems="${problems:+$problems; }READY ${blocks:-without blocks=} but an earlier arm of $cfg reported $CFG_BLOCKS: the position names another block"
    fi

    tsv "$cfg-$arm" "$arm" "$fixture" "$pos" "$appearance" "$step" "$CONTENT_SIZE" "$app" "$app_sha" \
        "$installed_sha" "${args[*]}" "$UDID" "$DEVICE_NAME" "$DEVICE_RUNTIME" "$LOCALE" "$ready" \
        "${stats:-}" "$( [[ -s "$png" ]] && sha256 "$png" || echo missing )" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${problems:-ok}" \
        "$(marker_line SCROLL_LANDED "$launch_log")" "$(landed_line RENDERER_STATS "$launch_log")" \
        "$(landed_line TK2_CODE_ROWS "$launch_log")" "$(landed_line TK2_CONTAINER_ROWS "$launch_log")" \
        "$(landed_line TK2_CAPTION_ROWS "$launch_log")" "$(geometry_line 1 "$launch_log")" \
        "$(geometry_line 2 "$launch_log")" >>"$MANIFEST"

    if [[ -n "$problems" ]]; then
        log "$cfg-$arm: $problems"
        return 1
    fi
    if [[ $MASKS_EXPLICIT -eq 0 ]]; then
        local size
        size="$(image_size "$png")"
        [[ "$size" == "$EXPECTED_SIZE" ]] ||
            die "screenshot is $size, default masks are for $EXPECTED_SIZE (iPhone 17 Pro); pass --top-band/--bottom-band/--mask for this device"
    fi
    log "captured $cfg-$arm"
}

CAPTURE_FAILURES=0
if [[ $SKIP_CAPTURE -eq 0 ]]; then
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    prepare_device
    {
        echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host=$(hostname) macOS $(sw_vers -productVersion 2>/dev/null || echo ?) $(uname -m)"
        echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "device=$UDID $DEVICE_NAME $DEVICE_RUNTIME booted_by_this_run=$BOOTED_BY_US"
        echo "other_booted=${OTHER_BOOTED:-none} allow_other_booted=$ALLOW_OTHER_BOOTED"
        echo "list_fixtures=${LIST_FIXTURES[*]}"
        echo "code_captures=${CODE_CAPTURES[*]:-none}"
        echo "locale=$LOCALE content_size=$CONTENT_SIZE (device had: ${ORIG_CONTENT_SIZE:-?}, appearance ${ORIG_APPEARANCE:-?})"
        echo "ref_app=$REF_APP sha256=$(sha256 "$REF_APP/ADFReader")"
        if [[ -n "$APP" && -x "$APP/ADFReader" ]]; then
            echo "app=$APP sha256=$(sha256 "$APP/ADFReader")"
        else
            echo "app=(none: arms $ARMS use --ref-app only)"
        fi
        echo "arms=$ARMS fixtures=${FIXTURE_SPECS[*]} appearances=$APPEARANCES size_steps=$SIZE_STEPS"
        echo "timing=ready_timeout ${READY_TIMEOUT}s, scroll_wait ${SCROLL_WAIT_SECONDS}s, settle ${SETTLE_SECONDS}s"
        echo "renderer_stats_required=$RENDERER_STATS"
        echo "visual_diff_args=${DIFF_ARGS[*]}"
        echo "checkout=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo ?) dirty_paths=$(git -C "$ROOT" status --porcelain 2>/dev/null | grep -c . || true)"
    } >"$OUT/env.txt"
    tsv capture arm fixture position appearance size_step content_size app app_sha256 installed_sha256 \
        argv udid device runtime locale ready_line renderer_stats png_sha256 captured_utc status \
        scroll_landed landed_renderer_stats landed_code_rows landed_container_rows landed_caption_rows \
        geometry_before geometry_after >"$MANIFEST"

    for entry in "${PLAN[@]}"; do
        IFS=$'\t' read -r cfg fixture pos appearance step <<<"$entry"
        CFG_BLOCKS=""
        for arm in $ARMS; do
            capture "$cfg" "$arm" "$fixture" "$pos" "$appearance" "$step" ||
                CAPTURE_FAILURES=$(( CAPTURE_FAILURES + 1 ))
        done
    done
fi

# ------------------------------------------------------------------- score ---

build_pairs 1
[[ ${#PAIR_ARGS[@]} -gt 0 ]] || { log "nothing to compare under $CAPTURES"; exit 1; }
DIFF_STATUS=0
python3 -I "$SCRIPT_DIR/visual_diff.py" --out "$OUT" "${DIFF_ARGS[@]}" "${PAIR_ARGS[@]}" \
    ${CODE_ARGS[@]+"${CODE_ARGS[@]}"} || DIFF_STATUS=$?

echo
echo "captures:  $CAPTURES"
echo "manifest:  $MANIFEST"
echo "scores:    $OUT/scores.csv  $OUT/scores.json"
echo "summary:   $OUT/summary.md"
if (( CAPTURE_FAILURES > 0 )); then
    log "FAIL: $CAPTURE_FAILURES capture(s) failed (their pairs are not scored)"
    exit 1
fi
expected_pairs=0
for arm in A2 B C; do has_arm "$arm" && expected_pairs=$(( expected_pairs + ${#PLAN[@]} )); done
if (( PAIR_COUNT != expected_pairs )); then
    log "FAIL: scored $PAIR_COUNT of $expected_pairs pairs (captures missing under $CAPTURES)"
    exit 1
fi
case "$DIFF_STATUS" in
    0) log "PASS" ;;
    1) log "FAIL: see $OUT/summary.md" ;;
    *) log "visual_diff.py error (exit $DIFF_STATUS)" ;;
esac
exit "$DIFF_STATUS"
