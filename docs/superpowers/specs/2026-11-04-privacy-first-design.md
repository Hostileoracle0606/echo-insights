# Privacy-first Lumen: design

**Status:** proposed · **Date:** 2026-11-04 · **Tickets:** `docs/privacy-security-tickets.md` (LM-43 to LM-62)

People tell Lumen things they wouldn't write down anywhere else, out loud, every day. Some users won't trust it while an admin or an AI provider could read their journal. This document sets out who can read a journal today, the options we evaluated, what research and the market say, and the plan: four privacy features plus the security work that backs them up.

---

## 1. Who can read a journal today

| Data | Where it goes | Who can read it |
|---|---|---|
| Raw voice and the live transcript | Gemini Live | Google. **On the free tier, Google may use it to improve its products.** |
| Transcript text for extraction, cards and briefs | AWS Lambdas → Gemini 2.5 Flash and TTS | Google; us through AWS, and CloudWatch if content is ever logged |
| `conversation_turns`, `journal_entries`, `entities`, `relations`, `session_cards`, `follow_ups`, `asked_questions`, `session_briefs` (including the opener audio) | Supabase Postgres and its backups | Supabase staff with operational access; any project member; the dashboard's SQL editor |
| `entity_embeddings` (gte-small) | Supabase pgvector | Same as above. Embeddings can be partly turned back into text. |
| Anything on the phone | The device | Anyone holding the unlocked phone |

**Takeaway:** Supabase admin access is a real concern, but it isn't the biggest one. A credible privacy-first claim has to cover the **AI provider** and the **person holding the phone** as well as the database.

**What we already have:**
- Row-level security on all 15 tables, tested with pgTAP.
- RPCs that run as the signed-in user, so no service key is used for user writes.
- Ephemeral Gemini Live tokens minted by the `live-session` Lambda, so the app never holds the API key.
- Account deletion (`20260922000000_account_deletion.sql`).

---

## 2. Options evaluated

| Option | Protects against | Cost | Verdict |
|---|---|---|---|
| **A. Hygiene:** paid AI (no training, retention documented), collect and keep less, MFA, least access, honest policy | Training on entries; casual access | Days | **Do now.** Required before any claim is honest. |
| **B. Server-side encryption with AWS KMS** | Supabase staff; leaked dumps and backups | 1–2 weeks | Skip. "Supabase can't read it" means little to users, and C replaces it. |
| **C. Zero-access storage:** keys held on the device; the database stores ciphertext; AI processing only sees plain text briefly | Supabase, us, database leaks | 1–2 months | **Do.** The strongest claim users understand, for the effort. |
| **D. Confidential inference:** self-hosted Gemma on confidential-computing GPUs, with attestation checked by the app | Us and the cloud host seeing text while it's processed | A quarter or more | Later, for text calls. |
| **E. Local-first:** everything on the device | Every server | Large, and quality drops | Not now. Voice quality and latency suffer, and the web app is lost. |

Pseudonymization (section 3) is added on top of A and C.

Supabase's pgsodium column encryption is deprecated, so we don't use it.

---

## 3. Research

### Split inference: rejected
The idea is to run the first layers of a model on the phone and send activations, not words, to the server. Research shows activations can be inverted back into text:
- **ActInv** (arXiv 2605.23158) relies on LLMs being almost surely injective.
- **Shu et al.** (2501.05965) and **PIDI** (2606.14210) recover prompts and even outputs.
- The defences that exist cost accuracy (survey: 2604.24468).

It also needs model weights we host ourselves, which Gemini doesn't allow, and it doesn't help with voice.

### On-device pseudonymization: promising
A small step on the phone swaps identifiers for placeholders before text leaves the device, and swaps them back in the result. Relevant work:
- **LOPSIDED** (2510.27016): the mapping stays on the device.
- **DR-SL** (2609.14883): checks that the swap reverses correctly.
- **RLAA** (ACL Findings 2026): an "attacker" model tests whether the text can still be re-identified, and warns that naive anonymizers using small models wreck the text's usefulness.

**Why it fits Lumen:** the entity graph already knows the user's people, places and projects. The replacement can be a lookup ("Priya" → `[person:7]`) plus on-device name recognition for new names, with no extra model in the common case.

