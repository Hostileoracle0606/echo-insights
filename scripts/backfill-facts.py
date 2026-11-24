#!/usr/bin/env python3
"""EC-09: backfill facts for journals written before EC-03, on staging.

For the signed-in account, runs the same extraction the app runs on each new
turn over the user's existing entries, oldest first, and records each entry's
facts. Built to be stopped and started:

  * the cursor lives in the database (advance_memory_backfill), so a run
    that stops anywhere resumes after the last entry it finished;
  * an entry that already has facts (extracted live since EC-03) is skipped,
    and facts are recorded with p_replace, so a re-run adds nothing;
  * one extraction at a time, --delay seconds apart, backing off on 429.

Forget is honoured at run time: entries come back with their Forget-redacted
text, the extraction runtime redacts again with the user's own token, and a
fact about a forgotten (deleted) entity is skipped by record_memory_facts.

Needs the local runtime on :8787 (scripts/ec01-rebuild-test.sh runtime) and
.env.staging + .env.staging-account (gitignored). Refuses production.

Usage:
  scripts/backfill-facts.py [--max N] [--delay SECONDS] [--reset]
  scripts/backfill-facts.py --eval     # done-when check, see eval() below
"""
import argparse
import importlib.util
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
VERBOSE = "--verbose" in sys.argv
_spec = importlib.util.spec_from_file_location("fact_eval", os.path.join(HERE, "fact-eval.py"))
fe = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fe)  # config, call(), rpc(), RUNTIME; refuses production


def sign_in():
    status, auth = fe.call("POST", f"{fe.URL}/auth/v1/token?grant_type=password",
                           {"email": fe.cfg["STAGING_TEST_EMAIL"], "password": fe.cfg["STAGING_TEST_PASSWORD"]})
    if status != 200:
        sys.exit(f"sign-in failed: {status}")
    return auth["access_token"], auth["user"]["id"]


_notebook_entities = {}


def context_entities(token, entry):
    """The entry's entities, then the rest of its notebook's, as the live
    path shows the model: "monthly savings target" can then land on the
    notebook's "savings goal" instead of becoming a new thing."""
    nb = entry["notebookId"]
    if nb not in _notebook_entities:
        status, rows = fe.call(
            "GET", f"{fe.URL}/rest/v1/entities?select=id,name,type&notebook_id=eq.{nb}&order=last_seen.desc&limit=40",
            None, token)
        _notebook_entities[nb] = rows if status == 200 and isinstance(rows, list) else []
    seen, out = set(), []
    for e in entry["entities"] + _notebook_entities[nb]:
        if e["id"] not in seen:
            seen.add(e["id"])
            out.append({"id": e["id"], "name": e["name"], "type": e["type"]})
    return out[:20]


def extract(token, entry, entities):
    """The runtime's patch for one entry, retried on 429 / in-progress."""
    body = {
        "turnId": f"backfill-{entry['entryId']}",
        "extractorVersion": "backfill/v2",
        "text": entry["text"],
        "mode": "granular",
        "spokenAt": entry["spokenAt"],
        "context": {
            "entities": entities,
            "relations": [],
            "recentConversation": [],
            "answeringFollowUp": None,
        },
    }
    for attempt in range(5):
        status, data = fe.call("POST", f"{fe.RUNTIME}/v1/notebooks/{entry['notebookId']}/extractions", body, token)
        if status == 200:
            return data["patch"]
        if status == 400:
            return None  # too short or not extractable: nothing to backfill
        if status in (409, 429, 503):
            time.sleep(min(2 ** attempt, 20))
            continue
        raise RuntimeError(f"extraction {status}: {str(data)[:200]}")
    raise RuntimeError("extraction kept failing")


def facts_for(entities, patch):
    """The patch's facts, keyed by the ids of the entities the model was shown."""
    by_name = {e["name"].lower(): e["id"] for e in entities}
    ids = {e["id"] for e in entities}
    out = []
    for f in (patch or {}).get("facts", []):
        name = f["entity"].strip().lower()
        entity_id = by_name.get(name) or (fe.slugify(name) if fe.slugify(name) in ids else None)
        if not entity_id:
            continue
        out.append({"entityId": entity_id, **{k: v for k, v in f.items() if k != "entity"}})
    return out


def run(token, max_entries=None, delay=1.0, log=print):
    done = skipped = recorded = 0
    while max_entries is None or done < max_entries:
        page = fe.rpc(token, "list_backfill_entries", {"p_limit": 20})
        if not page:
            break
        for entry in page:
            if max_entries is not None and done >= max_entries:
                break
            if not entry["hasFacts"]:
                entities = context_entities(token, entry)
                patch = extract(token, entry, entities)
                facts = facts_for(entities, patch)
                if VERBOSE and (patch or {}).get("facts"):
                    log(f"  {entry['text'][:60]!r}: {len(patch['facts'])} found, {len(facts)} kept"
                        + ("" if len(facts) == len(patch["facts"]) else
                           f" (fact entities {[f['entity'] for f in patch['facts']]}, "
                           f"shown {[e['name'] for e in entities][:6]})"))
                if facts:
                    result = fe.rpc(token, "record_memory_facts", {
                        "p_notebook_id": entry["notebookId"],
                        "p_entry_id": entry["entryId"],
                        "p_facts": facts,
                        "p_replace": True,
                    })
                    recorded += len(result["recorded"])
                time.sleep(delay)
            else:
                skipped += 1
            fe.rpc(token, "advance_memory_backfill", {"p_entry_id": entry["entryId"]})
            done += 1
    log(f"backfill: {done} entries, {skipped} already had facts, {recorded} facts recorded")
    return done


