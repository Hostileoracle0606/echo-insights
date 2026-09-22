# iOS release runbook

How to produce a signed Lumen build that App Store Connect will accept, and
upload it. Written for someone who has never built this app.

Signing is done **locally from a Mac**. CI (`.github/workflows/flutter-retrieval-release.yml`)
only builds an unsigned `.app` to prove the release compiles and carries no
bundled credentials. No Apple secrets live in CI.

| Thing | Value |
|---|---|
| Bundle ID | `com.echoinsights.lumen` |
| Team ID | `ZFQ35TYCLA` (`DEVELOPMENT_TEAM` in `ios/Runner.xcodeproj`) |
| Export options | `ios/ExportOptions.plist` (`app-store-connect`, automatic signing, symbols uploaded) |
| Build entry point | `scripts/ios-build.mjs` (via `npm run release:ios:ipa`) |
| Minimum iOS | 16.0 |

---

## 1. Prerequisites

### On the Mac

- **Xcode**: the current release from the Mac App Store. App Store Connect
  rejects uploads built with an SDK older than Apple's current minimum, so do
  not use an old Xcode. Run `xcode-select -p`; it should point inside
  `Xcode.app`. Accept the licence once with `sudo xcodebuild -license accept`.
- **Flutter**: stable channel (`flutter --version`). `flutter doctor` must
  show no errors under *Xcode*.
- **CocoaPods**: `pod --version`. Install with `brew install cocoapods` if
  it's missing.
- **Node 20+**: runs the build script.

### In the Apple Developer account (team `ZFQ35TYCLA`)

- You must be a team member with the **App Manager** or **Admin** role, so
  Xcode can create distribution signing assets.
- Sign in to Xcode: *Xcode → Settings → Accounts → +*, using that Apple ID.
  With automatic signing, Xcode creates or downloads the **Apple Distribution**
  certificate and the App Store provisioning profile during export. To check
  that the certificate is present, run
  `security find-identity -v -p codesigning | grep "Apple Distribution"`.
- The App ID `com.echoinsights.lumen` must have the **Background Modes**
  capability available. Automatic signing registers this when the capability
  is enabled on the Runner target (see §6).

### In App Store Connect

- An **app record** for bundle ID `com.echoinsights.lumen` must exist
  (*Apps → + → New App*). Uploads to a bundle ID with no record are rejected.
  Creating the record, and the hosted privacy policy URL it requires, are
  outside this repository and have lead time. Start them first.

### Configuration values

The build requires these values, from the Supabase project and the `infra/`
stack; they are the same values CI uses:

| Variable | What it is |
|---|---|
| `SUPABASE_URL` | Project URL, `https://<ref>.supabase.co` |
| `SUPABASE_ANON_KEY` | Project publishable/anon key (public by design; RLS protects data) |
| `NOTEBOOK_RUNTIME_URL` | The `NotebookRuntimeUrl` output of the `infra/` stack (see `infra/README.md`) |
| `PRIVACY_POLICY_URL` | The hosted privacy policy, linked from the in-app account sheet. **Required for the signed `ipa` build only**; the unsigned CI build passes it through if set. |

Never put the service-role key, `GEMINI_API_KEY` or any other server secret
here. Gemini credentials are minted per session by the backend.

### Backend the build depends on

In-app account deletion needs its migration and edge function deployed to the
same Supabase project the build points at. The retrieval CI job does not
deploy them:

```sh
supabase link --project-ref <ref>
supabase db push                               # includes 20260922000000_account_deletion.sql
supabase functions deploy delete-account --project-ref <ref>
```

`delete-account` uses the project's built-in `SUPABASE_SERVICE_ROLE_KEY`; it
needs no extra secret. Check it on a throwaway account before submitting:
sign up, record a turn, then *Account → Delete account*. Afterwards,
*Authentication → Users* should no longer list the account.

---

## 2. Build the signed archive

From the repository root:

```sh
flutter pub get
(cd ios && pod install)

export SUPABASE_URL=https://<ref>.supabase.co
export SUPABASE_ANON_KEY=<publishable key>
export NOTEBOOK_RUNTIME_URL=<NotebookRuntimeUrl stack output>
export PRIVACY_POLICY_URL=https://<your policy host>/privacy

npm run release:ios:ipa -- --build-name=1.0.0 --build-number=<N>
```