**Limits:**
- It hides *who*, not *what*.
- Details can still add up to a person.
- It doesn't cover the Gemini Live voice path.

**Impact on extraction.** The extract-graph prompt deduplicates against `EXISTING ENTITIES` ("reuse the existing spelling") and resolves pronouns using `RECENT CONVERSATION`. Quality holds if all three inputs use the **same** placeholder, and deduplication may even improve. The risks:

| Risk | Mitigation |
|---|---|
| Speech-recognition misspellings ("Pria" vs "Priya"), which leak the name and create a duplicate | Fuzzy matching on spelling and sound |
| Aliases ("Sam" / "Samantha" / "my sister") | An alias list per entity |
| Names that are also words (Will, June, Rose) | Replace only when the graph knows them as a person |
| Lost meaning (gender, role, "tech job") | Placeholders that carry a role (`[person:7 · sister]`), or consistent fake names |
| New names the lookup misses | On-device name recognition; a miss leaks but doesn't break extraction |
| Brief opener audio needs the real name | Generate the audio on the device, or state that TTS receives the name |

A spike (task_c85a425b) measures this on synthetic transcripts: plain tags vs role-carrying tags vs fake names, including misspelled transcripts. It ends in a go/no-go decision.

### Market opinion
Reddit was blocked to our tools. These findings come from Product Hunt, Hacker News and comparison blogs, many of them written by competing apps.
- **"We don't train on your data" is seen as incomplete.** People also want to know how long data is kept and which AI providers are involved.
- **Encryption versus AI is a known tension.** Day One says its end-to-end encrypted journals are temporarily decrypted for AI features, and makes those features opt-in.
- **Naming AI providers is becoming the norm.** Rosebud names five and cites zero-retention agreements.
- **"Where does the AI run?"** is the question privacy-minded buyers are told to ask. On-device and zero-knowledge journal apps advertise on exactly this.
- **People are skeptical of vague claims.** No independent audits of competitors were found.

The gap we can fill is honest, checkable claims. Few competitors have them.

---

## 4. Principles from the user's point of view

1. **The person most likely to read a journal is someone nearby.** Lock the app, hide previews, and don't speak private things aloud without headphones.
2. **Explain it on one plain screen at the moment it matters:** a short "Who hears you" list on the first mic tap, honest even when uncomfortable.
3. **Make memory visible and editable.** The graph is "what Lumen remembers about you", and "forget Priya" removes everything about her.
4. **Give control in the moment:** off the record, delete this session, auto-forget.
5. **Protect the people users talk about.** "Lumen never sends the names of people you talk about" is how we present pseudonymization.
6. **Show proof rather than claims:** the "What Lumen shared" log, open-source encryption code on the device, an independent audit. No "military-grade".
7. **Explain trade-offs in human terms**, for example: "If you lose your phone and your recovery phrase, we can't get your journal back. That's the point."
8. **Copy follows shipping.** Never claim a protection before it exists.

---

## 5. The four privacy features

| # | Feature | Who it keeps out | What the user sees | Tickets |
|---|---|---|---|---|
| 1 | **Paid AI processing, with retention stated honestly** | Google training on entries | Before billing: "Lumen sends your voice and text to Google's Gemini service to talk with you." After billing: the paid-tier line in `docs/security/ai-processing.md` section 6, which says Google may keep them for a limited period. Never "keeps nothing" (see the note below). | LM-43, LM-44 |
| 2 | **Pseudonymized AI calls** | Google and our servers learning who entries are about | "The AI sees 'Person A', never your sister's name." | LM-55 to LM-57 |
| 3 | **Zero-access encrypted journal** | Supabase, us, database leaks | "Locked with a key only your devices hold." | LM-59 to LM-62 |
| 4 | **Off the record, auto-forget and forget a person** | Storing what never needed storing | Toggles on the session, in settings and on entity pages | LM-49 to LM-51 |

**Note on feature 1 (ruling R13, `docs/security/ai-processing.md`):** zero retention is not achievable on the paid Gemini API. It has no documented zero-retention mode, and Google logs prompts and responses for a limited, unpublished period for abuse detection and legal reasons. "Keeps nothing" stays out of all copy unless Lumen moves to Vertex with zero data retention and a written abuse-monitoring exemption, or Google confirms in writing that the paid Gemini API retains nothing. Vertex is not a drop-in change; it is its own project.

