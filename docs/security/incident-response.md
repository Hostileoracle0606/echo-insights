# Incident response (LM-54)

Status: written for one developer today, structured so a second person can take a role without rewriting it.

Items marked **(unverified)** describe vendor features, plan limits or settings that were not checked against the live consoles. Check them, then remove the marker.

**This is an engineering runbook, not legal advice.** Whether an event is a notifiable personal data breach, who must be told and by when are legal questions. Get legal advice early in any incident that involves user data.

Related: `docs/security/admin-access.md` (access paths, break-glass, what is logged; on branch `feat/lm-45-admin-access`), `docs/security/ai-processing.md` (providers; on `feat/lm-43-ai-retention`), `docs/security/vulnerability-disclosure.md`.

## Roles

| Role | Does | Today |
|---|---|---|
| Incident lead | Declares severity, decides containment, keeps the timeline, decides notifications | The developer |
| Operator | Runs the console and CLI steps (rotate, revoke, deploy a fix) | The developer |
| Scribe | Writes the timeline as it happens (private note or private repo issue; never user data or content) | The developer |
| Legal / privacy adviser | Advises on notification duties | Not appointed. Name one before launch; this is a user action |

With a second person: the second person becomes scribe and checks the lead's notification decision. With more people, split lead and operator.

## Severity levels

| Level | Meaning | Examples | Start within | Update |
|---|---|---|---|---|
| SEV1 | Confirmed or likely exposure of user content or credentials, or content reachable by someone it shouldn't be | Leaked service-role or Gemini key in use; RLS hole letting one user read another's journal; journal text found in a log or a third party | Immediately | Hourly to yourself; users per the notification section |
| SEV2 | Possible exposure or a control failure with no evidence of access yet | Suspicious admin session; RLS policy found broken but no cross-user reads seen; provider reports a breach that may include Lumen data | Same day | Daily |
| SEV3 | Reliability or hygiene issue, no data exposure | Alarm on Lambda errors or 5xx; expired secret; failed deploy | Next working day | On resolution |

When unsure, pick the higher level and downgrade with a written reason.

## What can and cannot be alerted on

| Signal | Alert exists? | Where / why not |
|---|---|---|
| Lambda errors, per function (5 functions) | Yes, CDK alarm | CloudWatch alarm to the alerts SNS topic (`infra/lib/infra-stack.ts`) |
| Spike in failed authorization | Indirectly | The authorizer logs no denials (a denied token is a normal answer), so there is no log-based filter. The alarm is on API Gateway `4xx` for the `$default` stage, which also counts bad input and throttling |
| API 5xx | Yes, CDK alarm | Same topic |
| AWS admin activity (console sign-in, IAM change, `GetSecretValue` by an unknown principal) | Records yes, alerts no | The CDK stack now creates a CloudTrail trail (365-day retention). No alarm is wired on it: that needs a CloudWatch Logs destination and metric filters, which cost more and were left out of this minimal change. Review by hand (see "Evidence") |
| Supabase admin / dashboard session | Not by this repo | Org audit logs depend on plan (unverified). Postgres statement logging / `pgaudit` is not enabled here and may not be available on the plan (unverified). Until confirmed, the written break-glass log is the only record |
| Bulk reads of user tables | Not alertable here | RLS-bypassing reads by an owner or the service key leave no per-row log in this setup. Supabase log-drain or log-based alerting is plan-dependent (unverified). Do not assume it exists |
| Gemini key abuse | Not by this repo | Watch usage and spend in the Google console; set a budget alert there (user action, unverified in UI) |

The alarms only exist after `cdk deploy` and a confirmed email subscription (see Alert wiring). They have not been fired in a test: that is a user action in `launch-checklist.md`.

### Alarm thresholds (all per 5-minute period, one period to trigger)

