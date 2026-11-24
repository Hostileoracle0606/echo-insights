#!/usr/bin/env python3
"""EC-10: latency and naturalness report for a Simulator or device run.

Reads the app's [voice] log of a session (scripts/ec01-rebuild-test.sh, or a
`log stream` capture) and the session's saved transcript on staging, and
reports:

  * time from the end of the user's turn to Lumen's first audio, p50 / p95 /
    max, for normal turns, tool turns and the first turn after a rebuild
    (the rebuild turn must sit inside the normal-turn distribution);
  * each rebuild: why, how long it took, the context it was seeded with;
  * boundary checks on the first Lumen line after each rebuild:
      - re-greeting ("hi", "welcome back", ...),
      - repeating something Lumen already said (word overlap with any earlier
        line of the session at or above 0.6),
      - re-asking the question that was pending at the rebuild instead of
        continuing it.

The blind listening test (reviewers mark where they hear a reset) needs
people; this report is the automated half of the gate.

Usage:
  scripts/ec10-report.py LOG [--notebook ID] [--out REPORT.md]
  scripts/ec10-report.py --self-test
"""
import argparse
import json
import re
import statistics
import sys
from datetime import datetime, timezone

LATENCY = re.compile(r"\[voice\]\[latency\] (typed|spoken) turn → reply audio \+(\d+)ms(.*)")
REBUILD_START = re.compile(r"\[voice\]\[rebuild\] start reason=(\w+)")
REBUILD_DONE = re.compile(r"\[voice\]\[rebuild\] (seeded|did not complete) in (\d+)ms")
REBUILD_CONTEXT = re.compile(r"\[voice\]\[rebuild\] context ~(\d+) tokens, (\d+) turns")
STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d+)([+-]\d{4})?")
GREETING = re.compile(r"^\W*(hi|hey|hello|welcome back|good (morning|afternoon|evening)|nice to (see|hear) you)\b",
                      re.IGNORECASE)


def parse_log(lines, tz=None):
    """Latency rows and rebuild events, in order, with UTC times."""
    # `log stream` writes local time with no offset.
    tz = tz or datetime.now().astimezone().tzinfo
    rows, rebuilds, after_rebuild = [], [], False
    for line in lines:
        m = STAMP.match(line)
        at = None
        if m:
            offset = m.group(3)
            fmt = "%Y-%m-%d %H:%M:%S.%f%z" if offset else "%Y-%m-%d %H:%M:%S.%f"
            raw = f"{m.group(1)} {m.group(2)}{offset or ''}"
            at = datetime.strptime(raw, fmt)
            at = at.astimezone(timezone.utc) if at.tzinfo else at.replace(tzinfo=tz).astimezone(timezone.utc)
        if (r := REBUILD_START.search(line)):
            rebuilds.append({"at": at, "reason": r.group(1), "ms": None, "ok": None, "tokens": None, "turns": None})
            continue
        if (r := REBUILD_CONTEXT.search(line)) and rebuilds:
            rebuilds[-1]["tokens"], rebuilds[-1]["turns"] = int(r.group(1)), int(r.group(2))
            continue
        if (r := REBUILD_DONE.search(line)) and rebuilds:
            rebuilds[-1]["ms"], rebuilds[-1]["ok"] = int(r.group(2)), r.group(1) == "seeded"
            after_rebuild = rebuilds[-1]["ok"]
            continue
        if (r := LATENCY.search(line)):
            rows.append({
                "at": at,
                "input": r.group(1),
                "kind": "tool" if "tool call" in r.group(3) else "plain",
                "ms": int(r.group(2)),
                "after_rebuild": after_rebuild,
            })
            after_rebuild = False
    return rows, rebuilds


def words(text):
    return set(re.findall(r"[a-z0-9']+", text.lower()))


def overlap(a, b):
    wa, wb = words(a), words(b)
    return len(wa & wb) / len(wa | wb) if wa and wb else 0.0