`scripts/ios-build.mjs` refuses to run if any of these variables is missing
or empty. It names every missing one and exits nonzero **before**
Flutter starts, so an archive with no backend cannot be produced this way.
Do not call `flutter build ipa` directly; that skips this check, and
`lib/main.dart` would then stop the app at launch with a `StateError` naming
the missing values.

`--build-number` must be higher than every build already uploaded for that
version. Anything after `--` is passed straight to `flutter build`.

Output:

- `build/ios/archive/Runner.xcarchive`, the archive (open it in Xcode's
  Organizer if you need to inspect it)
- `build/ios/ipa/*.ipa`, the App Store-signed binary to upload

Before uploading, check that no credentials were bundled:

```sh
node scripts/production-secrets.mjs build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app
```

For an unsigned smoke build (what CI runs), use `npm run release:ios:unsigned`.
It runs the retrieval release gate first, which needs server credentials, so
on a laptop run `node scripts/ios-build.mjs ios` directly instead.

---

## 3. Upload

Use one of these.

**Transporter** (simplest): install *Transporter* from the Mac App Store,
sign in with the team Apple ID, drag in `build/ios/ipa/<name>.ipa`, and choose
**Deliver**.

**Command line**: create an App Store Connect API key (*Users and Access →
Integrations → App Store Connect API*, role *App Manager*) and put the `.p8`
file at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`. Then:

```sh
xcrun altool --validate-app -f build/ios/ipa/*.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```

Processing takes 5 to 30 minutes. The build then shows up under *TestFlight*,
and App Store Connect emails the account holder if processing rejects it (for
example, a missing purpose string or an invalid icon).

---

## 4. When the archive is signed for development instead of distribution

Symptoms: `flutter build ipa` reports `exportArchive: No signing certificate
"iOS Distribution" found`, or `No profiles for 'com.echoinsights.lumen' were
found`. Or the `.ipa` uploads, but validation says it has a development
provisioning profile / `get-task-allow` entitlement.

Work through these in order:

1. **Check what the archive was signed with:**
   ```sh
   codesign -dvv build/ios/archive/Runner.xcarchive/Products/Applications/Runner.app 2>&1 | grep Authority
   ```
   The archive itself is always signed with *Apple Development*. That's
   expected; export re-signs it. The exported `.ipa` must show *Apple
   Distribution*:
   ```sh
   unzip -oq build/ios/ipa/*.ipa -d /tmp/lumen-ipa
   codesign -dvv /tmp/lumen-ipa/Payload/Runner.app 2>&1 | grep Authority
   ```
2. **Confirm export used `ios/ExportOptions.plist`.** `method` must be
   `app-store-connect`. If you ran `flutter build ipa` without
   `--export-options-plist`, Flutter chose the export method and signing on
   its own. Rebuild with `npm run release:ios:ipa`.
3. **Confirm Xcode can create a distribution certificate.** In *Xcode →
   Settings → Accounts → (team) → Manage Certificates*, there must be an
   *Apple Distribution* entry, or a **+** that can create one. If **+** is
   greyed out, your role is below App Manager. Ask an Admin.
4. **Confirm the target signs automatically for team `ZFQ35TYCLA`.** Open
   `ios/Runner.xcworkspace` (the workspace, not the `.xcodeproj`). Under
   *Runner → Signing & Capabilities*, for the **Release** configuration,
   *Automatically manage signing* must be on and *Team* must be the Echo
   Insights team. Fix any red error shown there first.
5. **Fall back to Xcode's Organizer.** Open the archive with
   `open build/ios/archive/Runner.xcarchive`, then choose *Distribute App →
   App Store Connect → Upload*. Organizer shows the signing identity it picks
   and why, which is the fastest way to see the underlying problem.
6. If a stale profile keeps getting picked, delete
   `~/Library/MobileDevice/Provisioning Profiles/*` (Xcode 15 and earlier) or
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/*` (Xcode 16 and
   later), then rebuild.

---

## 5. Pre-submission checklist

- [ ] App Store Connect app record exists
- [ ] Hosted privacy policy URL is live and entered in App Store Connect
- [ ] App Privacy (nutrition label) answers entered (see §7)
- [ ] Demo account created and entered under *App Review Information*
      (see §6)
- [ ] `ios/Podfile.lock` regenerated on a Mac and committed
- [ ] Build uploaded, processed, and installed from TestFlight on a physical
      iPhone
- [ ] Sign in, record a turn, background the app mid-turn, take a phone call,
      return, sign out, sign back in, delete the account