| Alarm | Threshold | Why |
|---|---|---|
| Lambda `Errors`, each of five functions | 3 or more | One failed request, such as a model timeout, does not page; three in five minutes is a pattern |
| API Gateway `4xx` (`$default` stage) | 30 or more | A normal client sends occasional 4xx; 30 in five minutes is a sign-in storm, probing or throttling. Expect to retune with real traffic |
| API Gateway `5xx` | 3 or more | As for Lambda errors |

Missing data counts as OK, so a quiet API does not alarm. Throttling at the stage (10 rps default, 20/40 on model routes) counts toward 4xx.

### Alert wiring

- One SNS topic. The subscriber is **not** in the repo: deploy with `cdk deploy -c alertEmail=<your address>`, then click the confirmation link AWS emails. An unconfirmed subscription receives nothing.
- CloudTrail: the stack creates a multi-region trail for management events to a private S3 bucket that expires objects after 365 days and is retained if the stack is deleted. Cost: the first copy of management events per account is free; S3 storage for a small account is cents per month. If the account **already** has a trail, a second copy of management events is charged per event after the free copy (about $2 per 100,000 events at time of writing, unverified); delete one of them or drop this one before deploying.

## First hour, by incident

For every incident: (1) open the timeline note with the time you learned of it, (2) assign severity, (3) contain before investigating, (4) preserve evidence (next section), (5) decide notification (last section).

### A. Leaked key (Gemini, Supabase service-role, personal access token, DB password, `EMBED_INTERNAL_SECRET`)

1. Treat as compromised the moment it appeared anywhere public or unintended (repo, log, chat, screenshot, app bundle).
2. Rotate per `admin-access.md` section B (rotation order). Gemini key: create new, set in Secrets Manager, delete the old key. Supabase legacy keys: rotating is an outage, read that section first.
3. Revoke a leaked personal access token in the Supabase account settings immediately.
4. If it was in git history: rotating is the fix; rewriting history is not.
5. Check use of the old key: Google console usage; Supabase API/function logs; CloudTrail `GetSecretValue` by principals other than the four Lambda execution roles that read the secret.
6. If the service-role key or DB password may have been used: go to incident B.

### B. Suspected data access (an account, an admin session, or a key used by someone else)

1. Contain: rotate the credential, end sessions, remove members or tokens. Do not delete logs.
2. Scope: which table, which user ids, which time window. Use metadata only; break-glass rules in `admin-access.md` apply to you too (written reason first, no copying rows).
3. Evidence sources: Supabase API and Postgres logs, org audit log (plan-dependent, unverified), CloudTrail, GitHub audit log, Actions history.
4. If you cannot rule out that user content was read, say so; "no evidence" is not "none".
5. Involve the legal adviser now if content may have been read.

### C. A provider breach (Google, Supabase, AWS, or another processor)

1. Read the provider's notice. Note what data classes they say were affected and the dates.
2. Map to Lumen using `ai-processing.md`: Google sees live audio and the text sent for extraction, cards and briefs; Supabase holds the database; AWS holds logs, the secret, the extraction cache (derived content, unverified what it stores).
3. Rotate any Lumen credential the provider says may be exposed (keys held with them).
4. Ask the provider in writing: what was accessed, whether Lumen data is in scope, and whether they will notify. You are the controller; the duty to tell regulators and users may be yours even if they are the source (legal advice applies).
5. Decide user notification (below) with legal advice.

### D. Broken RLS policy

1. Reproduce on **local or staging with synthetic data**, never by testing production user data. Use two synthetic users and the user-token path.
2. Contain: ship a migration that tightens the policy (or revokes the grant) as the fastest fix, test with `supabase test db` locally, apply with the owner's deploy path. If the exposure is severe and a fix will take time, consider taking the affected function or route offline.
3. After the fix, work out whether it was exploited: Supabase API logs for the affected table over the window since the migration that introduced the problem (`git log` on `supabase/migrations`). Row-level access by other users usually leaves only request metadata (unverified how much the plan keeps).
4. Add a pgTAP test that fails on the old behaviour. New user-owned tables must join the LM-48 deletion guard test.

### E. Accidental content log (journal text, card text, entity names or audio in a log)

