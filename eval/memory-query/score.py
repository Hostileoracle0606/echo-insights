#!/usr/bin/env python3
"""Score independently annotated, synthetic evaluation observations."""
import argparse
import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
STAGES = ("retrieval", "evidence", "spoken")


def percentile(values, p):
    values = sorted(values)
    return values[math.ceil(p * len(values)) - 1] if values else None


def score(fixtures, observations):
    cases = {c["id"]: c for c in fixtures["cases"]}
    if len(cases) != len(fixtures["cases"]):
        raise ValueError("duplicate fixture IDs")
    result = {}
    for row in observations:
        key = (row["variant"], row["case_id"])
        if key in result or row["case_id"] not in cases:
            raise ValueError(f"duplicate or unknown observation: {key}")
        case = cases[row["case_id"]]
        expected = case["expected"]
        for field in ("timeout", "fallback"):
            if type(row[field]) is not bool:
                raise ValueError(f"{key}: {field} must be boolean")
        latency = row["latency_ms"]
        if type(latency) not in (int, float) or not math.isfinite(latency) or latency < 0:
            raise ValueError(f"{key}: invalid latency")
        for stage in STAGES:
            if type(row["judgments"][stage]) is not bool:
                raise ValueError(f"{key}: {stage} judgment must be boolean")
        source_ids = row["returned_source_ids"]
        if not isinstance(source_ids, list) or any(not isinstance(x, str) for x in source_ids):
            raise ValueError(f"{key}: invalid source IDs")
        eligible = {s["id"] for s in case["sources"] if s["eligible"]}
        bad_sources = sorted(set(source_ids) - eligible)
        timed_out = row["timeout"]
        stages = {
            "route": row["operation"] == expected["operation"] and not timed_out,
            "time_scope": row["time_scope"] == expected["time_scope"] and not timed_out,
            **{s: row["judgments"][s] and not timed_out for s in STAGES},
            "status": row["status"] == expected["status"] and not timed_out,
        }
        if bad_sources:
            stages["retrieval"] = stages["evidence"] = False
        result[key] = {"stages": stages, "bad_sources": bad_sources, "latency_ms": latency,
                       "timeout": timed_out, "fallback": row["fallback"], "expected_status": expected["status"]}
    variants = sorted({key[0] for key in result})
    summaries = {}
    for variant in variants:
        rows = [r for (v, _), r in result.items() if v == variant]
        summaries[variant] = {
            "cases": len(rows), "missing_case_ids": sorted(set(cases) - {i for v, i in result if v == variant}),
            "stage_passes": {s: sum(r["stages"][s] for r in rows) for s in rows[0]["stages"]},
            "grounded_answer_passes": sum(all(r["stages"].values()) for r in rows if r["expected_status"] == "supported"),
            "supported_cases": sum(r["expected_status"] == "supported" for r in rows),
            "abstention_passes": sum(r["stages"]["status"] and r["stages"]["spoken"] for r in rows if r["expected_status"] == "insufficient_evidence"),
            "abstention_cases": sum(r["expected_status"] == "insufficient_evidence" for r in rows),
            "clarification_passes": sum(r["stages"]["status"] and r["stages"]["spoken"] for r in rows if r["expected_status"] == "clarification"),
            "clarification_cases": sum(r["expected_status"] == "clarification" for r in rows),
            "latency_ms_p50": percentile([r["latency_ms"] for r in rows], .50),
            "latency_ms_p95": percentile([r["latency_ms"] for r in rows], .95),
            "over_3500_ms": sum(r["latency_ms"] > 3500 for r in rows),
            "timeouts": sum(r["timeout"] for r in rows), "fallbacks": sum(r["fallback"] for r in rows),
            "ineligible_or_unknown_source_cases": sum(bool(r["bad_sources"]) for r in rows),
        }
    paired = None
    if len(variants) == 2:
        left, right = variants
        ids = sorted({i for v, i in result if v == left} & {i for v, i in result if v == right})
        def grounded(r):
            return r["expected_status"] == "supported" and all(r["stages"].values())
        pairs = [(result[left, i], result[right, i]) for i in ids]
        paired = {"variants": [left, right], "paired_cases": len(ids),
                  "case_ids": ids,
                  "supported_cases": sum(a["expected_status"] == "supported" for a, _ in pairs),
                  "grounded_gain_right": sum(not grounded(a) and grounded(b) for a, b in pairs),
                  "grounded_loss_right": sum(grounded(a) and not grounded(b) for a, b in pairs),
                  "complete": len(ids) == len(cases)}
    return {"variants": summaries, "paired": paired, "cases": [dict(variant=v, case_id=i, **r) for (v, i), r in sorted(result.items())]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("observations", type=Path, help="JSON array of independently assessed observations")
    parser.add_argument("--fixtures", type=Path, default=HERE / "cases.json")
    args = parser.parse_args()
    print(json.dumps(score(json.loads(args.fixtures.read_text()), json.loads(args.observations.read_text())), indent=2))


if __name__ == "__main__":
    main()
