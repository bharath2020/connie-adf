#!/usr/bin/env python3
"""Offline cases for Scripts/lifecycle_agent.py: the pasteboard requests
(PR 3: the Copy test reads the device pasteboard on the host), `record`,
the report, and one request served end to end over the file channel.

USAGE
    python3 -I Scripts/tests/lifecycle_agent_tests.py <workdir>

No simulator and no app: a private fake `xcrun` written into <workdir> is
put first on PATH; it keeps the "device pasteboard" in a file and logs the
`simctl spawn` calls. Standard library only. Exits 1 on any mismatch.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True

SCRIPTS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENT = os.path.join(SCRIPTS, "lifecycle_agent.py")
work = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.environ.get("TMPDIR", "/tmp"), "lifecycle-agent-tests")
os.makedirs(work, exist_ok=True)
work = os.path.realpath(work)
results: list[bool] = []

UDID = "FAKE-UDID-0001"
FAKE_BIN = os.path.join(work, "bin")
BOARD = os.path.join(work, "pasteboard.bin")
SPAWN_LOG = os.path.join(work, "spawn.log")
os.makedirs(FAKE_BIN, exist_ok=True)
with open(os.path.join(FAKE_BIN, "xcrun"), "w", encoding="utf-8") as fh:
    fh.write("""#!/bin/sh
# Fake xcrun for lifecycle_agent_tests.py: simctl pbcopy | pbpaste | spawn.
[ "$1" = simctl ] || { echo "fake xcrun: only simctl" >&2; exit 64; }
[ "$3" = "$FAKE_UDID" ] || { echo "Invalid device: $3" >&2; exit 148; }
case "$2" in
    pbcopy)
        [ -z "${FAKE_PB_FAIL:-}" ] || { echo "pbcopy refused" >&2; exit 1; }
        cat >"$FAKE_PB_FILE" ;;
    pbpaste)
        [ -z "${FAKE_PB_FAIL:-}" ] || { echo "pbpaste refused" >&2; exit 1; }
        cat "$FAKE_PB_FILE" ;;
    spawn) shift 3; echo "$*" >>"$FAKE_SPAWN_LOG" ;;
    *) echo "fake xcrun: simctl $2 not faked" >&2; exit 64 ;;
