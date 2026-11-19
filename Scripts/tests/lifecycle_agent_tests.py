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


def k3_results(name: str, crossed: tuple[bool, bool], passed: bool = True) -> str:
    """A results file holding one K3 record whose swiftui and textkit2
    arms have crossed_boundary `crossed`."""
    path = os.path.join(work, name + ".jsonl")
    arms = [{"arm": arm, "crossed_boundary": value} for arm, value in zip(("swiftui", "textkit2"), crossed)]
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
status, row = crossing_report(phone)
expect("D-R5: a phone K3 (passed, not crossable) alone fails the report", (status, "| **FAIL** |" in row), (1, True))
expect("... the row says how to supply the crossing", "--k3-crossing" in row, True)
status, row = crossing_report(phone, ipad)
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
