# Flutter authentication routing

## Context

The login screen previously called `context.go('/journal')` after authentication. The Flutter router does not define a `/journal` route; its authenticated entry point is `/dashboard`, with individual journals available at `/notebook/:id`.

Having the login screen choose the destination also split navigation policy between the screen and `GoRouter`. Those two implementations could drift, which is how the invalid route was introduced.

## Decision

`GoRouter` is the single owner of authentication-based navigation. Login and signup screens perform authentication but do not choose the post-authentication route.

The policy is expressed by the pure `authRedirect` function in `lib/app.dart`:

- A signed-out user requesting an application route is redirected to `/auth/login`.
- A signed-in user requesting an authentication route is redirected to `/dashboard`.
- A user already in the correct route family is not redirected.

The router passes only the current authentication state and matched location into this function.

## Why this reduces coupling

Authentication screens no longer need to know the application's authenticated landing route. The router no longer hides its policy inside a framework callback. UI code owns authentication actions, while routing code owns navigation policy.

Because `authRedirect` depends only on `isLoggedIn` and `location`, its behavior can be tested without constructing widgets, an authentication backend, or a complete `GoRouter`. This makes route changes localized and reduces the chance of screens and router configuration disagreeing.