esac
""")
os.chmod(os.path.join(FAKE_BIN, "xcrun"), 0o755)
os.environ.update(PATH=FAKE_BIN + os.pathsep + os.environ.get("PATH", ""), FAKE_UDID=UDID,
                  FAKE_PB_FILE=BOARD, FAKE_SPAWN_LOG=SPAWN_LOG)
os.environ.pop("FAKE_PB_FAIL", None)
for stale in (BOARD, SPAWN_LOG):
    open(stale, "wb").close()

spec = importlib.util.spec_from_file_location("lifecycle_agent", AGENT)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)


def expect(label: str, got, want) -> None:
    ok = got == want
    results.append(ok)
    print(f"{'ok  ' if ok else 'FAIL'} {label}" + ("" if ok else f"\n       got  {got!r}\n       want {want!r}"))


def error_of(req: dict, args: argparse.Namespace) -> str:
    try:
        agent.handle(req, args)
    except Exception as error:  # the agent reports every failure to the test
        return f"{type(error).__name__}: {error}"
    return "(no error)"


def sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


RESULTS = os.path.join(work, "results.jsonl")
open(RESULTS, "w").close()
args = argparse.Namespace(udid=UDID, channel=os.path.join(work, "channel"), results=RESULTS, log=None)

# ---- pasteboard: exact text both ways ---------------------------------------
sentinel = "ADF-COPY-SENTINEL-5F1C"
expect("pasteboard_set returns the byte count and digest of what it wrote",
       agent.handle({"kind": "pasteboard_set", "text": sentinel}, args),
       {"utf8_bytes": len(sentinel), "sha256": sha(sentinel)})
expect("pasteboard reads the sentinel back unchanged",
       agent.handle({"kind": "pasteboard"}, args),
       {"text": sentinel, "utf8_bytes": len(sentinel), "sha256": sha(sentinel)})

# What a code block's Copy puts there: indentation, blank lines, a trailing
# newline and non-ASCII must all survive (nothing stripped, nothing added).
code = "func f() {\n    let s = \"naïve ✓\"\n\n\treturn\n}\n"
agent.handle({"kind": "pasteboard_set", "text": code}, args)
got = agent.handle({"kind": "pasteboard"}, args)
expect("code with tabs, blank lines, non-ASCII and a trailing newline round-trips exactly", got["text"], code)
expect("utf8_bytes counts bytes, not characters", got["utf8_bytes"], len(code.encode("utf-8")))
expect("sha256 is of the raw bytes", got["sha256"], sha(code))
with open(BOARD, "wb") as fh:
    fh.write(b"one line, no newline")
expect("text the app put there is returned as is (no newline appended)",
       agent.handle({"kind": "pasteboard"}, args)["text"], "one line, no newline")
open(BOARD, "wb").close()
expect("an empty pasteboard is empty text, not an error",
       agent.handle({"kind": "pasteboard"}, args), {"text": "", "utf8_bytes": 0, "sha256": sha("")})

# ---- pasteboard: failures reach the test ------------------------------------
expect("pasteboard_set without text is refused", error_of({"kind": "pasteboard_set"}, args), "RuntimeError: pasteboard_set needs text=<string>")
expect("pasteboard_set with a non-string is refused", error_of({"kind": "pasteboard_set", "text": 7}, args),
       "RuntimeError: pasteboard_set needs text=<string>")
not_text = b"\xff\xfe not text"
with open(BOARD, "wb") as fh:
    fh.write(not_text)
expect("a pasteboard that is not UTF-8 is an error, never a lossy string",
       error_of({"kind": "pasteboard"}, args).split(":", 2)[:2],
       ["RuntimeError", f" pasteboard is not UTF-8 text ({len(not_text)} bytes)"])
os.environ["FAKE_PB_FAIL"] = "1"
expect("a failing simctl pbpaste is an error", error_of({"kind": "pasteboard"}, args),
       "RuntimeError: simctl pbpaste failed: pbpaste refused")
expect("a failing simctl pbcopy is an error", error_of({"kind": "pasteboard_set", "text": "x"}, args),
       "RuntimeError: simctl pbcopy failed: pbcopy refused")
os.environ.pop("FAKE_PB_FAIL")
other = argparse.Namespace(udid="ANOTHER-DEVICE", channel=args.channel, results=RESULTS, log=None)
expect("the request goes to the agent's own device", error_of({"kind": "pasteboard"}, other),
       "RuntimeError: simctl pbpaste failed: Invalid device: ANOTHER-DEVICE")

# ---- existing kinds keep working without an app ------------------------------
expect("rotate posts the Darwin notification through simctl spawn", agent.handle({"kind": "rotate"}, args), {})
expect("the notification name is the app's", open(SPAWN_LOG).read().strip(), "notifyutil -p com.connie.adfreader.rotate")
expect("an unknown kind is an error (no pasteboard access, no fake call)",
       (error_of({"kind": "pasteboard_all"}, args) != "(no error)", open(SPAWN_LOG).read().count("\n")), (True, 1))

# ---- record and report --------------------------------------------------------
agent.handle({"kind": "record", "check": "C1 round trips (code-dense)", "pass": True, "max_drift_px": 1}, args)
agent.handle({"kind": "record", "check": "copy (CP-02)", "pass": True, "utf8_bytes": 42}, args)
entries = [json.loads(line) for line in open(RESULTS) if line.strip()]
expect("record appends one JSON line per check", [e["check"] for e in entries],
       ["C1 round trips (code-dense)", "copy (CP-02)"])
report = os.path.join(work, "lifecycle.md")
status = agent.main(["report", "--results", RESULTS, "--out", report, "--meta", "tests=testC1"])
text = open(report, encoding="utf-8").read()
expect("report exits 0 when every check passed", status, 0)
expect("the report title names the code checks", "PR 3 code: plan §6, C1–C6" in text.splitlines()[0], True)
expect("the report lists each check", ("| C1 round trips (code-dense) | PASS |" in text, "| copy (CP-02) | PASS |" in text),
       (True, True))
agent.handle({"kind": "record", "check": "C2 control", "pass": False, "failure_class": "control_drift"}, args)
status = agent.main(["report", "--results", RESULTS, "--out", report])
expect("a failed check fails the report and keeps its class",
       (status, "| C2 control | **FAIL** (control_drift) |" in open(report, encoding="utf-8").read()), (1, True))
# A Copy test records the code it compared: line breaks, tabs and pipes
# must not break the report's table row.
copied = os.path.join(work, "copied.jsonl")
open(copied, "w").close()
copy_args = argparse.Namespace(udid=UDID, channel=args.channel, results=copied, log=None)
agent.handle({"kind": "record", "check": "5.1 Copy puts the exact code on the pasteboard (code-parity)", "pass": True,
              "block": "0.2", "expected": "if a || b {\n\treturn\n}\n", "pasteboard": "let answer = 42 // CP-01",
              "utf16": 23}, copy_args)
agent.main(["report", "--results", copied, "--out", report])
rows = [line for line in open(report, encoding="utf-8").read().splitlines() if line.startswith("| 5.1 Copy")]
expect("recorded multi-line code stays on one table row, escaped",
       rows, ["| 5.1 Copy puts the exact code on the pasteboard (code-parity) | PASS | block=0.2; "
              "expected=\"if a \\|\\| b {\\n\\treturn\\n}\\n\"; pasteboard=let answer = 42 // CP-01; utf16=23 |"])
empty = os.path.join(work, "empty.jsonl")
open(empty, "w").close()
expect("no recorded check is a failure", agent.main(["report", "--results", empty, "--out", report]), 1)

# ---- K3 column crossing (review D-R5) ------------------------------------------
K3 = "K3 width and type-size changes in containers (containers-parity 0.46)"


def k3_results(name: str, crossed: tuple[bool, bool], passed: bool = True, regular: bool | None = None) -> str:
    """A results file holding one K3 record whose swiftui and textkit2
    arms have crossed_boundary `crossed` and regular_width `regular`
    (default: whether both crossed, as K3 records it; None leaves it out)."""
    path = os.path.join(work, name + ".jsonl")
    regular = all(crossed) if regular is None else regular
    arms = [{"arm": arm, "regular_width": regular, "crossed_boundary": value}
            for arm, value in zip(("swiftui", "textkit2"), crossed)]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"check": K3, "pass": passed, "arms": arms}) + "\n")
    return path


def crossing_report(results: str, *crossing: str) -> tuple[int, str]:
    argv = ["report", "--results", results, "--out", report]
    for path in crossing:
        argv += ["--crossing-results", path]
    status = agent.main(argv)
    rows = [line for line in open(report, encoding="utf-8").read().splitlines() if line.startswith("| K3 column")]
    return status, rows[0] if rows else ""


phone = k3_results("k3-phone", (False, False))
ipad = k3_results("k3-ipad", (True, True))
# A Pro Max K3 whose rotation crossed the column boundary with the engine
# flip (review N2, below): a phone run needs it too, so the D-R5 case that
# passes carries it.
rotation_evidence = os.path.join(work, "k3-promax.jsonl")
with open(rotation_evidence, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"check": K3, "pass": True, "arms": [
        {"arm": "swiftui", "regular_width": False, "crossed_boundary": False, "rotation_crossable": True,
         "crossed_rotation": True, "rotation_textkit2_leaves": [0, 0, 0]},
        {"arm": "textkit2", "regular_width": False, "crossed_boundary": False, "rotation_crossable": True,
         "crossed_rotation": True, "rotation_textkit2_leaves": [4, 0, 4], "in_window_rows_rotation": [40, 8, 40],
         "release_at_top": True, "release_off_window": 0}]}) + "\n")
status, row = crossing_report(phone, rotation_evidence)
expect("D-R5: a phone K3 (passed, not crossable) alone fails the report", (status, "| **FAIL** |" in row), (1, True))
expect("... the row says how to supply the crossing", "--k3-crossing" in row, True)
status, row = crossing_report(phone, ipad, rotation_evidence)
expect("D-R5: ... and passes with an iPad run's crossing K3 as --crossing-results", (status, "| PASS |" in row), (0, True))
expect("... naming that file", f"source={ipad}" in row, True)
status, row = crossing_report(ipad)
expect("D-R5: a run whose own K3 crossed (an iPad destination) passes on its own", (status, "source=this run" in row),
       (0, True))
status, row = crossing_report(phone, k3_results("k3-ipad-failed", (True, True), passed=False))
expect("D-R5: a crossing K3 that failed is no evidence", (status, "| **FAIL** |" in row), (1, True))
status, row = crossing_report(phone, k3_results("k3-ipad-one-arm", (True, False)))
expect("D-R5: a K3 that crossed on one arm only is no evidence", (status, "| **FAIL** |" in row), (1, True))
status, row = crossing_report(phone, os.path.join(work, "no-such-run.jsonl"))
expect("D-R5: a missing crossing file is no evidence", (status, "| **FAIL** |" in row), (1, True))
status, row = crossing_report(copied, phone)
expect("D-R5: a run without K3 gets no crossing row", (status, row), (0, ""))
status, row = crossing_report(phone, k3_results("k3-crossed-compact", (True, True), regular=False))
expect("Astra R5: a crossing K3 not from a regular-width destination is no evidence", (status, "| **FAIL** |" in row),
       (1, True))
legacy = os.path.join(work, "k3-legacy.jsonl")
with open(legacy, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({"check": K3, "pass": True, "arms": [{"arm": "swiftui", "crossed_boundary": True},
                                                             {"arm": "textkit2", "crossed_boundary": True}]}) + "\n")
status, row = crossing_report(phone, legacy)
expect("Astra R5: a crossing K3 without regular_width (an older build) is no evidence",
       (status, "| **FAIL** |" in row), (1, True))

# ---- K3 rotation crossing (review N2) ------------------------------------------


def k3_record(name: str, arms: list[dict], passed: bool = True) -> str:
    path = os.path.join(work, name + ".jsonl")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps({"check": K3, "pass": passed, "arms": arms}) + "\n")
    return path


def k3_arm(arm: str, regular: bool = False, crossed: bool = False, rotation: bool = False,
           rotated: bool | None = None, leaves: list | None = None, in_window: list | None = None,
           at_top: bool | None = None, off_window: object = "default") -> dict:
    """One K3 arm: `regular`/`crossed` as the D-R5 fields; `rotation` is
    rotation_crossable, `rotated` crossed_rotation (default: rotation),
    `leaves` rotation_textkit2_leaves (default: what the arm draws when it
    rotates across: textkit2 > 0 -> 0 -> > 0, swiftui 0 throughout; a
    compact phone's textkit2 arm stays > 0). C60 rows: `in_window`
    in_window_rows_rotation (default on textkit2: 40 portrait, 8
    landscape, one per stage; the swiftui arm records null), `at_top`
    release_at_top and `off_window` release_off_window (default on a
    crossing textkit2 arm: True, 0; else null)."""
    if leaves is None:
        leaves = [0, 0, 0] if arm == "swiftui" else ([4, 0, 4] if rotation else [4, 4, 4])
    released = arm == "textkit2" and rotation
    if in_window is None:
        in_window = [None] * len(leaves) if arm == "swiftui" else [8 if i % 2 else 40 for i in range(len(leaves))]
    return {"arm": arm, "regular_width": regular, "crossed_boundary": crossed, "rotation_crossable": rotation,
            "crossed_rotation": rotation if rotated is None else rotated, "rotation_textkit2_leaves": leaves,
            "in_window_rows_rotation": in_window,
            "release_at_top": (True if released else None) if at_top is None else at_top,
            "release_off_window": (0 if released else None) if off_window == "default" else off_window}


def rows_of(results: str, *crossing: str) -> tuple[int, dict[str, str]]:
    """The report's exit status and its K3 crossing rows by check prefix
    ("K3 column", "K3 rotation"; a row the report did not add is "")."""
    argv = ["report", "--results", results, "--out", report]
    for path in crossing:
        argv += ["--crossing-results", path]
    status = agent.main(argv)
    lines = open(report, encoding="utf-8").read().splitlines()
    return status, {key: next((l for l in lines if l.startswith("| " + key)), "")
                    for key in ("K3 column", "K3 rotation")}


ipad_n2 = k3_record("n2-ipad", [k3_arm(a, regular=True, crossed=True) for a in ("swiftui", "textkit2")])
promax = k3_record("n2-promax", [k3_arm(a, rotation=True) for a in ("swiftui", "textkit2")])
phone17 = k3_record("n2-phone", [k3_arm(a) for a in ("swiftui", "textkit2")])
status, rows = rows_of(phone17, ipad_n2, promax)
expect("N2: a phone K3 passes with an iPad crossing and a Pro Max rotation crossing",
       (status, "| PASS |" in rows["K3 column"], "| PASS |" in rows["K3 rotation"],
        f"source={promax}" in rows["K3 rotation"]), (0, True, True, True))
two_trips = k3_record("n2-promax-two-trips", [k3_arm("swiftui", rotation=True, leaves=[0, 0, 0, 0, 0]),
                                              k3_arm("textkit2", rotation=True, leaves=[6, 0, 6, 0, 6])])
status, rows = rows_of(phone17, ipad_n2, two_trips)
expect("N2: a Pro Max record with two round trips that both flipped is evidence",
       (status, "| PASS |" in rows["K3 rotation"]), (0, True))
landscape_varies = k3_record("n2-promax-landscape-varies",
                             [k3_arm("swiftui", rotation=True, leaves=[0, 0, 0, 0, 0]),
                              k3_arm("textkit2", rotation=True, leaves=[6, 0, 6, 0, 6], in_window=[40, 8, 40, 9, 40])])
status, rows = rows_of(phone17, ipad_n2, landscape_varies)
expect("C60: rows in a window are compared at the portrait stages only (landscape recorded)",
       (status, "| PASS |" in rows["K3 rotation"]), (0, True))
status, rows = rows_of(phone17, ipad_n2)
expect("N2: ... and fails without the Pro Max record (the iPad crossing alone flips no engine)",
       (status, "| PASS |" in rows["K3 column"], "| **FAIL** |" in rows["K3 rotation"]), (1, True, True))
expect("... the row says how to supply the rotation crossing", "Pro Max" in rows["K3 rotation"] and "--k3-crossing"
       in rows["K3 rotation"], True)
status, rows = rows_of(promax, ipad_n2)
expect("N2: a Pro Max run's own rotation crossing passes its row (this run), with the iPad's crossing",
       (status, "source=this run" in rows["K3 rotation"], "| PASS |" in rows["K3 column"]), (0, True, True))
status, rows = rows_of(promax)
expect("N2: ... but a Pro Max run still needs the iPad crossing (D-R5 kept as is)",
       (status, "| **FAIL** |" in rows["K3 column"], "| PASS |" in rows["K3 rotation"]), (1, True, True))
status, rows = rows_of(ipad_n2)
expect("N2: an iPad run (regular in both orientations) gets no rotation row and passes on its own crossing",
       (status, rows["K3 rotation"], "| PASS |" in rows["K3 column"]), (0, "", True))
status, rows = rows_of(copied, promax)
expect("N2: a run without K3 gets no rotation row", (status, rows["K3 rotation"]), (0, ""))
no_flip = k3_record("n2-promax-no-flip", [k3_arm("swiftui", rotation=True),
                                          k3_arm("textkit2", rotation=True, leaves=[4, 4, 4])])
status, rows = rows_of(phone17, ipad_n2, no_flip)
expect("N2: a Pro Max K3 whose column text stayed TextKit 2 side by side (no flip) is no evidence",
       (status, "| **FAIL** |" in rows["K3 rotation"]), (1, True))
for name, arms in (
        ("n2-tk2-never", [k3_arm("swiftui", rotation=True), k3_arm("textkit2", rotation=True, leaves=[0, 0, 0])]),
        ("n2-tk2-not-back", [k3_arm("swiftui", rotation=True), k3_arm("textkit2", rotation=True, leaves=[4, 0, 0])]),
        ("n2-swiftui-tk2", [k3_arm("swiftui", rotation=True, leaves=[0, 1, 0]), k3_arm("textkit2", rotation=True)]),
        ("n2-not-crossed", [k3_arm("swiftui", rotation=True, rotated=False),
                            k3_arm("textkit2", rotation=True, rotated=False)]),
        ("n2-one-arm", [k3_arm("swiftui", rotation=True), k3_arm("textkit2", rotation=True, rotated=False)]),
        ("n2-compact", [k3_arm("swiftui", rotation=False, rotated=True),
                        k3_arm("textkit2", rotation=False, rotated=True, leaves=[4, 0, 4])]),
        ("n2-textkit2-only", [k3_arm("textkit2", rotation=True)]),
        ("n2-leaves-missing", [{k: v for k, v in k3_arm(a, rotation=True).items() if k != "rotation_textkit2_leaves"}
                               for a in ("swiftui", "textkit2")]),
        ("n2-leaves-bool", [k3_arm("swiftui", rotation=True, leaves=[False, False, False]),
                            k3_arm("textkit2", rotation=True, leaves=[True, False, True])]),
        ("n2-second-trip-no-flip", [k3_arm("swiftui", rotation=True, leaves=[0, 0, 0, 0, 0]),
                                    k3_arm("textkit2", rotation=True, leaves=[6, 0, 6, 6, 6])]),
        ("n2-leaves-even", [k3_arm("swiftui", rotation=True, leaves=[0, 0, 0, 0]),
                            k3_arm("textkit2", rotation=True, leaves=[6, 0, 6, 0])]),
        ("C60 in-window mismatch after a trip", [k3_arm("swiftui", rotation=True),
                                                 k3_arm("textkit2", rotation=True, in_window=[40, 8, 41])]),
        ("C60 in-window mismatch after the second trip",
         [k3_arm("swiftui", rotation=True, leaves=[0, 0, 0, 0, 0]),
          k3_arm("textkit2", rotation=True, leaves=[6, 0, 6, 0, 6], in_window=[40, 8, 40, 8, 52])]),
        ("C60 in-window not applicable (no off-window count)",
         [k3_arm("swiftui", rotation=True), k3_arm("textkit2", rotation=True, in_window=[None, None, None])]),
        ("C60 in-window one count short", [k3_arm("swiftui", rotation=True),
                                           k3_arm("textkit2", rotation=True, in_window=[40, 40])]),
        ("C60 off-window rows left at the top", [k3_arm("swiftui", rotation=True),
                                                 k3_arm("textkit2", rotation=True, off_window=3)]),
        ("C60 release not applicable (no off-window count)",
         [k3_arm("swiftui", rotation=True), k3_arm("textkit2", rotation=True, off_window=None)]),
        ("C60 release read away from the top", [k3_arm("swiftui", rotation=True),
                                                k3_arm("textkit2", rotation=True, at_top=False)])):
    status, rows = rows_of(phone17, ipad_n2, k3_record(name, arms))
    expect(f"N2: {name} is no rotation evidence", (status, "| **FAIL** |" in rows["K3 rotation"]), (1, True))
failed = k3_record("n2-promax-failed", [k3_arm(a, rotation=True) for a in ("swiftui", "textkit2")], passed=False)
status, rows = rows_of(phone17, ipad_n2, failed)
expect("N2: a Pro Max K3 that failed is no evidence", (status, "| **FAIL** |" in rows["K3 rotation"]), (1, True))
status, rows = rows_of(phone17, ipad_n2, os.path.join(work, "no-such-promax.jsonl"))
expect("N2: a missing rotation file is no evidence", (status, "| **FAIL** |" in rows["K3 rotation"]), (1, True))
status, rows = rows_of(phone, ipad)
expect("N2: a K3 record without the rotation fields (an older build) gets the row and fails it",
       (status, "| **FAIL** |" in rows["K3 rotation"]), (1, True))

# ---- one request over the file channel ----------------------------------------
channel = os.path.join(work, "channel-serve")
os.makedirs(channel, exist_ok=True)
for name in os.listdir(channel):
    os.unlink(os.path.join(channel, name))
with open(BOARD, "wb") as fh:
    fh.write(code.encode("utf-8"))
server = subprocess.Popen([sys.executable, "-I", "-u", AGENT, "serve", "--udid", UDID, "--channel", channel,
                           "--results", os.path.join(work, "serve-results.jsonl"),
                           "--log", os.path.join(work, "agent.log")], env=os.environ.copy())
answers = {}
try:
    for name, body in (("1", {"kind": "pasteboard"}), ("2", {"kind": "pasteboard_set"})):
        staging = os.path.join(channel, f"tmp-{name}.json")
        with open(staging, "w", encoding="utf-8") as fh:
            json.dump(body, fh)
        os.rename(staging, os.path.join(channel, f"req-{name}.json"))
        response = os.path.join(channel, f"resp-{name}.json")
        deadline = time.monotonic() + 10
        while not os.path.exists(response) and time.monotonic() < deadline:
            time.sleep(0.05)
        answers[name] = json.load(open(response, encoding="utf-8")) if os.path.exists(response) else None
finally:
    server.send_signal(signal.SIGTERM)
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        server.kill()
expect("served pasteboard read answers ok with the exact text",
       answers["1"] and (answers["1"].get("ok"), answers["1"].get("text")), (True, code))
expect("a served failure answers ok=false with the reason",
       answers["2"], {"ok": False, "error": "RuntimeError: pasteboard_set needs text=<string>"})
expect("the agent stops on SIGTERM", server.returncode, 0)

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