**Order:** 1 → 4 → 2 → 3. Each step makes the next one smaller. For example, feature 2's name map becomes the device-held key material in feature 3.

---

## 6. Security features behind the claims

Trust usually breaks on keys, access and logs rather than on the encryption method.

| Layer | Features | Tickets |
|---|---|---|
| **Encryption** | TLS and ephemeral tokens (exist); keys on the device (Secure Enclave and Keychain, per-notebook keys, iCloud Keychain sync, recovery phrase); encrypted embeddings and name map; `NSFileProtectionComplete` for local files; key rotation | LM-47, LM-59 to LM-62 |
| **Identity and access** | Face ID or passcode app lock; re-authentication for sensitive actions; Sign in with Apple and passkeys; device list with remote sign-out | LM-47, LM-58 |
| **Server hardening** | RLS and owner-checked RPCs (exist); service key only in Secrets Manager; least-privilege IAM; RPC size caps; rate limits; **no standing admin access** (break-glass only, with MFA, time limits and a log) | LM-45, LM-46 |
| **AI pipeline** | Paid tier with no training, and retention stated as it is (not zero; see section 5); **no content in logs** (a CI test fails if marker text appears); 14-day log retention; pseudonymization; journal text kept separate from instructions in prompts | LM-43, LM-44, LM-56 |
| **Data lifecycle** | Complete account and session deletion, with a test that fails when a new table holding user data isn't covered; forget a person; auto-forget; export; a stated window for backups | LM-48 to LM-52 |
| **Detection and response** | Audit logs and alerts on unusual access; incident plan with 72-hour user notification; key rotation | LM-45, LM-54 |
| **Proof** | Penetration test; `security.txt` and a disclosure page; public security page; open-source encryption code on the device | LM-53, LM-54 |

---

## 7. Plan

- **Phase 1, launch blockers (LM-43 to LM-54):** paid AI with retention documented, logs without content, admin lockdown, RPC caps, app lock, complete deletion, forget a person, off the record, auto-forget, export, the "Who hears you" screen, and a penetration test.
- **Phase 2, pseudonymization (LM-55 to LM-58):** gated on the spike's go/no-go.
- **Phase 3, keys on the device (LM-59 to LM-62):** needs its own design spec first.
- **Later:** confidential inference for text calls (option D), and on-device or open streaming voice (see the research notes on Gemma voice pipelines) to take Gemini Live out of the path.

### Open decisions
- **D1:** should the web app be able to read journals? If yes, keys are unlocked in the browser with a passkey (WebAuthn PRF).
- **D2:** when a user loses their key, is permanent data loss acceptable, or do we offer optional key escrow, which weakens the claim?
- **Verify:** whether the Gemini Live API and its ephemeral tokens work under Vertex AI zero data retention (LM-43).
- **Brief audio under pseudonymization:** generate it on the device, or state that TTS receives the real name (LM-56).

---

## Sources

**Split inference**
- ActInv: https://arxiv.org/pdf/2605.23158
- Shu et al.: https://arxiv.org/pdf/2501.05965
- PIDI: https://arxiv.org/abs/2606.14210
- Split learning survey: https://arxiv.org/pdf/2604.24468
- Edge-cloud collaborative inference: https://arxiv.org/pdf/2607.13093

**Pseudonymization**
- LOPSIDED: https://www.arxiv.org/pdf/2510.27016
- DR-SL: https://arxiv.org/pdf/2609.14883
- RLAA: https://aclanthology.org/2026.findings-acl.274.pdf
- Anonymizer SLM: https://hface.pages.dev/blog/pratyushrt/anonymizerslm

**Market opinion**
- Day One AI features: https://dayoneapp.com/?p=87313
- Private AI journaling comparison: https://privateclaude.ai/blog/private-ai-journaling
- Rosebud reviews on Product Hunt: https://www.producthunt.com/products/rosebud/reviews?page=2
- Rosebud review: https://blog.mylifenote.ai/rosebud-review/
- Best private AI journaling apps, 2026: https://merrin.xyz/articles/best-private-ai-journaling-apps-2026/
- Journaling app privacy guide: https://journal-gems-blog.pages.dev/blog/journaling-app-privacy/
