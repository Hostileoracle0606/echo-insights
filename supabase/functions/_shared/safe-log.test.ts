import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { errorClass, safeLog, sanitizeLogFields } from "./safe-log.ts";

const MARKER = "ZZ-SECRET-MARKER";

Deno.test("keeps ids, counts and codes and drops prose", () => {
  assertEquals(
    sanitizeLogFields({
      event: "x",
      status: 500,
      ok: false,
      stage: "notebook",
      transcript: MARKER,
      error: `${MARKER} has spaces`,
      detail: { text: MARKER },
    }),
    { event: "x", status: 500, ok: false, stage: "notebook", droppedFields: 3 },
  );
});

Deno.test("errorClass reports the class, never the message", () => {
  assertEquals(errorClass(new SyntaxError(`bad ${MARKER}`)), "SyntaxError");
  assertEquals(errorClass(`${MARKER}`), "unknown");
});

Deno.test("safeLog output never contains a field it dropped", () => {
  const lines: string[] = [];
  safeLog("f", { title: MARKER, count: 2 }, (l) => lines.push(l));
  assert(!lines.join("").includes(MARKER));
  assertEquals(JSON.parse(lines[0]), { fn: "f", count: 2, droppedFields: 1 });
});
