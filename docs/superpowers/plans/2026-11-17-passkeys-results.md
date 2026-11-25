# LM-127 results: passkeys on for release 1 (repo side)

Date: 2026-11-17. Branch `claude/rel-passkeys-cb3abf`. Nothing here is pushed or deployed, and no hosted project was touched.

## What changed in the repo

| Piece | File | State |
|---|---|---|
| AASA file | `public/.well-known/apple-app-site-association` | Served next to `security.txt`. Holds the placeholder `REPLACE_WITH_APPLE_TEAM_ID`. |
| JSON content type | `public/_headers` | Cloudflare static-assets rule so the extensionless file is `application/json`. |
| Entitlement | `ios/Runner/Runner.entitlements` | `webcredentials:REPLACE_WITH_RELYING_PARTY_DOMAIN`. |
| Release define | `.github/workflows/flutter-retrieval-release.yml` | The release build passes `--dart-define=PASSKEYS_ENABLED=true`. |
| Ignore comment (LM-79) | `lib/services/account_auth_service.dart` | `ignore_for_file: experimental_member_use` moved to the top of the file, above the imports. |
| Guard tests | `test/passkey_release_config_test.dart` | Default off; AASA JSON names the bundle id; entitlement and `_headers` rule exist. |

### Release define or flipped default: define, and why

Chosen: keep the default off and pass the define in the release build command. Reasons:
- Debug, simulator and test builds keep hiding the passkey UI. With placeholders still in the entitlement and AASA file, an always-on button would fail in front of whoever taps it.
- Passkeys sit on a Supabase beta. A build-time define is a per-build switch: a release can ship with it off if the device test fails, with no code change.
- A "default is true" test would pin an unverified beta decision into the code. The test we have pins the opposite and is cheap to keep.

Every release build must pass the define. The CI unsigned build now does. For a signed archive built by hand:

```bash
flutter build ipa --release \
  --dart-define-from-file=<your release env file> \
  --dart-define=PASSKEYS_ENABLED=true
```

## AASA hosting check

The web app deploys to Cloudflare Workers (`wrangler.jsonc`, static assets from `public/`). Extensionless files are not given a JSON type by extension, which is why `public/_headers` exists.

Checked locally on 2026-11-17: `npm run build`, then `wrangler dev -c dist/server/wrangler.json`. Result: `GET /.well-known/apple-app-site-association` returned `200`, `Content-Type: application/json`, no redirect, and wrangler logged "Parsed 1 valid header rule". `dist/client/` contained `_headers`, the AASA file and `security.txt`. The real host was not checked.

Check the deployed host once the file is live, with the real values filled in:

```bash
curl -sSI https://<domain>/.well-known/apple-app-site-association
```

Expect `HTTP/2 200` (no `301`/`302`) and `content-type: application/json`. Apple's CDN caches the file, so a fix can take a while to reach devices.

**Deploy order (reverses the usual web-after-iOS rule for this one file):** the AASA file must be live before the iOS build ships, but `/security` must not go early (it describes iPhone-only controls). Deploy only the file early, for example a one-off deploy of a build that contains this file and `_headers` without the `/security` changes. Do not deploy the whole web app early.

## Supabase docs re-read (2026-11-17) against LM-58

Source: Supabase "Passkey authentication" guide and the passkeys changelog entry (beta announced 2026-05-28).

Still true:
- Beta, experimental, may change without notice. The guide has no changelog.
- Minimum clients: `supabase_flutter` 2.15.0 (we have `^2.15.0`) and `passkeys` 2.21.0+ (we have `^2.24.1`).
- Flutter: you pass your own authenticator (`PasskeyAuthenticator`) to `registerPasskey` and `signInWithPasskey`; `auth.passkey.list()` and `auth.passkey.delete(passkeyId:)`. This is exactly what `SupabaseAuthGateway` calls.
- Dashboard: Authentication, Passkeys, "Enable Passkey authentication"; Relying Party Display Name, Relying Party ID (bare domain), up to 5 origins (HTTPS, each matching or under the ID). Changing the ID later invalidates enrolled passkeys.

New or worth noting since LM-58 (none breaks the code):
- Settings are also exposed in `config.toml` (`[auth.passkey]`, `[auth.webauthn]`) and the Management API (`passkey_enabled`, `webauthn_rp_*`). Dashboard remains the plan.
- `auth.passkey.update(...)` (rename) exists. The app does not use it.
- Limits: SSO users cannot register passkeys; anonymous users cannot until they link an email or phone; unconfirmed or banned users cannot sign in; there is a per-account cap (`too_many_passkeys`, number not stated). The app's UI is only offered to signed-in email/Apple accounts, so SSO and anonymous do not apply, but `too_many_passkeys` would surface as a generic error. Not handled; low priority.
- The guide does not mention the AASA file by name; Apple's Associated Domains docs cover it.

Conclusion: the existing code still matches the documented API. No code change was needed beyond the ignore-comment placement. The community reports of registration errors in the beta remain unverified; the device test below is the check.

## Your console steps (in this order)

1. **Choose the relying-party domain.** A bare domain you control, normally the web app's. It cannot change after people enroll.
2. **Fill the placeholders** (find them with `grep -rn REPLACE_WITH .`):
   - `public/.well-known/apple-app-site-association`: `REPLACE_WITH_APPLE_TEAM_ID` is your 10-character Apple Team ID (Apple Developer, Membership details).
   - `ios/Runner/Runner.entitlements`: `REPLACE_WITH_RELYING_PARTY_DOMAIN` is the domain from step 1, with no scheme.
   Then rebuild the web app and run the AASA deploy described above, and confirm with the `curl` check.
3. **Apple Developer, Identifiers, `com.echoinsights.lumen`:** turn on Associated Domains. Regenerate the provisioning profile (development and distribution) and let Xcode pick it up. A device build will not sign until the profile includes the capability; the simulator build does not need it.
4. **Supabase dashboard, staging first, then production (`bjoevzvsdlhlcjywpyfx`):** Authentication, Passkeys. Enable it; Relying Party Display Name `Lumen`; Relying Party ID the bare domain from step 1; Origins `https://<domain>` (up to 5). Anything that looks different on your screen: mark it unverified in the LM-121 notes.
5. **Build with the define** (the CI release build already has it; hand-built archives need the command above).

## Device test lines for LM-121 (real iPhone, against staging; date each pass or file a defect)

- [ ] Add a passkey from Privacy, Sign-in and devices (Face ID prompt appears; it appears in the list).
- [ ] Sign out, then sign in with the passkey (no email typed).
- [ ] Cancel the passkey sheet during sign-in: no error is shown, the login screen stays.
- [ ] Cancel the sheet during add: nothing is added, no error.
- [ ] An account with both an email and a passkey is still one account (same notes and graph after either sign-in).
- [ ] Remove the passkey: it is gone from the list and can no longer sign in.
- [ ] A build without the define (debug run without `PASSKEYS_ENABLED`) shows no passkey button.
- [ ] If the sheet errors on add (the reported beta registration errors), record the exact message and the Supabase auth log line.

A defect here blocks release 1 (decision 3), unless the build is made with the define off.
