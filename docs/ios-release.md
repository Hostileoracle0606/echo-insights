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
  is enabled on the Runner target (see §5).

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

When regenerating `ios/Podfile.lock`, use `pod install --repo-update` and
review the complete diff before committing. `permission_handler_apple` must
appear in both `PODS` and `SPEC CHECKSUMS`; verify its generated build settings
contain `PERMISSION_MICROPHONE=1`. The pinned `path_provider_foundation` 2.6.0
uses direct Dart/FFI calls to Foundation and has no podspec, so its absence
from `Podfile.lock` is expected. Do not add a synthetic pod entry.

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

If even a simulator build fails with `resource fork, Finder information, or
similar detritus not allowed`, inspect the affected generated bundle with
`xattr -lr <bundle>`. A checkout under a synced Documents folder can acquire
`com.apple.FinderInfo` metadata during builds. Use a checkout outside that
folder and regenerate build output before retrying. Do not disable code
signing to hide this error. On the release Mac, moving only `build` behind a
symlink was insufficient; moving the worktree and generating fresh output
resolved the simulator failure.

---

## 5. Background audio: capability and App Review notes

`ios/Runner/Info.plist` declares `UIBackgroundModes` → `audio`, so a journaling
session keeps recording when the screen locks or the user switches apps.
Choosing this was deliberate, and it gets extra App Review scrutiny.

**One-time Xcode step (needs a Mac):** open `ios/Runner.xcworkspace` → *Runner*
target → *Signing & Capabilities* → **+ Capability** → *Background Modes* →
tick **Audio, AirPlay, and Picture in Picture**. That records the capability on
the target so automatic signing includes it in the provisioning profile. The
plist key alone is what the OS reads at runtime, but review and signing expect
the capability to be enabled on the target too. Commit the resulting
`project.pbxproj` change.

**App Review Information → Notes.** Paste this and fill in the demo account:

> Lumen is a voice journal. The user starts a journaling session and talks;
> Lumen listens, replies by voice, and builds a personal knowledge graph from
> what was said.
>
> **Why background audio:** a journaling session is a continuous spoken
> conversation, often several minutes long. Users commonly lock the phone or
> put it in a pocket while talking, the same way they would during a phone
> call. The `audio` background mode keeps the microphone capture and the
> spoken replies running during an active session only. When the user ends
> the session, Lumen stops recording and releases the audio session, so it
> does no background audio work outside a session the user started. The
> microphone indicator is visible for the whole session.
>
> **To test:** sign in with the demo account below → tap **New notebook** →
> allow microphone access → speak for a few seconds → lock the phone and keep
> speaking → unlock: the transcript continues. Incoming calls pause the
> session, which resumes after the call.
>
> Demo account: `<email>` / `<password>`
>
> **Account deletion:** dashboard → person icon (top right) → *Delete account*.

Create the demo account in the production Supabase project and do **not**
delete it. App Review signs in with it. If it has no notebooks, the
reviewer's first view is the empty dashboard, which is fine.

Keep the claim true. If session recording is ever changed to stop when the
app goes to the background, remove the `audio` background mode in the same
change.

---

## 6. Privacy: manifest, nutrition labels, policy

### What the app actually does with data

| Data | Where it goes | Retained |
|---|---|---|
| Microphone audio (16 kHz PCM) | Streamed **from the device directly to Google** (`generativelanguage.googleapis.com`, Gemini Live API) over WSS during a session | Not stored by Lumen; Google's API data terms apply |
| Transcripts, journal entries, knowledge graph | Supabase (Lumen's backend) | Until the user deletes the account |
| Transcripts (in-flight turns) | On-device checkpoint files (Application Support, `turn-journal-v1`) | Until the turn is committed, or account deletion |
| Email address, account ID | Supabase Auth | Until the user deletes the account |
| Transcript text, for graph extraction | Lumen's runtime (`infra/`), which calls Gemini | Not stored beyond the request |

No analytics, advertising or tracking SDKs; no tracking domains.

### Privacy manifest

`ios/Runner/PrivacyInfo.xcprivacy` (bundled via the Runner target's
Resources phase) declares `NSPrivacyTracking = false` and collected types
**Audio Data**, **Other User Content**, **Email Address** and **User ID**,
all *linked to the user*, *not used for tracking*, purpose *App
Functionality*. It declares no required-reason APIs: the app's Dart code
calls none directly. Several native plugins ship their own manifests;
`path_provider_foundation` 2.6.0 instead uses direct Dart/FFI calls and ships
no native plugin manifest. Do not infer complete required-reason coverage
from the presence of plugin manifests alone. If App Store Connect's upload validation or the Xcode
*Privacy Report* (Organizer → archive → *Generate Privacy Report*) flags a
missing reason, add it to the app manifest then.

### App Store Connect → App Privacy (nutrition labels)

Answer **Yes, we collect data**, then:

| Category → type | Linked to user | Tracking | Purposes |
|---|---|---|---|
| Audio Data → *Voice or sound recordings* | Yes | No | App Functionality |
| User Content → *Other User Content* (journal transcripts and graph) | Yes | No | App Functionality |
| Contact Info → *Email Address* | Yes | No | App Functionality |
| Identifiers → *User ID* | Yes | No | App Functionality |

Apple counts data sent to a third-party partner as collected. The labels do
not name recipients, so **the transfer of microphone audio to Google (Gemini
Live API) must be disclosed in the privacy policy**. It is a data transfer,
not an implementation detail.

### Hosted privacy policy (external action)

A public URL is needed both in App Store Connect (*App Information → Privacy
Policy URL*) and in the app (the account sheet's *Privacy Policy* link, from
`PRIVACY_POLICY_URL`). At minimum the policy must say:

- what is collected (the table above);
- that voice audio is streamed to **Google** for real-time speech processing
  and replies, and transcript text is sent to Google for graph extraction;
- that Supabase hosts account and journal data;
- how to delete the account in the app (*Account → Delete account*), and
  that deletion removes all server data and the on-device journal;
- a contact address.

---

## 7. Pre-submission checklist

- [ ] App Store Connect app record exists
- [ ] Hosted privacy policy URL is live and entered in App Store Connect
- [ ] App Privacy (nutrition label) answers entered (see §6)
- [ ] Demo account created and entered under *App Review Information*
      (see §5)
- [ ] `ios/Podfile.lock` regenerated on a Mac and committed
- [ ] Build uploaded, processed, and installed from TestFlight on a physical
      iPhone
- [ ] Sign in, record a turn, background the app mid-turn, take a phone call,
      return, sign out, sign back in, delete the account
