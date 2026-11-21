#!/usr/bin/env python3
"""make-perf-mixed.py - build Fixtures/perf-mixed.json for the Instruments
profile check (Scripts/perf-instruments.sh, docs/Perf-Instruments.md).

    python3 -I Tools/make-perf-mixed.py

perf-mixed is one performance-heavy document that a ~60 s autoscroll
crosses end to end. It is composed, deterministically and without
randomness, from blocks of the generated fixtures already in Fixtures/ (so
it renders on every ref that can render those) plus a few hand-built
smart-link blocks. It has two parts, in this order:

1. The list section comes FIRST: a level-1 heading, then list-dense.json's
   top-level blocks [LIST_START, LIST_START + LIST_BLOCKS) verbatim. That is
   8 whole cycles of list-dense's 20-block pattern (7 bullet, 6 ordered,
   4 task, 3 decision), so the mix matches the full fixture, and the blocks
   are the TextKit 2-eligible list rows of GitHub issue 10. list-dense's
   600 blocks scroll in ~116 s at 1,200 pt/s, so this section scrolls in
   ~31 s and occupies the start of the scroll window; perf_instruments.py
   measures it with --list-window-s (perf-instruments.sh default
   LIST_WINDOW_S, a little under the estimate so the window ends before
   the mixed sections' rows start to materialise).

2. The mixed sections (unchanged since the first version), where every
   section mixes the expensive families:

    heading, 2 mixed-mark paragraphs (text-dense)
    8 dense list blocks: bullet, ordered, task, decision (list-dense)
    a smart-link paragraph (2 inlineCards) and a blockCard
    2 code blocks (code-dense)
    a 12-row table slice with its header (giant-table)
    2 images (media-gallery, local placeholder:// urls)
    a long paragraph (a ~2,500-character slice of long-paragraph)
    a panel (kitchen-sink) and a blockquote

No embedCard (YouTube) and nothing else that touches the network: a
profile must not depend on the host's connection.

Re-running the script rewrites the same bytes. Changing it changes the
measured workload, so a change here invalidates baselines recorded against
the old document: compare refs that bundle the same perf-mixed.json
(perf-instruments.sh copies the candidate tree's file into both builds).
"""

import json
import os
import sys

LIST_START = 0
LIST_BLOCKS = 160
# Measured: list-dense's 600 top-level blocks scroll in ~116 s at 1,200 pt/s.
LIST_DENSE_BLOCKS = 600
LIST_DENSE_SCROLL_S = 116.0
# Scripts/perf-instruments.sh --list-window-s default; keep the two in step.
LIST_WINDOW_S = 28

SECTIONS = 7
LISTS_PER_SECTION = 8
TABLE_ROWS = 12
LONG_PARAGRAPH_NODES = 40

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Fixtures")


def load(name):
    with open(os.path.join(FIXTURES, name + ".json"), encoding="utf-8") as f:
        return json.load(f)["content"]


def text(value, marks=None):
    node = {"type": "text", "text": value}
    if marks:
        node["marks"] = marks
    return node


def smart_link_paragraph(i):
    return {
        "type": "paragraph",
        "content": [
            text("Tracked in "),
            {"type": "inlineCard",
             "attrs": {"url": f"https://example.atlassian.net/browse/PERF-{i}"}},
            text(", design notes in "),
            {"type": "inlineCard",
             "attrs": {"url": f"https://example.atlassian.net/wiki/pages/{1000 + i}"}},
            text(" and the "),
            text("rollout checklist", [{"type": "link", "attrs": {
                "href": f"https://example.com/rollout/{i}"}}]),
            text("."),
        ],
    }


def build():
    paragraphs = [b for b in load("text-dense") if b["type"] == "paragraph"]
    lists = load("list-dense")
    codes = load("code-dense")
    table = [b for b in load("giant-table") if b["type"] == "table"][0]
    images = [b for b in load("media-gallery") if b["type"] == "mediaSingle"]
    long_nodes = [b for b in load("long-paragraph")
                  if b["type"] == "paragraph"][0]["content"]
    sink = load("kitchen-sink")
    panels = [b for b in sink if b["type"] == "panel"]
    quote = [b for b in sink if b["type"] == "blockquote"][0]

    # list-dense groups each family together (bullet, ordered, task,
    # decision); interleave so every section gets all four.
    families = {}
    for block in lists:
        families.setdefault(block["type"], []).append(block)
    order = ["bulletList", "orderedList", "taskList", "decisionList"]
    mixed_lists = []
    for n in range(max(len(v) for v in families.values())):
        for family in order:
            if n < len(families[family]):
                mixed_lists.append(families[family][n])

    # The list section comes first, so it fills the start of the scroll
    # window (perf_instruments.py --list-window-s).
    content = [{
        "type": "heading", "attrs": {"level": 1},
        "content": [text("Perf mixed: dense lists")],
    }]
    content += lists[LIST_START:LIST_START + LIST_BLOCKS]

    header, rows = table["content"][0], table["content"][1:]
    content.append({
        "type": "heading", "attrs": {"level": 1},
        "content": [text("Perf mixed: lists, tables, code, media, links")],
    })
    for s in range(SECTIONS):
        content.append({"type": "heading", "attrs": {"level": 2},
                        "content": [text(f"Section {s + 1}")]})
        content += paragraphs[2 * s:2 * s + 2]
        content += mixed_lists[LISTS_PER_SECTION * s:LISTS_PER_SECTION * (s + 1)]
        content.append(smart_link_paragraph(s))
        content.append({"type": "blockCard", "attrs": {
            "url": f"https://example.atlassian.net/browse/ADF-{100 + s}"}})
        content += codes[2 * s:2 * s + 2]
        content.append({
            "type": "table", "attrs": table.get("attrs", {}),
            "content": [header] + rows[TABLE_ROWS * s:TABLE_ROWS * (s + 1)],
        })
        content += images[2 * s:2 * s + 2]
        start = LONG_PARAGRAPH_NODES * s
        content.append({"type": "paragraph",
                        "content": long_nodes[start:start + LONG_PARAGRAPH_NODES]})
        content.append(panels[s % len(panels)])
        content.append(quote)
    content.append({"type": "paragraph",
                    "content": [text("End of perf-mixed.")]})
    return {"version": 1, "type": "doc", "content": content}


def main():
    doc = build()
    out = os.path.join(FIXTURES, "perf-mixed.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    est = LIST_DENSE_SCROLL_S * LIST_BLOCKS / LIST_DENSE_BLOCKS
    print(f"wrote {out}: {len(doc['content'])} top-level blocks")
    print(f"list section FIRST: blocks 0-{LIST_BLOCKS} (heading + list-dense "
          f"[{LIST_START}, {LIST_START + LIST_BLOCKS})), ~{est:.0f} s of scroll; "
          f"perf-instruments.sh --list-window-s default {LIST_WINDOW_S}")
    print(f"mixed sections: blocks {LIST_BLOCKS + 1}-{len(doc['content']) - 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
