# Account deletion (LM-114..117): results

## Apple REST API, confirmed

Confirmed 2026-11-17 by reading Apple's live pages in the in-app browser (the pages are client-rendered, so plain fetch returns only titles):
- https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens ("Token validation")
- https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens ("Token revocation")
- https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret (the "Creating a client secret" article; the Sign in with Apple page links to this same article, and the fields are identical)

Confirmed facts:
- Token endpoint `POST https://appleid.apple.com/auth/token`, `application/x-www-form-urlencoded`. Params: `client_id`, `client_secret`, `code`, `grant_type=authorization_code`. The code is single-use and valid five minutes. Response has `access_token`, `refresh_token`, `id_token`, `expires_in`, `token_type`.
- `redirect_uri`: Apple's note says to include it only if the app supplied one in the initial authorization request. A native `getAppleIDCredential` call supplies none, so the function omits it.
- Revoke endpoint `POST https://appleid.apple.com/auth/revoke`, form-urlencoded. Params: `client_id`, `client_secret`, `token` (refresh or access token), optional `token_type_hint` (`refresh_token` or `access_token`). 200 with no body on success, and also if the token was already invalid; 400 with an ErrorResponse otherwise.
- `client_id` is "App ID or Services ID", must match the identifier used in the authorization request, and must not include the Team ID. For the native flow that is the bundle id.
- Client secret: JWT, `alg=ES256` (ECDSA P-256 + SHA-256), header `kid` = 10-character Key ID; claims `iss` = 10-character Team ID, `iat`, `exp` (at most 15777000 s, six months, ahead), `aud=https://appleid.apple.com`, `sub` = the same value as `client_id` (case-sensitive).
- To revoke you need a refresh or access token; Apple says to obtain tokens by validating an authorization code. So the design holds: exchange the fresh code, then revoke. Revoking the refresh token "invalidates the token and associated user authorizations".
- Differences from the ticket's assumptions: none in parameters. The code lives only five minutes, so the app must re-run Sign in with Apple at delete time and send that code at once.

Still not confirmable from docs (needs a device, LM-121): that Lumen disappears from Settings, Apple ID, Sign in with Apple after revoking the refresh token alone, and that a native code exchanges with the bundle id as `client_id` (one forum thread claimed a Services ID was needed; Apple's text says "App ID or Services ID" matching the authorization request).

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