def boundary_checks(rebuilds, turns):
    """For each completed rebuild: Lumen's first line after it, checked."""
    results = []
    for rb in rebuilds:
        if not rb["ok"] or rb["at"] is None:
            continue
        # Lines are stamped when they finish, so a reply begun before the
        # rebuild can land after it: the rebuild turn is Lumen's reply to the
        # first user turn after the rebuild.
        first_user = next((t for t in turns if t["at"] >= rb["at"] and t["speaker"] == "user"), None)
        if first_user is None:
            continue
        before = [t for t in turns if t["at"] < first_user["at"]]
        after = [t for t in turns if t["at"] > first_user["at"] and t["speaker"] == "assistant"]
        if not after:
            continue
        first = after[0]["text"]
        lumen_before = [t["text"] for t in before if t["speaker"] == "assistant"]
        pending = next((t["text"] for t in reversed(before) if t["speaker"] == "assistant" and "?" in t["text"]), None)
        questions = lambda text: [q.strip() for q in re.findall(r"[^.!?]*\?", text)]
        repeat = max((overlap(first, earlier) for earlier in lumen_before), default=0.0)
        reasked = bool(pending) and any(
            overlap(q, p) >= 0.6 for q in questions(first) for p in questions(pending))
        results.append({
            "reason": rb["reason"],
            "line": first,
            "greeting": bool(GREETING.search(first)),
            "repeat": round(repeat, 2),
            "reasked": reasked,
        })
    return results


def percentile(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(p * (len(ordered) - 1)))]


def report(rows, rebuilds, checks, source):
    out = [f"# EC-10 run report", "", f"Source: {source}", "", "## Time to first audio", "",
           "| turn | n | p50 | p95 | max |", "|---|---|---|---|---|"]
    groups = {}
    for r in rows:
        label = f"{r['input']} {r['kind']}" + (", first after rebuild" if r["after_rebuild"] else "")
        groups.setdefault(label, []).append(r["ms"])
    for label in sorted(groups):
        v = groups[label]
        out.append(f"| {label} | {len(v)} | {percentile(v, .5)} ms | {percentile(v, .95)} ms | {max(v)} ms |")
    out.append("")
    for kind in ("plain", "tool"):
        normal = [r["ms"] for r in rows if not r["after_rebuild"] and r["kind"] == kind]
        rebuilt = [r["ms"] for r in rows if r["after_rebuild"] and r["kind"] == kind]
        if normal and rebuilt:
            inside = max(rebuilt) <= percentile(normal, .95)
            out.append(f"First {kind} turn after a rebuild within the normal {kind} p95 "
                       f"({percentile(normal, .95)} ms): {'yes' if inside else 'no'} (worst {max(rebuilt)} ms).")
    out += ["", "## Rebuilds", "", "| reason | seeded in | context | turns replayed |", "|---|---|---|---|"]
    for rb in rebuilds:
        out.append(f"| {rb['reason']} | {rb['ms'] if rb['ms'] is not None else '—'} ms "
                   f"{'' if rb['ok'] else '(did not complete)'} | "
                   f"~{rb['tokens'] if rb['tokens'] is not None else '?'} tokens | {rb['turns'] if rb['turns'] is not None else '?'} |")
    out += ["", "## Boundary checks (first Lumen line after each rebuild)", "",
            "| reason | re-greets | repeats (overlap) | re-asks pending question | line |", "|---|---|---|---|---|"]
    for c in checks:
        out.append(f"| {c['reason']} | {'FAIL' if c['greeting'] else 'ok'} | "
                   f"{'FAIL' if c['repeat'] >= 0.6 else 'ok'} ({c['repeat']}) | {'FAIL' if c['reasked'] else 'ok'} | "
                   f"{c['line'][:90].replace('|', '/')} |")
    failures = sum(c["greeting"] or c["repeat"] >= 0.6 or c["reasked"] for c in checks)
    out += ["", f"Boundary failures: {failures} of {len(checks)} rebuild turns.", ""]
    return "\n".join(out)


def parse_ts(text):
    """ISO time as UTC; any fraction length (Python 3.9 wants 0, 3 or 6 digits)."""
    m = re.match(r"^(.*T\d\d:\d\d:\d\d)(?:\.(\d+))?(.*)$", text)
    fraction = ((m.group(2) or "") + "000000")[:6]
    return datetime.fromisoformat(f"{m.group(1)}.{fraction}{m.group(3)}").astimezone(timezone.utc)


