import { describe, expect, it } from "vitest";
import {
  MIN_PASSWORD_LENGTH,
  parseRecoveryLink,
  passwordProblem,
  updateErrorMessage,
} from "./password-reset";

describe("parseRecoveryLink", () => {
  it("reads the token_hash from a recovery link", () => {
    expect(parseRecoveryLink("?token_hash=abc123&type=recovery")).toEqual({
      kind: "token",
      tokenHash: "abc123",
    });
  });

  it("ignores token hashes minted for another flow", () => {
    expect(parseRecoveryLink("?token_hash=abc&type=signup")).toEqual({ kind: "missing" });
  });

  it("surfaces Supabase's error code from the query or the fragment", () => {
    expect(parseRecoveryLink("?error_code=otp_expired")).toEqual({
      kind: "error",
      code: "otp_expired",
    });
    expect(parseRecoveryLink("", "#error=access_denied&error_code=otp_expired")).toEqual({
      kind: "error",
      code: "otp_expired",
    });
  });

  it("treats a bare visit as missing", () => {
    expect(parseRecoveryLink("")).toEqual({ kind: "missing" });
  });
});

describe("passwordProblem", () => {
  it("requires the minimum length", () => {
    expect(passwordProblem("short", "short")).toBe(
      `Use at least ${MIN_PASSWORD_LENGTH} characters.`,
    );
  });

  it("requires both fields to match", () => {
    expect(passwordProblem("long-enough-1", "long-enough-2")).toBe("Passwords don't match.");
  });

  it("accepts a matching pair of the minimum length", () => {
    expect(passwordProblem("12345678", "12345678")).toBeNull();
  });
});

describe("updateErrorMessage", () => {
  it("keeps Supabase's weak-password guidance", () => {
    expect(
      updateErrorMessage({ code: "weak_password", message: "Password should contain a digit." }),
    ).toBe("Password should contain a digit.");
  });

  it("maps an expired recovery session to the resend path", () => {
    expect(updateErrorMessage({ code: "session_not_found" })).toMatch(/expired/);
  });

  it("never shows unknown internals", () => {
    expect(updateErrorMessage({ code: "unexpected_failure", message: "pg: deadlock" })).toBe(
      "Couldn't update your password. Check your connection and try again.",
    );
  });
});
