# App Store privacy answers and privacy manifest (LM-119)

A draft for you to read and enter by hand in App Store Connect (App Privacy). Nothing was entered by an agent. Every answer comes from `docs/security/ai-processing.md`, `lib/privacy/privacy_claims.dart` and the code; where the repo cannot settle a fact it says **(unverified)** and what would settle it. You are the one attesting to Apple, so check each line against the release build.

Rule for the answers: they must say at least what `/privacy` and the in-app "Who hears you" screen say, and no less. Apple counts data sent off the device to a service (including Google) as **collected**, even if Lumen's own servers never keep it.

## 1. Tracking

**Does this app track users?** No. There is no advertising SDK, no analytics or crash SDK, and no data broker in `pubspec.yaml`, `ios/` or `lib/` (checked by search, 2026-11-17; `ai-processing.md` section 1 reached the same result). No data is combined with other companies' data for advertising. So: **no "Data Used to Track You"**, no `NSUserTracking` prompt, and no ATT string.

## 2. Data types

For every type below: **Linked to the user: Yes** (the data is held under the user's account), **Used for tracking: No**, **Purpose: App Functionality** only (no analytics, no personalization-for-ads, no marketing).

| Apple category → type | Collected? | What it is in Lumen | Where it goes |
| --- | --- | --- | --- |
| Contact Info → Email Address | Yes | The sign-up email (also an Apple private-relay address when someone uses Sign in with Apple and hides their email) | Supabase Auth |
| Identifiers → User ID | Yes | The account's Supabase user id | Supabase; sent as the sign-in token to Lumen's AWS functions |
| User Content → Audio Data | Yes | The live voice conversation; the spoken opening line (stored with the brief) | Google (live, to answer); the opening line's audio is saved in Supabase **(unverified: confirm in the release build that it is stored; `save_session_brief` accepts `p_audio_base64`, and a brief can be saved without audio)** |
| User Content → Other User Content | Yes | Transcripts, session cards, briefs, and the map of people and places | Supabase (stored); Google and AWS handle the text while it is processed |
| User Content → Customer Support, Photos or Videos, Gameplay | No | | |
| Contact Info → Name, Phone, Address | No, **unless** Sign in with Apple supplies a name and the app keeps it **(unverified: check `lib/services/account_auth_service.dart` and the user's `auth.users` row after an Apple sign-up; if a name is stored, add Contact Info → Name)** | | |
| Identifiers → Device ID | **Check** | The app lists signed-in devices (`device_sessions`), which wraps Supabase sessions; it is hidden for release 1 (R30) **(unverified: if the build sends a device name or identifier to the server, declare Device ID; otherwise No)** | |
| Usage Data, Diagnostics (crash, performance) | No (app side) | Lumen's AWS logs are content-free by design (LM-44) but may hold request metadata such as IP address, kept by AWS and Supabase as platform logs **(unverified: if you treat platform request logs as collected, add Diagnostics → Other Diagnostic Data, linked, not tracking, App Functionality)** | |
| Location, Contacts, Health & Fitness, Financial Info, Browsing History, Search History, Sensitive Info | No | | |

**Sensitive Info:** answer No. Journals can contain anything, but Apple's "Sensitive Info" category is for the specific fields it lists (racial or ethnic data, sexual orientation, pregnancy, disability, religious or philosophical beliefs, trade-union membership, political opinion, genetic or biometric data). Lumen does not ask for any of them as a field; the free text is covered by Other User Content. This is your reading of Apple's definition, so check the live wording on the form.

**Biometrics:** Face ID is used for app lock through `local_auth`; the app never receives biometric data, so nothing to declare.

### Release 1 decisions that touch these answers (2026-11-17)

- **Account deletion runs through a server queue.** "Delete my account" in the app calls the `delete-account` function, which deletes the account; a deletion worker (built by another session, **not in this branch yet**) removes what the cascade does not reach, including a deleted user's `auth.audit_log_entries` and `auth.flow_state` rows. What stays is only the user id and timestamps in `account_deletion_requests`, kept as proof the request was handled. Answer "yes, users can request deletion" and point to the in-app route. The form has no place for the retained record; if a field asks, the User ID row stays "collected" and the purpose is App Functionality. **<CONFIRM table name, what the worker purges and the retention of this record once the worker merges.>** Backups can outlive a delete for a limited time (`reachClaim`); do not say deletion is instant or complete everywhere.
- **Sign-in audit log is off.** You turn off "Write audit logs to the database" (Authentication, Audit Logs) on staging and production (runbook, section 2). So the app does not add sign-in audit rows with the user's email to the database. Sign-in records may still sit in the provider's own logs, kept for a limited time the provider sets, then removed (the line on `/privacy`). This does not remove Email Address or User ID from section 2, since the account itself holds them.
- **Passkeys are on.** A passkey adds a public key and a credential id to the account in Supabase Auth; the private key stays in the iPhone's Keychain, and Lumen never receives biometric data. It adds no Apple data type beyond Email Address and User ID already listed. Passkeys depend on Supabase's beta, so their device test (LM-121) must pass before you rely on them in the notes.

## 3. Answers that must not be stronger than the page

- Do not state or imply "data is encrypted in transit and at rest" in marketing text. `privacy_claims.dart` keeps `supabaseEncryptionVerified` false, so the app says only that the journal "isn't encrypted with a key only you hold".
- Do not state that Google does not train on the data: `paidTierVerified` is false until LM-123 is done and its checks pass.
- Do not say "we keep nothing" or that you cannot read journals.
- Deletion: the form asks whether users can request deletion. The in-app route ("Delete my account", LM-116) is merged and must be in the submitted build **(confirm on device)**.

## 4. Does the app need its own `PrivacyInfo.xcprivacy`?

**Answer: yes.** `ios/` has none, and the app's own Swift code uses a required-reason API.

- Evidence in the repo: `ios/Runner/AppDelegate.swift` lines 47 and 49 call `UserDefaults.standard.bool(forKey:)` and `.set(_:forKey:)` (the fresh-install flag, `lib/security/fresh_install.dart`). `UserDefaults` is a required-reason API category.
- What Apple requires: an app (or the code in its own target) that uses a required-reason API declares the category and an approved reason in the app's privacy manifest. Plugin manifests cover plugin code; they do not replace the app's declaration. Source: <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>. **That page returned only its title when fetched by the agent, so the category name and reason code below come from general knowledge, not the page text. Verify them against the live page before shipping.**
- Reason code for the app's own defaults: `CA92.1` (the app reads and writes its own defaults, nothing shared).
- Other required-reason APIs in the app target: none found. `AppDelegate.swift` line 87 calls `attributesOfItem` but reads only `.protectionKey`, not a creation or modification date; the other Swift files (`NameRecognizer`, `VoiceEnginePlugin`, `VoiceEngineDSP`, `SceneDelegate`) have no matches for the file-timestamp, boot-time, disk-space or active-keyboard APIs (searched 2026-11-17). Re-run that search before shipping.
- Plugins: the pub cache copies of these iOS plugins each ship a `PrivacyInfo.xcprivacy`: `app_links` 7.0.0, `device_info_plus` 13.3.0, `flutter_secure_storage_darwin` 0.4.3, `local_auth_darwin` 2.0.5, `package_info_plus` 10.2.2, `passkeys_darwin` 0.4.8, `share_plus` 13.3.1, `shared_preferences_foundation` 2.5.6, `url_launcher_ios` 6.4.1. `sign_in_with_apple` 8.1.0 ships none, and I found no required-reason API calls in its iOS source (searched, not proof). `path_provider_foundation` was not in the local pub cache, so it was **not checked** here **(unverified)**. Flutter's own engine ships a manifest in current releases **(unverified: Apple's SDK page names Flutter among SDKs that need one; <https://developer.apple.com/support/third-party-SDK-requirements/>)**.

**What to add (the agent did not create the file, because a new file in the Xcode project must be added to the Runner target, which is project-file surgery you should see):** `ios/Runner/PrivacyInfo.xcprivacy`, added to the Runner target's "Copy Bundle Resources", with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>NSPrivacyTracking</key>
  <false/>
  <key>NSPrivacyTrackingDomains</key>
  <array/>
  <key>NSPrivacyCollectedDataTypes</key>
  <array/>
  <key>NSPrivacyAccessedAPITypes</key>
  <array>
    <dict>
      <key>NSPrivacyAccessedAPIType</key>
      <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
      <key>NSPrivacyAccessedAPITypeReasons</key>
      <array><string>CA92.1</string></array>
    </dict>
  </array>
</dict>
</plist>
```

`NSPrivacyCollectedDataTypes` can stay empty or list the section 2 types; the App Store Connect answers are what the store shows. If you would rather keep them in step, add the section 2 types here too, linked, not tracking, App Functionality.

**How to confirm before submitting:** archive the app in Xcode, then Product → Archive → "Generate Privacy Report" (a PDF that merges the manifests). Upload to TestFlight: Apple emails if a declaration is missing (ITMS-91053 is the missing-reason code **(unverified)**).

## 5. Checks left for you

- [ ] Resolve each **(unverified)** row in section 2 against the release build.
- [ ] Add and verify `ios/Runner/PrivacyInfo.xcprivacy` (section 4); run the privacy report.
- [ ] Privacy policy URL: `/privacy` (LM-119). It must be live when you submit; see `app-review-notes.md`.
- [ ] Re-read these answers once the deletion worker merges (the retained deletion record, the purge list) and again after the LM-121 device pass: a new data type or a stored name changes section 2.
