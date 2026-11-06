# AI processing and retention (LM-43)

Last researched: 2026-11-05. Terms change; re-check each link before quoting
it in user-facing copy. Anything marked **unverified** is not established by a
primary source, and the line says what would confirm it.

## 1. What leaves the device, and where it goes

| Provider / model | Call site | Receives | Reachable from the iOS app? |
| --- | --- | --- | --- |
| Gemini Live `gemini-3.1-flash-live-preview` | `lib/services/gemini_live_client.dart` opens a WebSocket straight to `generativelanguage.googleapis.com` with an ephemeral token minted by `infra/lambda/live-session/core.mjs` (`POST /v1beta/auth_tokens`, key from secret `echo-insights/gemini-api-key`) | Live microphone audio (PCM), the system instruction (which can carry retrieved memory and the contextual-opening brief), tool calls and results, and Gemini's audio replies. Input and output transcription are switched on. | Yes |
| Gemini 2.5 Flash, extraction | `infra/lambda/extract-graph/core.mjs` (`generateContent`, `gemini-2.5-flash`, thinking budget 0) | Transcript text of the turns plus extraction context (existing entity names) | Yes |
| Gemini 2.5 Flash, session card | `infra/lambda/close-session/core.mjs` | Notebook content for the session (transcript and notes) | Yes |
| Gemini 2.5 Flash, brief | `infra/lambda/close-session/brief.mjs` | Notebook content and the previous brief | Yes |
| Gemini TTS `gemini-2.5-flash-preview-tts` (env `GEMINI_TTS_MODEL`) | `infra/lambda/close-session/brief.mjs` | The one-sentence opening line, derived from the user's journal | Yes |
| Supabase `gte-small` embeddings | `supabase/functions/_shared/embedder.ts`, `embed-entities`, `retrieve-memory` | Entity text and queries. Runs inside Supabase's edge runtime (`Supabase.ai.Session`). No third-party model API. | Yes |
| Groq `llama-3.3-70b-versatile` | `supabase/functions/extract-graph/index.ts` | Conversation text, if called | Not called by the Flutter app or any in-repo code (see finding F1) |
| ElevenLabs TTS | `supabase/functions/speak-agent/index.ts`; called from the web app only (`src/lib/agent-voice.ts`) | Text the agent is about to speak | Not by Flutter; yes by the web app (F2) |
| Gemini Live, web client | `src/lib/gemini-live-client.ts:22` connects to `BidiGenerateContentConstrained` with `sessionToken`; the token comes from the same `live-session` Lambda (via the notebook runtime `/live-sessions` route, `src/lib/notebook-runtime-http.ts`), so it is minted with the key in `echo-insights/gemini-api-key` | Same as the iOS Live row: microphone audio, instructions, tool traffic, replies | Web app only (F3) |
| ElevenLabs TTS, browser-direct | `src/lib/agent-voice.ts:166-167` and `requestElevenLabsDirect` at `:193`: when `VITE_ELEVENLABS_API_KEY` is set, the browser posts text straight to `api.elevenlabs.io` with that key, bypassing `speak-agent`. The key is in the client bundle. | Text the agent is about to speak | Web app only (F2) |
| Gemini 2.5 Flash, web extractor | `src/lib/extract-graph.ts` calls `generativelanguage.googleapis.com` from the browser with `VITE_GEMINI_API_KEY` | Transcript text | Web app only (F3) |

Settings that bear on retention, as found in the repo:

- **Context caching:** none. No `cachedContent`, no explicit cache creation anywhere.
- **`store` flag:** none. Lumen does not use the Interactions API, where `store` defaults to true.
- **Session resumption:** ON in `gemini_live_client.dart` (`session_resumption` in the setup message, handle kept in memory and reused on reconnect). See section 3.
- **Context window compression:** ON (sliding window). No retention effect documented.
- **Grounding (Google Search or Maps):** none used.
- **Server-side logging toggles:** not set by code. Console-side only (section 4).
- Lambda and edge logs: the Lambdas log metrics (counts, timings), not content. That is LM-45's scope and is not re-audited here.