1. Find the group and range: CloudWatch Lambda log groups (kept 14 days, `infra/lib/infra-stack.ts`), API Gateway logs, Supabase function logs.
2. Delete the offending log events or the group (CloudWatch allows deleting a group, not single events; deleting the group loses the other lines too). If the **old** auto-created `/aws/lambda/*` groups from before LM-44 still exist, delete them: they never expire and may hold content.
3. Stop the source: revert or fix the code, check that `safeLog` is used and the privacy tests (`.github/workflows/privacy-tests.yml`) catch the pattern; add a test.
4. Scope: who could have read the logs (AWS admins; see `admin-access.md`), were they exported or sent to a third party. If only the owner could read them and nothing left the account, it is usually SEV3 or SEV2; this is a legal judgement, take advice.
5. Record in the post-incident review even if no one was notified.

## Evidence

- Take a timestamped copy of the relevant log slice **before** rotating or deleting anything that is not itself the leak. Store it in a private location (not the repo): metadata only, no content, no user identifiers beyond opaque ids.
- CloudTrail: the trail bucket is the long copy (365 days); Event history is the short one (90 days documented, unverified for this account). Do not delete either.
- Note exact times in UTC, commands run (never with secrets on the command line), and who did what.
- Screenshot console settings that matter (store privately).
- Do not copy production rows anywhere (`admin-access.md` rule 4).
- Keep the timeline note until counsel or the regulator process says otherwise.

## User notification

Not legal advice; take it. The points below are an accurate summary of GDPR Articles 33 and 34 for planning, not a substitute for advice:

- **Supervisory authority:** where a personal data breach is likely to result in a risk to people's rights and freedoms, the controller notifies the competent supervisory authority without undue delay and, where feasible, **no later than 72 hours after becoming aware of it**. Late notification must say why. If the breach is unlikely to result in a risk, notification is not required but the breach must still be documented. Which authority is competent depends on where Lumen is established: not decided here (unverified; needs legal advice).
- **Affected users:** where the breach is likely to result in a **high risk** to people's rights and freedoms, the controller tells the affected people **without undue delay**. This is not a fixed 72-hour clock. Notification to users is not required if the data was unintelligible to others (for example effectively encrypted) or the risk has been removed by measures taken afterwards. Journal content is highly sensitive; assume high risk until advised otherwise.
- **Processors** (Supabase, AWS, Google) must tell the controller without undue delay: that is you.
- The 72 hours starts when you become **aware**, so write the time down.
- Other laws (the country where users live, app store rules) may add duties. Ask.

What a user message says: what happened, when, what data, what we have done, what they should do, and how to reach us. No speculation, no minimising, no blame. Send it through the channel you can verify (in-app notice or the email on the account). Do not include any journal content. Do not promise "we can't read it" (not true until Phase 3); do not claim "keeps nothing".

## Post-incident review template

Copy to a private note. Blameless; the goal is a fix, not a culprit.

```
Incident:            (short title, no user data)
Severity:            SEV1 / SEV2 / SEV3   (initial -> final)
Detected:            (UTC time, how: alarm / report / found by us)
Aware (72h clock):   (UTC time)
Contained:           (UTC time)
Resolved:            (UTC time)
Lead / scribe:
Summary:             (3 to 5 sentences)
Timeline:            (UTC, what happened, what was done)
Data affected:       (classes and counts, never content; "unknown" is allowed)
Root cause:
Why it was not caught earlier:
What went well:
What went badly:
Notified:            authority (when, ref) / users (when, how, how many) / providers
Legal advice taken:  yes / no, from whom
Actions:             | action | owner | due | status |
Docs or alarms to change:
Test added that would have caught it:
Reviewed by / date:
```

## Honest limits

- A solo owner can read all data and nothing here technically prevents it (`admin-access.md`).
- Several important detections (bulk reads, Supabase admin sessions) depend on plan features that are unverified.
- Alarms are not tested until they are deployed and fired once on purpose.
