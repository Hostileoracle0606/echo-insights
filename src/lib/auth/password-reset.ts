/**
 * Password reset, web side. The recovery email links to
 * `/auth/reset?token_hash=…&type=recovery` (Supabase "Reset Password" email
 * template). A token_hash link works in any browser, unlike a PKCE `?code=`
 * link, which only the device that requested it can redeem. The iOS app
 * requests the email, so the reset has to complete here.
 */

/** Matches the web signup form's minimum. */
export const MIN_PASSWORD_LENGTH = 8;

export type RecoveryLink =
  | { kind: "token"; tokenHash: string }
  | { kind: "error"; code: string }
  | { kind: "missing" };

/** Reads the link Supabase's recovery email opened. */
export function parseRecoveryLink(search: string, hash = ""): RecoveryLink {
  const query = new URLSearchParams(search);
  const tokenHash = query.get("token_hash");
  if (tokenHash && (query.get("type") ?? "recovery") === "recovery") {
    return { kind: "token", tokenHash };
  }
  // Supabase reports failed verifications (e.g. otp_expired) in the query or
  // the fragment, depending on the flow.
  const fragment = new URLSearchParams(hash.replace(/^#/, ""));
  const code =
    query.get("error_code") ??
    fragment.get("error_code") ??
    query.get("error") ??
    fragment.get("error");
  if (code) return { kind: "error", code };
  return { kind: "missing" };
}

/** The first problem with a new password pair, or null when it is usable. */
export function passwordProblem(password: string, confirm: string): string | null {
  if (password.length < MIN_PASSWORD_LENGTH) {
    return `Use at least ${MIN_PASSWORD_LENGTH} characters.`;
  }
  if (password !== confirm) return "Passwords don't match.";
  return null;
}

/** User-facing text for a failed updateUser call. */
export function updateErrorMessage(error: { code?: string; message?: string } | null): string {
  switch (error?.code) {
    case "weak_password":
      return error.message || "Choose a stronger password.";
    case "same_password":
      return "Choose a password you haven't used for this account.";
    case "session_not_found":
    case "session_expired":
      return "This reset link has expired. Request a new one below.";
    default:
      return "Couldn't update your password. Check your connection and try again.";
  }
}
