# Account deletion (LM-114..117): results

## Apple REST API, confirmed

Honesty note: Apple's developer.apple.com doc pages are client-rendered. WebFetch
returned only the page titles for all three pages below, so its summaries were
the fetch model's general knowledge, NOT confirmed page text. A web search
surfaced only Apple Developer Forums threads and third-party guides (no
official page text). Everything below is therefore "documented per tooling
recall plus community reports", not verified against Apple's live text. Re-check
the three pages in a browser before LM-120/121.

URLs attempted:
- https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens (title only)
- https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens (title only)
- https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret (title only)
- Community: https://developer.apple.com/forums/thread/708839 , /thread/706792 , /thread/759934 (search snippets only)

Facts used by the implementation (unverified against live docs, consistent across sources):
- Token endpoint: POST https://appleid.apple.com/auth/token, `application/x-www-form-urlencoded`, params `client_id`, `client_secret`, `code`, `grant_type=authorization_code`. Response JSON includes `refresh_token`, `access_token`, `id_token`. `redirect_uri` is listed for web flows; native-code exchange is expected to work without it (UNCONFIRMED; verify on device).
- Revoke endpoint: POST https://appleid.apple.com/auth/revoke, form-urlencoded, params `client_id`, `client_secret`, `token`, `token_type_hint` (`refresh_token`). 200 with empty body on success.
- Client secret: JWT, header `alg=ES256`, `kid=<Key ID>`; claims `iss=<Team ID>`, `iat`, `exp` (max 6 months after iat, 15777000 s), `aud=https://appleid.apple.com`, `sub=<client_id>`.
- client_id for a native iOS authorization code: the app bundle id (community reports; one forum reply claims a Services ID was needed instead, so confirm on device). The `sub` claim must equal the `client_id` sent.
- Revoking the refresh token is the standard way to end the grant (also invalidates access tokens issued from it).
- Differences from the plan's assumptions: the authorization code is single-use and valid only about 5 minutes, so the app (Task 4) must obtain a FRESH code by re-authenticating with Apple at delete time and send it immediately. A code captured at original sign-in cannot be used.

## Secrets the user must create (LM-120)

Names: `APPLE_TEAM_ID` (Membership details in developer.apple.com), `APPLE_KEY_ID`
(Keys > a key with "Sign in with Apple" enabled), `APPLE_PRIVATE_KEY` (the .p8
PEM downloaded once), `APPLE_CLIENT_ID` (the app bundle id). Put them in an
untracked env file and run `supabase secrets set --env-file <file>`; never pass
values inline or commit the file.

## Checks left for LM-120/121 (staging + real device)

- Confirm the three Apple pages (above) in a browser.
- Real device: Sign in with Apple, delete account, confirm `apple_revoked:true` and the app disappears from Settings > Apple ID > Sign in with Apple.
- Confirm bundle id works as client_id (vs Services ID) and no `redirect_uri` is required.
- Confirm a fresh code from re-auth reaches the function within 5 minutes.
- Confirm missing-secret behaviour on staging yields `apple_revoked:false` and still deletes.