def transcript(notebook):
    """The session's saved turns from staging, as the test account."""
    import importlib.util, os
    spec = importlib.util.spec_from_file_location(
        "fact_eval", os.path.join(os.path.dirname(os.path.abspath(__file__)), "fact-eval.py"))
    fe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fe)
    status, auth = fe.call("POST", f"{fe.URL}/auth/v1/token?grant_type=password",
                           {"email": fe.cfg["STAGING_TEST_EMAIL"], "password": fe.cfg["STAGING_TEST_PASSWORD"]})
    token = auth["access_token"]
    if not notebook:
        status, rows = fe.call("GET", f"{fe.URL}/rest/v1/notebooks?select=id&order=started_at.desc&limit=1", None, token)
        notebook = rows[0]["id"]
    status, rows = fe.call("GET", f"{fe.URL}/rest/v1/conversation_turns?select=speaker,text,created_at"
                                  f"&notebook_id=eq.{notebook}&order=created_at", None, token)
    return notebook, [{"speaker": r["speaker"], "text": r["text"],
                       "at": parse_ts(r["created_at"])} for r in rows]


def self_test():
    log = """2026-11-22 17:00:00.000-0500 flutter: [voice][latency] typed turn → reply audio +900ms
2026-11-22 17:00:10.000-0500 flutter: [voice][latency] typed turn → reply audio +1000ms
2026-11-22 17:00:20.000-0500 flutter: [voice][latency] typed turn → reply audio +2400ms (tool call at +100ms)
2026-11-22 17:00:30.000-0500 flutter: [voice][rebuild] start reason=turnBudget turns=3 age=30s
2026-11-22 17:00:30.100-0500 flutter: [voice][rebuild] context ~1200 tokens, 6 turns
2026-11-22 17:00:30.700-0500 flutter: [voice][rebuild] seeded in 700ms
2026-11-22 17:00:40.000-0500 flutter: [voice][latency] typed turn → reply audio +950ms""".splitlines()
    rows, rebuilds = parse_log(log)
    assert [r["after_rebuild"] for r in rows] == [False, False, False, True], rows
    assert rows[2]["kind"] == "tool"
    assert rebuilds[0]["reason"] == "turnBudget" and rebuilds[0]["ms"] == 700 and rebuilds[0]["tokens"] == 1200
    at = lambda s: datetime.fromisoformat(f"2026-11-22T22:00:{s}+00:00")
    turns = [
        {"speaker": "assistant", "text": "What did you eat at the market?", "at": at("05")},
        # Begun before the rebuild, finished just after it: not the rebuild turn.
        {"speaker": "assistant", "text": "Fresh fruit is the best part of a market.", "at": at("31")},
        {"speaker": "user", "text": "Mostly fruit.", "at": at("35")},
        {"speaker": "assistant", "text": "Hey! What did you eat at the market?", "at": at("41")},
    ]
    checks = boundary_checks(rebuilds, turns)
    assert checks[0]["greeting"] and checks[0]["reasked"] and checks[0]["repeat"] >= 0.6, checks
    assert checks[0]["line"] == "Hey! What did you eat at the market?", checks
    good = boundary_checks(rebuilds, turns[:3] + [{"speaker": "assistant", "text": "Fruit sounds right for a hot day.", "at": at("41")}])
    assert not good[0]["greeting"] and not good[0]["reasked"] and good[0]["repeat"] < 0.6, good
    text = report(rows, rebuilds, checks, "self-test")
    assert "| typed plain, first after rebuild | 1 | 950 ms" in text, text
    assert "within the normal plain p95 (1000 ms): yes" in text, text
    assert "Boundary failures: 1 of 1" in text, text
    assert parse_ts("2026-11-23T00:36:48.78644+00:00").microsecond == 786440
    assert parse_ts("2026-11-23T00:36:48+00:00").second == 48
    print("self-test passed")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("log", nargs="?")
    parser.add_argument("--notebook")
    parser.add_argument("--out")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.log:
        parser.error("LOG is required")
    rows, rebuilds = parse_log(open(args.log, errors="replace"))
    notebook, turns = transcript(args.notebook)
    text = report(rows, rebuilds, boundary_checks(rebuilds, turns), f"{args.log}, notebook {notebook}")
    if args.out:
        open(args.out, "w").write(text)
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
