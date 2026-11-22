#!/usr/bin/env python3
"""EC-03 labelled fixtures, end to end on staging with the real model.

For each case: a fresh notebook for the staging test account, then each
utterance in order goes through the local runtime's extraction (real Gemini),
commit_notebook (entities and the entry), and record_memory_facts, exactly
as the app does. The expected facts are then read back with
get_memory_fact / get_memory_fact_history. The notebook is deleted at the
end, which deletes its entries and their facts.

Needs: the local runtime on :8787 (scripts/ec01-rebuild-test.sh runtime) and
.env.staging + .env.staging-account (gitignored). Refuses production.

Usage: scripts/fact-eval.py [case-name ...]
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNTIME = "http://127.0.0.1:8787"
PRODUCTION_REFS = {"bjoevzvsdlhlcjywpyfx"}

# A spoken time for the turns: Sunday 22 Nov 2026, 5:23 pm at UTC-5.
SPOKEN_AT = "2026-11-22T17:23:00-05:00"

CASES = [
    {
        "name": "same goal, different words",
        "turns": ["My savings goal is 5k.", "I bumped my monthly savings target up to 6k."],
        "expect": [("savings-goal", None, "current", 6000), ("savings-goal", None, "previous", 5000)],
        "asks": [
            ("What's my savings goal now?", "savings goal", "6000"),
            ("What was my savings goal before?", "savings goal", "5000"),
            ("How much did my savings goal go up?", "savings goal", "up 1000"),
        ],
    },
    {
        "name": "from X to Y",
        "turns": ["My rent went from 1500 to 1700 a month."],
        "expect": [("rent", None, "current", 1700), ("rent", None, "previous", 1500)],
        "asks": [
            ("How much is my rent now?", "rent", "1700"),
            ("What was my rent before?", "rent", "1500"),
        ],
    },
    {
        "name": "a plan is proposed, not current",
        "turns": ["My savings goal is 5k.", "I'm planning to raise my savings goal to 10k next year."],
        "expect": [("savings-goal", None, "current", 5000), ("savings-goal", None, "proposed_num", 10000)],
        "asks": [("Did I raise my savings goal to 10k?", "savings goal", "planned")],
    },
    {
        "name": "a total across items",
        "turns": ["My rent is 1700 a month.", "I spend 400 a month on groceries."],
        "expect": [("rent", None, "current", 1700), ("groceries", None, "current", 400)],
        "asks": [("What do my rent and groceries come to in total?", "rent groceries", "2100")],
    },
    {
        "name": "an unsure value is not a fact",
        "turns": ["I don't know, maybe I'll try to save like 2k this year?"],
        "expect": [("*", None, "no_confirmed", None)],
    },
    {
        "name": "relative dates are resolved",
        "turns": ["Last Tuesday I ran 10 kilometres in the park."],
        "expect": [("*", None, "event_date", "2026-11-17")],
    },
]


def env(path):
    out = {}
    for line in open(os.path.join(ROOT, path)):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            out[key] = value.strip().strip("'\"")
    return out


cfg = {**env(".env.staging"), **env(".env.staging-account")}
URL = cfg["SUPABASE_URL"].rstrip("/")
KEY = cfg["SUPABASE_PUBLISHABLE_KEY"]
if any(ref in URL for ref in PRODUCTION_REFS):
    sys.exit("Refusing to run against production.")


def call(method, url, body=None, token=None, headers=None):
    req = urllib.request.Request(
        url,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "apikey": KEY,
            "content-type": "application/json",
            "authorization": "Bearer " + (token or KEY),
            **(headers or {}),
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            raw = res.read().decode()
            return res.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()[:300]


def rpc(token, name, params):
    status, data = call("POST", f"{URL}/rest/v1/rpc/{name}", params, token)
    if status >= 300:
        raise RuntimeError(f"{name}: {status} {data}")
    return data


def slugify(name):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", name.lower())).strip("-")


ASK_MS = []


def run_case(token, user_id, case):
    notebook = str(uuid.uuid4())
    status, data = call(
        "POST", f"{URL}/rest/v1/notebooks",
        {"id": notebook, "user_id": user_id, "title": "fact eval",
         "started_at": datetime.now(timezone.utc).isoformat()},
        token, {"prefer": "return=minimal"},
    )
    if status >= 300:
        raise RuntimeError(f"notebook: {status} {data}")
    revision, known, recorded = 0, {}, []
    try:
        for i, text in enumerate(case["turns"]):
            turn_id = f"eval-{uuid.uuid4()}"
            status, data = call(
                "POST", f"{RUNTIME}/v1/notebooks/{notebook}/extractions",
                {
                    "turnId": turn_id,
                    "extractorVersion": "fact-eval/v1",
                    "text": text,
                    "mode": "granular",
                    "spokenAt": SPOKEN_AT,
                    "context": {
                        "entities": [{"id": k, "name": v[0], "type": v[1]} for k, v in known.items()],
                        "relations": [],
                        "recentConversation": [],
                        "answeringFollowUp": None,
                    },
                },
                token,
            )
            if status != 200:
                raise RuntimeError(f"extraction: {status} {data}")
            patch = data["patch"]
            now = datetime.now(timezone.utc).isoformat()
            entities = []
            for e in patch["entities"]:
                eid = slugify(e["name"])
                if not eid:
                    continue
                known[eid] = (e["name"], e["type"])
                entities.append({"id": eid, "name": e["name"], "type": e["type"], "metadata": {},
                                 "mentions": 1, "firstSeen": now, "lastSeen": now})
            result = rpc(token, "commit_notebook", {
                "p_notebook_id": notebook,
                "p_expected_revision": revision,
                "p_request_id": str(uuid.uuid4()),
                "p_change": {"kind": "applyTurn",
                             "entry": {"text": text, "entityIds": [e["id"] for e in entities],
                                       "relationIds": []},
                             "entities": entities, "relations": []},
            })
            if result.get("status") != "committed":
                raise RuntimeError(f"commit: {result}")
            revision = result["revision"]
            facts = [{"entityId": slugify(f["entity"]), **{k: v for k, v in f.items() if k != "entity"}}
                     for f in patch.get("facts", [])]
            outcome = rpc(token, "record_memory_facts", {
                "p_notebook_id": notebook, "p_entry_id": result["ids"]["entryId"], "p_facts": facts,
            }) if facts else {"recorded": [], "skipped": 0}
            recorded.append((text, patch.get("facts", []), outcome))
        ok, lines = check(token, case, known, recorded)
        for question, hint, want in case.get("asks", []):
            start = time.time()
            status, data = call("POST", f"{URL}/functions/v1/retrieve-memory", {
                "scope": "user", "notebookId": notebook, "version": 3,
                "query": hint, "question": question,
            }, token)
            ms = (time.time() - start) * 1000
            ASK_MS.append(ms)
            verdict = (data or {}).get("verdict", {}) if status == 200 else {}
            text = verdict.get("text", "")
            passed = status == 200 and want.lower() in text.lower()
            ok &= passed
            lines.append(f"    {'PASS' if passed else 'FAIL'} ask {question!r} ({ms:.0f} ms): "
                         f"{verdict.get('status', status)} | {text[:120]}")
        return ok, lines
    finally:
        call("DELETE", f"{URL}/rest/v1/notebooks?id=eq.{notebook}", None, token)


def history(token, entity, attribute):
    return rpc(token, "get_memory_fact_history", {"p_entity_id": entity, "p_attribute": attribute})["facts"]


def check(token, case, known, recorded):
    keys = rpc(token, "list_memory_fact_keys", {"p_entity_ids": list(known)})
    lines, ok = [], True
    for text, facts, outcome in recorded:
        lines.append(f"    said: {text}")
        for f in facts:
            lines.append(f"      fact: {json.dumps(f)}")
        lines.append(f"      db:   {[r['outcome'] for r in outcome['recorded']]} skipped={outcome['skipped']}")
    for entity, attribute, kind, want in case["expect"]:
        candidates = [k for k in keys if entity == "*" or k["entityId"] == entity]
        if attribute:
            candidates = [k for k in candidates if k["attribute"] == attribute]
        got = None
        if kind in ("current", "previous"):
            attrs = {k["attribute"] for k in candidates}
            if len(attrs) != 1:
                got = f"{len(attrs)} attributes: {sorted(attrs)}"
            else:
                fact = rpc(token, "get_memory_fact", {"p_entity_id": candidates[0]["entityId"],
                                                      "p_attribute": attrs.pop(), "p_scope": kind})["fact"]
                got = fact and fact["valueNum"]
            passed = got == want
        elif kind == "proposed_num":
            vals = [(f["status"], f["valueNum"]) for k in candidates
                    for f in history(token, k["entityId"], k["attribute"])]
            got, passed = vals, ("proposed", want) in vals
        elif kind == "no_confirmed":
            vals = [f for k in candidates for f in history(token, k["entityId"], k["attribute"])
                    if f["status"] == "confirmed"]
            got, passed = [f["valueNum"] or f["valueText"] for f in vals], not vals
        elif kind == "event_date":
            vals = [f["eventAt"] for k in candidates for f in history(token, k["entityId"], k["attribute"])]
            got, passed = vals, any(v and v.startswith(want) for v in vals)
        ok &= passed
        lines.append(f"    {'PASS' if passed else 'FAIL'} {entity}.{attribute or '*'} {kind}: want {want}, got {got}")
    return ok, lines


def main():
    names = set(sys.argv[1:])
    status, auth = call("POST", f"{URL}/auth/v1/token?grant_type=password",
                        {"email": cfg["STAGING_TEST_EMAIL"], "password": cfg["STAGING_TEST_PASSWORD"]})
    if status != 200:
        sys.exit(f"sign-in failed: {status}")
    token, user_id = auth["access_token"], auth["user"]["id"]
    passed = 0
    selected = [c for c in CASES if not names or c["name"] in names]
    for case in selected:
        start = time.time()
        try:
            ok, lines = run_case(token, user_id, case)
        except Exception as error:  # noqa: BLE001 - report and go on
            ok, lines = False, [f"    ERROR {error}"]
        passed += ok
        print(f"{'PASS' if ok else 'FAIL'} {case['name']} ({time.time() - start:.1f}s)")
        print("\n".join(lines))
    print(f"\n{passed}/{len(selected)} cases passed")
    if ASK_MS:
        ordered = sorted(ASK_MS)
        p95 = ordered[min(len(ordered) - 1, int(round(0.95 * (len(ordered) - 1))))]
        print(f"routed questions: {len(ordered)}, p50 {ordered[len(ordered) // 2]:.0f} ms, "
              f"p95 {p95:.0f} ms (wall time, including the network)")
    return 0 if passed == len(selected) else 1


if __name__ == "__main__":
    sys.exit(main())