## 2. Google's terms, as checked on 2026-11-05

### Gemini API, free (unpaid) vs paid

Source: [Gemini API Additional Terms of Service](https://ai.google.dev/gemini-api/terms) (redirects to `aistudio.google.com/docs/terms`). Checked 2026-11-05.

| | Unpaid services | Paid services (billing-enabled project) |
| --- | --- | --- |
| Used to improve Google products and train models | Yes | No. Google does not use prompts or responses to improve its products. |
| Human review | Yes. Reviewers may read, annotate and process input and output (disconnected from account, key and project first). | Not addressed in the terms. **Unverified**. Confirm with Google Cloud support or the DPA text. |
| Logging | No retention period stated | Prompts and responses are logged "for a limited period of time", no number given, solely for abuse detection (Prohibited Use Policy) and legal disclosure. Data may be stored transiently or cached in any country where Google operates. |
| Zero retention option | Not offered | Not mentioned anywhere on the paid terms page |
| Data terms | Controller-style; in EEA/UK/CH the paid terms apply to all services | Data Processing Addendum for Products Where Google is a Data Processor |

Per product (Live, 2.5 Flash, TTS): the terms and the logs page make no per-product distinction. Both treat "the Services" uniformly, with exceptions only for Grounding with Google Search and Maps (30-day storage, both tiers). That Live, Flash and TTS (a preview model) are handled identically is therefore the documented default but is **unverified for preview models**. Confirm with Google Cloud support or the DPA.

Project logging: [Logging and retention](https://ai.google.dev/gemini-api/docs/logs-policy) (redirects to `aistudio.google.com/docs/logs-policy`). Checked 2026-11-05.
- Developer-owned logs, private to the project, separate from abuse-monitoring logs.
- On for Generate Content calls by default in projects created on or after 2026-10-26; on by default for the Interactions API. Billing-enabled projects only.
- Default retention up to 55 days (AI Studio lets you pick 7, 14, 28 or 55); datasets have no retention limit. Can be turned off at any time on the Logs and Datasets page.
- Not used for product improvement by default. Sharing a dataset allows human review.
- The page offers no zero-retention option and gives no retention period for the separate abuse-monitoring logs.

Whether the paid Gemini API offers any zero-retention option: **No, none documented.** The most that can be done is to avoid optional storage (project logging off, no Interactions `store`, no caching, no grounding), which still leaves the undocumented-length abuse-monitoring log.

### Vertex AI

Sources, all checked 2026-11-05:
[Data governance and ZDR](https://cloud.google.com/vertex-ai/generative-ai/docs/data-governance),
[Abuse monitoring](https://cloud.google.com/vertex-ai/generative-ai/docs/learn/abuse-monitoring),
[Cloud Service Terms](https://cloud.google.com/terms/service-terms) (section 18 no training; 20(h) prompts not stored outside the customer account longer than needed to create output; exceptions for Search and Maps grounding).

- **ZDR conditions** (data-governance page): request-response logging off; no Interactions `store`; Sandbox Snapshot API unused; caching off (in-memory cache is deleted within 24 hours, durable cache within 24 hours, both disabled per project with `cacheConfig`: `disableCache`); no Grounding with Google Search (query logs kept up to 3 days, cannot be disabled) or Maps (30 days).
- **Abuse monitoring:** standard Google models, flagged prompts may be logged for review, up to 90 days. The page also describes a Frontier-model tier where prompts and responses may be logged, stored in the customer's environment for up to 30 days. Which tier the Live models fall into is **unverified**; confirm with Google Cloud support. If Live is in the Frontier tier, a Vertex migration would still keep logs for up to 30 days unless the Master Agreement exemption applies. Customers with a Google Cloud **Master Agreement** are exempt from prompt logging for abuse monitoring by default. The page names no self-serve request form; for opt-outs on Advanced AI features it says to contact the account team. Whether Lumen (on standard online terms, not a Master Agreement) gets the exemption automatically is **unverified**. Confirm by asking Google Cloud sales or support to state in writing that the project is exempt.
- **Live API on Vertex:** [Live API](https://cloud.google.com/vertex-ai/generative-ai/docs/live-api) lists `gemini-3.8-live` (GA) and `gemini-live-2.5-flash-native-audio` (GA). Lumen's `gemini-3.1-flash-live-preview` is **not listed** there; unverified whether it exists on Vertex (a developer-forum thread titled "Gemini 3.1 Flash Live Preview on Vertex AI — EU region availability?" exists but was not read). Regions: the page states none; the WebSocket endpoint is regional (`LOCATION-aiplatform.googleapis.com`).
- **Ephemeral tokens on Vertex:** **No evidence they exist.** The ephemeral-token page is Gemini Developer API only and never mentions Vertex. Vertex's Live API reference says it only provides server-to-server authentication and recommends a proxy server for clients, authenticating with OAuth 2.0 bearer tokens or ADC. Lumen's phone-to-Google direct WebSocket design would not work as-is; a WebSocket proxy would have to carry live audio (see section 5).
- **Session resumption on Vertex:** off by default; when on, text, audio, video prompts and model outputs are stored at rest for up to 24 hours. The page says: for zero data retention, do not enable it. ([Start and manage sessions](https://cloud.google.com/vertex-ai/generative-ai/docs/live-api/start-manage-session))

### Gemini Live session resumption (Gemini API)

Source: [Session management](https://ai.google.dev/gemini-api/docs/live-session) (redirects to `aistudio.google.com/docs/live-api/session-management`). Checked 2026-11-05.
- Resumption tokens are valid for 2 hours after the last session termination.
- The page implies the server keeps session state (that is how a handle restores context) but **does not state where it is stored or for how long**. The 2 hour validity is the only bound published. Whether that state counts as covered by the 55-day logging setting or the abuse log is **unverified**. Confirm with Google Cloud support.

## 3. Findings from the audit

- **F1 (reachable, not covered by Lumen's Google terms): Groq.** `supabase/functions/extract-graph` still sends conversation text to Groq (`llama-3.3-70b-versatile`). Nothing in the repo calls it (the web app migrated to Gemini, see the header of `src/lib/extract-graph.ts`; Flutter uses the Lambda). It is declared in `supabase/config.toml` with `verify_jwt = true`, so if deployed with `GROQ_API_KEY` set, any signed-in user can invoke it. Whether it is deployed or the secret is set is **unverified** without console access. Recommended: delete the function and the `GROQ_API_KEY` secret (separate ticket; not done here). Groq terms are not researched in this document.
- **F2: ElevenLabs (two web paths).** (a) `supabase/functions/speak-agent` sends text to ElevenLabs; the web app calls it, Flutter does not, and any signed-in user can invoke it if the secret is set. (b) `src/lib/agent-voice.ts:166-167` / `requestElevenLabsDirect` (`:193`): if `VITE_ELEVENLABS_API_KEY` is set, the browser sends text straight to `api.elevenlabs.io`, bypassing `speak-agent`, with the key shipped in the client bundle. There is also an optional custom endpoint (`VITE_AGENT_TTS_URL`) whose destination is unknown. ElevenLabs' retention and training terms are **unverified**: not researched here. Confirm from ElevenLabs' terms and data-processing documentation, or retire both paths.
- **F3: web app has two Gemini paths with different keys.** (a) The web Live client (`src/lib/gemini-live-client.ts:22`) uses a token from the `live-session` Lambda, so it is minted by the `echo-insights/gemini-api-key` secret and is covered by the billing switch. (b) `src/lib/extract-graph.ts` calls Gemini 2.5 Flash directly with `VITE_GEMINI_API_KEY`, a separate browser-held key. If that key's project is not billed, those calls stay on the free tier. A key in a client bundle is also a separate security problem. The billing step below must cover every key: the secret's key and `VITE_GEMINI_API_KEY`.
- **F4 (retention-affecting, not a one-line fix): session resumption is on** in `gemini_live_client.dart`. It makes reconnects keep context, so removing it is a behaviour change, not a one-liner. It matters only if Lumen migrates to Vertex ZDR (where it must be off) or if Google confirms resumption state is retained beyond what the claim below allows. Not changed.
- No other model providers were found (checked lib, infra, supabase, src, package.json; no analytics or crash SDKs match). `@ai-sdk/groq` is still in `package.json` but unused by `src`.

## 4. User actions

1. Enable billing on the Google Cloud project that owns the key stored in AWS secret `echo-insights/gemini-api-key`. Confirm in AI Studio that the key shows a paid tier.
2. Confirm the same for `VITE_GEMINI_API_KEY` (web) and any other Gemini key; point them at the billed project or remove the web path (F3).
3. In AI Studio, Logs and Datasets: check whether project logging is on for this project (default on for projects created on or after 2026-10-26). Turn it off unless retention is wanted. Do not create or share datasets from it.
4. Run a 10-call burst against the billed key (for example 10 `POST /v1beta/auth_tokens` mints plus a few `generateContent` calls) and confirm no 429s. Do not paste the key into a shell command line; use the Lambda or a script that reads it from the environment.
5. Check the Groq and ElevenLabs edge functions and secrets in the Supabase project (F1, F2), and remove them if unused.
6. Ask Google Cloud support in writing: (a) whether paid-tier prompts and responses for `gemini-3.1-flash-live-preview` and `gemini-2.5-flash-preview-tts` are handled like other paid models; (b) the abuse-monitoring log retention period; (c) where resumption state is held and for how long; (d) whether human review applies to paid use.

## 5. Recommendation: paid Gemini API, not Vertex, for now

Use the paid Gemini API. It removes training use and human review of prompts per the paid terms, ends the free-tier 429s, and requires no code change.

Vertex ZDR is the only route to a documented "no retention" posture, but it is not drop-in for Lumen:
- Ephemeral tokens are not documented on Vertex, so the app would need a WebSocket proxy that carries live audio (new infrastructure, added latency, and the proxy sees plaintext audio).
- `gemini-3.1-flash-live-preview` is not on Vertex's documented list; the app would move to `gemini-3.8-live` or `gemini-live-2.5-flash-native-audio`, with re-tuning and re-testing of voice and tools.
- Session resumption must be turned off (F4), so reconnects lose context unless the client replays history.
- Caching disabled at project level, logging off, and a written abuse-monitoring exemption (Master Agreement customers get it by default; otherwise **unverified**).
- Gemini 2.5 Flash and TTS on Vertex: both would need Vertex clients and IAM service-account credentials instead of an API key.

Revisit Vertex if the privacy promise must be literally "the AI provider keeps nothing". Treat it as its own project, not a ticket-sized change.

## 6. What Lumen may claim

This feeds LM-53. Rule: "keeps nothing" only once LM-43 is verified, and even then only if the facts support it.

- **Today (free tier, before billing is on):** "To talk with you, Lumen sends your voice and text to Google's Gemini service." Do **not** say Google doesn't train on it or doesn't keep it. Under the unpaid terms Google may use it to improve its products and humans may review it.
- **After billing is on (steps 1 to 4 done and checked, including the web key):** this claim holds only when the iOS app is the surface being described, or when the web Gemini key (F3), the Groq function (F1) and both ElevenLabs paths (F2) are retired or accounted for. For a shipped web app that still uses ElevenLabs, Groq or an unbilled key, it would be false. "Your voice and text are processed by Google's paid Gemini API, which under Google's terms does not use them to train its models. Google may keep them for a limited period for abuse detection and legal reasons." That is the strongest accurate statement. Do **not** say "keeps nothing" or "deletes immediately": the paid Gemini API has no documented zero-retention mode, the abuse-log period is unpublished, and Live session resumption state is held for an unstated time (2 hours is only the handle validity).
- **"Keeps nothing" becomes allowable** only on Vertex with ZDR configured as in section 5 and the abuse-monitoring exemption confirmed in writing, or if Google confirms in writing that paid Gemini API retains nothing.
- The statements above cover Google only. Lumen's own storage (Supabase, AWS) and any Groq or ElevenLabs path (F1, F2) are separate and must be accounted for in the same copy.
