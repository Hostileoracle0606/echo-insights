# App Review notes and demo account plan (LM-126)

A draft for you to read, correct against the build, and paste into App Store Connect (App Information, App Review Information). Nothing here was entered anywhere by an agent. **No password appears in this file and none should: you create the demo account and type its password yourself.**

Fill in or confirm every `<…>` before submitting. Lines marked **(confirm on device)** describe screens built by other tickets (LM-116, LM-127) that this draft was written before; check the wording against the release build.

## 1. Demo account plan

Review needs a way in. Lumen's sign-in is email and password, Sign in with Apple, and (release 1) passkeys. Give review the email path, because they can use it without an Apple ID of their own.

**You do, once, against the same backend the submitted build uses (production, after LM-125):**

1. In the release build, sign up with a new email address you control, for example `<review-account-email>`. Choose a password in the app yourself. Do not reuse any password you use elsewhere, and do not paste it into chat, a commit or this file.
2. Complete the first-run screen ("Who hears you") so review does not land on it cold, or leave it if you want them to see it.
3. Add some content so the maps and cards are not empty: have two short conversations (a few sentences each) mentioning two or three invented people and places. Use invented names only. Let each session close so a card is written.
4. Make sure the account is **not** one you want to keep: review may use "Delete my account" on it. Keep a script of the steps above so you can recreate it.
5. In App Store Connect, App Review Information: tick "Sign-in required", enter the email and the password you chose. This is where the password lives.
6. Confirm the account can sign in on a clean device or simulator **after** step 5, with Face ID app lock off (review cannot pass it).
7. After each review round, check the account still works, since deletion or a data cleanup would break it.

**Do not** give review a Sign in with Apple or passkey account; they cannot use yours. Say in the notes that those methods exist.

## 2. Text for the "Notes" field

> **What Lumen is.** Lumen is a voice journal. You talk, Lumen talks back, and afterwards it keeps a short card of each conversation and a private map of the people and places you mentioned, which it can bring up in later conversations.
>
> **How to try it.** Sign in with the demo account in the sign-in details. Tap to start a conversation and say a few sentences (for example, about a coworker named "Sam" and a trip to a place you invent). Lumen answers aloud. End the conversation to see the closing card. Open the map and a person to see what Lumen remembered.
>
> **Microphone.** Lumen needs the microphone: the conversation is live voice. The permission prompt appears the first time you start one. If you decline, the app cannot hold a conversation; nothing else is affected.
>
> **Network and AI services.** Voice and text are processed by Google's Gemini service, via infrastructure on Amazon Web Services; journals are stored in Supabase. The privacy policy and the in-app "Who hears you" screen (Privacy) list this in plain words. The app needs an internet connection.
>
> **Sign in.** Email and password, Sign in with Apple, and passkeys (from Settings after signing in, **(confirm on device)**). Sign in with Apple is offered with Apple's own button.
>
> **Account deletion.** In the app: Privacy, then "Delete my account" at the bottom **(confirm on device: LM-116)**. It asks you to confirm and, for an Apple account, to sign in with Apple once more so the Apple token can be revoked. The account and everything in it is deleted.
>
> **Other controls.** Privacy also has "Export my journal", app lock (Face ID or passcode), "Off the record" mode, automatic deletion of old transcripts, and "Forget" for a person. Forget is labelled beta in the app.
>
> **Camera.** The camera permission string exists for a framework dependency and the app does not use the camera. **(confirm: `NSCameraUsageDescription` is "Not used." in `Info.plist`; if no code path can request it, consider removing the key before submission so review does not ask.)**
>
> **Contact.** `<your name>`, `<phone>`, `<email>`.

## 3. Likely review questions, with the answer to give

| They may ask | Answer |
| --- | --- |
| Where is account deletion? | Privacy, "Delete my account" (Guideline 5.1.1(v)). **(confirm on device)** |
| Does Sign in with Apple revoke on delete? | Yes, the deletion flow revokes the Apple token (LM-115). **(confirm after LM-120 on staging)** |
| Why microphone? | Live voice conversation. |
| Do you use data for tracking? | No tracking. See `app-store-privacy.md` for the App Privacy answers. |
| Is AI-generated content moderated / is it a medical app? | Lumen is a journaling companion, not medical or therapy advice. **(your call: if you want a line saying this inside the app or notes, add it here)** |
| Privacy policy URL? | `<your web domain>/privacy` (LM-119). It must be **live before you submit**; the checklist deploys the web app after the iOS build is released, so deploy the `/privacy` page first or give review a URL that already works. |

## 4. Before you press Submit

- [ ] Privacy policy URL reachable from a phone (see the last row above).
- [ ] App Privacy answers entered from `app-store-privacy.md`.
- [ ] Demo account signs in on a clean device (section 1, step 6).
- [ ] Build is the production build (LM-125 done), version bumped from `1.0.0+1` (LM-126).
- [ ] Notes above match what you see on the device; every **(confirm on device)** resolved.
- [ ] Screenshots from the release build.
