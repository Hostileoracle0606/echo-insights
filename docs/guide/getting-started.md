# Getting started

There are two paths:

1. **[Run the app](#1-run-the-app)** against a backend that already exists. This takes
   about five minutes.
2. **[Stand up your own backend](#2-stand-up-your-own-backend)**: Supabase
   and the AWS runtime. Allow about an hour, most of it waiting on deploys.

## Prerequisites

| Tool | Version | Used for |
| --- | --- | --- |
| [Flutter](https://docs.flutter.dev/get-started/install/macos) | ≥ 3.22 (Dart ≥ 3.4) | The app |
| Xcode + CocoaPods | iOS 16.0+ target | Building for iPhone / Simulator |
| Node.js | 20+ (CI uses 22) | Web client, scripts, CDK |
| [Supabase CLI](https://supabase.com/docs/guides/cli) | latest | Migrations, Edge Functions |
| [Deno](https://deno.com) | 2.x | Edge Function tests |
| AWS CLI + CDK | CDK v2 | The runtime API |

---

## 1. Run the app

```bash
flutter pub get
```

Create `.env.dev` in the repo root. It's covered by the `.env.*` ignore rule
and passed at build time only; nothing is bundled as an asset:

```dotenv
SUPABASE_URL=https://<project-ref>.supabase.co
SUPABASE_PUBLISHABLE_KEY=<publishable or anon key>
NOTEBOOK_RUNTIME_URL=https://<api-id>.execute-api.<region>.amazonaws.com
```

Then run on the Simulator or a connected iPhone:

```bash
flutter run --dart-define-from-file=.env.dev
```

### Configuration reference

The app reads its configuration in [`lib/env.dart`](../../lib/env.dart). Each
setting accepts several names (first match wins), so one file can serve both
the web and Flutter builds:

| Setting | Accepted names | Notes |
| --- | --- | --- |
| Supabase URL | `SUPABASE_URL`, `VITE_SUPABASE_URL` | |
| Supabase key | `SUPABASE_ANON_KEY`, `SUPABASE_PUBLISHABLE_KEY`, `VITE_SUPABASE_PUBLISHABLE_KEY` | Public key only. Never the service role |
| Runtime URL | `NOTEBOOK_RUNTIME_URL`, `VITE_NOTEBOOK_RUNTIME_URL` | The `NotebookRuntimeUrl` CDK output. The app appends `/v1/…` |

> [!IMPORTANT]
> Never put a Gemini, ElevenLabs, Groq or service-role key in a client
> config. The release build is scanned for credentials by
> `scripts/production-secrets.mjs` and fails if it finds one.

### Building for a device

```bash
flutter build ios --release --dart-define-from-file=.env.prod
```

Signing uses automatic provisioning (bundle id `com.echoinsights.lumen`).
Change `DEVELOPMENT_TEAM` in Xcode to your own team if you're building from a
fork. The microphone usage string is already set in `ios/Runner/Info.plist`.

### Running the web client (optional)

`src/` holds the original TanStack Start + React client. It shares the turn
state rules with the app and is still useful for quick UI experiments.

```bash
npm install
```

```bash
npm run dev
```

It serves on `http://localhost:8080` and reads `VITE_SUPABASE_URL`,
`VITE_SUPABASE_PUBLISHABLE_KEY` and `VITE_NOTEBOOK_RUNTIME_URL` from `.env.local`.

---

## 2. Stand up your own backend

Order matters: **database → Edge Functions → AWS runtime → app.** Each layer
depends on the one before it.

### 2.1 Supabase project

Create a project, then link and push the schema:

```bash
supabase link --project-ref <project-ref>
```

```bash
supabase db push --linked
```

This applies everything in [`supabase/migrations/`](../../supabase/migrations):
tables, RLS policies, RPCs, the `pgvector`/`pg_net`/`pg_cron` setup and the
embedding trigger.

### 2.2 Edge Functions

```bash
supabase functions deploy retrieve-memory
```

```bash
supabase functions deploy embed-entities
```

Set the shared secret that lets the database trigger call `embed-entities`:

```bash
supabase secrets set EMBED_INTERNAL_SECRET=<long random string>
```

Then store the **same value** and the function URL in **Vault** (SQL editor),
since the trigger and cron jobs read them from there:

```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/embed-entities', 'embed_entities_url');
select vault.create_secret('<same long random string>', 'embed_internal_secret');
```

> [!TIP]
> If embeddings never appear, look at `net._http_response`. A `403` means the
> Vault secret and the function secret don't match. Re-set both to the same
> value.

`extract-graph` and `speak-agent` are used only by the web client. The app
uses the AWS runtime for extraction.

### 2.3 AWS runtime

See [`infra/README.md`](../../infra/README.md) for the full reference.

```bash
cd infra && npm install && npm test
```

```bash
npx cdk deploy --parameters SupabaseUrl=https://<project-ref>.supabase.co --parameters SupabasePublishableKey=<key>
```

Optional parameters: `WebOrigin` (enables CORS for the web client; leave empty
for native only) and `WorkerReservedConcurrency`.

After the deploy, enter the Gemini API key **directly** into the
`echo-insights/gemini-api-key` secret in Secrets Manager, using the console or a
hidden prompt. It is deliberately not a deploy parameter and must never appear
in a committed command.

The `NotebookRuntimeUrl` stack output is your `NOTEBOOK_RUNTIME_URL`.

### 2.4 Point the app at it

Put the three values in `.env.dev` (see [above](#1-run-the-app)) and run.

### Deploying changes later

When a change spans layers, deploy **migrations first, then functions and the
runtime, then the app**. A new app build may write columns or call routes that
an older backend doesn't have. See [Backend → Deploy order](backend.md#deploy-order).

---

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| Stuck on **Connecting** | `NOTEBOOK_RUNTIME_URL` wrong, or the Gemini secret not set in Secrets Manager |
| Mic never opens | Microphone permission denied. Check iOS Settings › Lumen |
| Lumen hears itself | Running a build from before the native voice engine. Make sure `VoiceEnginePlugin` is registered in `AppDelegate.swift` |
| Graph never fills | Extraction route failing. Check the `extract-graph` Lambda logs |
| Recall feels lexical only | Embeddings missing. See the Vault tip above |
| `401` from the runtime | Session expired. Sign out and back in |
