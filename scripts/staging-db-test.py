#!/usr/bin/env python3
"""Run pgTAP database tests on the staging project, with nothing kept.

There is no local Docker database here, so this sends the given migrations
and one pgTAP test file to staging as ONE implicit transaction through the
Supabase Management API. The last statement always raises an error carrying
the TAP output, so the whole transaction (migrations, fixtures, extension)
is rolled back every time.

Usage:
  scripts/staging-db-test.py TEST.sql [MIGRATION.sql ...]

Migrations listed are applied first (for testing a migration before it is
deployed). The Supabase CLI login token is read from the macOS keychain.
Refuses any project other than staging.
"""
import base64
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request

STAGING_REF = "roextftlnorvkjevqcsl"
PRODUCTION_REFS = {"bjoevzvsdlhlcjywpyfx"}
TAP_CALL = re.compile(
    r"^\s*select\s+(plan|ok|is|isnt|throws_ok|lives_ok|cmp_ok|is_empty|isnt_empty|"
    r"results_eq|set_eq|bag_eq|row_eq|matches|alike|pass|fail|diag|has_\w+|hasnt_\w+|"
    r"policies_are|function_privs_are|table_privs_are)\s*\(",
    re.IGNORECASE,
)
SKIP = re.compile(
    r"^\s*(begin|rollback|commit|create extension[^;]*pgtap|select \* from finish\(\))\s*$",
    re.IGNORECASE,
)


def token() -> str:
    raw = subprocess.run(
        ["security", "find-generic-password", "-s", "Supabase CLI", "-w"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    prefix = "go-keyring-base64:"
    return base64.b64decode(raw[len(prefix):]).decode() if raw.startswith(prefix) else raw


def statements(sql: str):
    """Split on ';' at line ends, keeping dollar-quoted bodies whole."""
    out, buf = [], []
    for line in sql.splitlines():
        if not buf and (line.strip().startswith("--") or not line.strip()):
            continue
        buf.append(line)
        text = "\n".join(buf)
        if line.rstrip().endswith(";") and text.count("$$") % 2 == 0:
            out.append(text.rstrip().rstrip(";"))
            buf = []
    if "".join(buf).strip():
        out.append("\n".join(buf))
    return out


def build(test_sql: str, migrations: list[str]) -> str:
    parts = ["create extension if not exists pgtap"]
    parts += [m.strip().rstrip(";") for m in migrations]
    parts += [
        "create temp table tap (n serial primary key, line text)",
        "grant all on tap to public",
        "grant all on sequence tap_n_seq to public",
    ]
    for stmt in statements(test_sql):
        if SKIP.match(stmt):
            continue
        if TAP_CALL.match(stmt):
            parts.append(f"insert into pg_temp.tap (line) select * from ({stmt}) t")
        else:
            parts.append(stmt)
    parts.append(
        "do $tap$ begin raise exception 'TAP_OUTPUT%', "
        "E'\\n' || coalesce((select string_agg(line, E'\\n' order by n) from pg_temp.tap), ''); "
        "end $tap$"
    )
    return ";\n".join(parts) + ";"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    ref = STAGING_REF
    if ref in PRODUCTION_REFS:
        print("Refusing to run tests against production.", file=sys.stderr)
        return 2
    test_sql = open(sys.argv[1]).read()
    migrations = [open(p).read() for p in sys.argv[2:]]
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{ref}/database/query",
        data=json.dumps({"query": build(test_sql, migrations)}).encode(),
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as res:
            body = res.read().decode()
    except urllib.error.HTTPError as error:
        body = error.read().decode()
    try:
        message = json.loads(body).get("message", body)
    except (ValueError, AttributeError):
        message = body
    if "TAP_OUTPUT" not in message:
        print("The test did not run to the end:\n" + message, file=sys.stderr)
        return 1
    tap = message.split("TAP_OUTPUT", 1)[1].split("\nCONTEXT:", 1)[0].strip("\n")
    print(tap)
    failed = [l for l in tap.splitlines() if l.startswith("not ok")]
    planned = re.search(r"^1\.\.(\d+)", tap, re.MULTILINE)
    ran = len([l for l in tap.splitlines() if re.match(r"^(not )?ok \d+", l)])
    if planned and int(planned.group(1)) != ran:
        print(f"# planned {planned.group(1)} tests but ran {ran}", file=sys.stderr)
        return 1
    print(f"# {ran - len(failed)}/{ran} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