def commit_without_facts(token, user_id, turns):
    """A notebook as the app wrote it before EC-03: entities and entries, no facts."""
    notebook = str(uuid.uuid4())
    status, data = fe.call("POST", f"{fe.URL}/rest/v1/notebooks",
                           {"id": notebook, "user_id": user_id, "title": "backfill eval",
                            "started_at": "2026-10-01T10:00:00+00:00"},
                           token, {"prefer": "return=minimal"})
    if status >= 300:
        raise RuntimeError(f"notebook: {status} {data}")
    revision, known = 0, {}
    for text in turns:
        status, data = fe.call("POST", f"{fe.RUNTIME}/v1/notebooks/{notebook}/extractions", {
            "turnId": f"pre-ec03-{uuid.uuid4()}", "extractorVersion": "pre-ec03/v1", "text": text,
            "mode": "granular", "context": {"entities": [{"id": k, "name": v[0], "type": v[1]} for k, v in known.items()],
                                            "relations": [], "recentConversation": [], "answeringFollowUp": None},
        }, token)
        entities = []
        for e in data["patch"]["entities"]:
            eid = fe.slugify(e["name"])
            known[eid] = (e["name"], e["type"])
            entities.append({"id": eid, "name": e["name"], "type": e["type"], "metadata": {}, "mentions": 1,
                             "firstSeen": "2026-10-01T10:00:00Z", "lastSeen": "2026-10-01T10:00:00Z"})
        result = fe.rpc(token, "commit_notebook", {
            "p_notebook_id": notebook, "p_expected_revision": revision, "p_request_id": str(uuid.uuid4()),
            "p_change": {"kind": "applyTurn", "entry": {"text": text, "entityIds": [e["id"] for e in entities],
                                                        "relationIds": []},
                         "entities": entities, "relations": []},
        })
        revision = result["revision"]
    return notebook


def eval_backfill():
    """Done-when for EC-09: a backfilled journal answers the EC-06 questions
    like one extracted live, and stopping and resuming adds nothing.

    Facts belong to the user, not a notebook, so cases run one at a time (as
    in fact-eval.py): each is written as before EC-03, backfilled with an
    interruption, then asked about, before the next exists. The re-run check
    is one more whole run at the end."""
    token, user_id = sign_in()
    fe.rpc(token, "reset_memory_backfill", {})
    run(token, delay=0.5)  # the account's older entries first
    notebooks, ok = [], True
    try:
        for case in [c for c in fe.CASES if c.get("asks")]:
            nb = commit_without_facts(token, user_id, case["turns"])
            notebooks.append(nb)
            run(token, max_entries=1, delay=0.5)  # interrupted
            run(token, delay=0.5)                  # resumed
            for question, hint, want in case["asks"]:
                status, data = fe.call("POST", f"{fe.URL}/functions/v1/retrieve-memory", {
                    "scope": "user", "notebookId": nb, "version": 3, "query": hint, "question": question,
                }, token)
                text = (data or {}).get("verdict", {}).get("text", "") if status == 200 else str(status)
                passed = want.lower() in text.lower()
                ok &= passed
                print(f"{'PASS' if passed else 'FAIL'} {case['name']}: {question!r} -> {text[:110]}")
        first = [count_facts(token, nb) for nb in notebooks]
        fe.rpc(token, "reset_memory_backfill", {})
        run(token, delay=0.5)
        second = [count_facts(token, nb) for nb in notebooks]
        same = first == second
        ok &= same
        print(f"{'PASS' if same else 'FAIL'} resume and re-run add nothing: {first} vs {second}")
        return 0 if ok else 1
    finally:
        for nb in notebooks:
            fe.call("DELETE", f"{fe.URL}/rest/v1/notebooks?id=eq.{nb}", None, token)


def count_facts(token, notebook):
    status, rows = fe.call("GET", f"{fe.URL}/rest/v1/memory_facts?select=id&source_notebook_id=eq.{notebook}",
                           None, token)
    return len(rows) if status == 200 else -1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max", type=int, default=None)
    parser.add_argument("--delay", type=float, default=1.0)
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--eval", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.eval:
        return eval_backfill()
    token, _ = sign_in()
    if args.reset:
        fe.rpc(token, "reset_memory_backfill", {})
    run(token, args.max, args.delay)
    return 0


if __name__ == "__main__":
    sys.exit(main())
