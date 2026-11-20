import type { MemoryRoute } from "./memory-query-types.ts";

const ENDPOINT = "https://generativelanguage.googleapis.com/v1beta/decisions";
const OPERATIONS = [
  "recall",
  "confirm_event",
  "calculate",
  "conversation",
] as const;
const SCOPES = [
  "current",
  "previous",
  "as_of",
  "compare_versions",
  "unspecified",
] as const;

type Reason =
  | "credential"
  | "timeout"
  | "provider"
  | "invalid"
  | "low_confidence"
  | "conflict";
type Observation = {
  elapsedMs: number;
  route?: MemoryRoute;
  confidenceRange?: "low" | "high";
  fallbackReason?: Reason;
};
type Options = {
  getApiKey: () => string | undefined | null;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  // Provisional threshold: calibrate on labeled traffic before enabling broadly.
  minConfidence?: number;
  observe?: (observation: Observation) => void;
};

function choice<T extends string>(
  value: unknown,
  allowed: readonly T[],
  threshold: number,
): { value?: T; reason?: Reason; confidence?: number } {
  if (!value || typeof value !== "object") return { reason: "invalid" };
  const answer = value as Record<string, unknown>;
  if (
    answer.type !== "choice" || typeof answer.choice !== "string" ||
    !allowed.includes(answer.choice as T) ||
    typeof answer.confidence !== "number" ||
    !Number.isFinite(answer.confidence) || answer.confidence < 0 ||
    answer.confidence > 1 ||
    !answer.probabilities || typeof answer.probabilities !== "object" ||
    Array.isArray(answer.probabilities)
  ) return { reason: "invalid" };
  const probabilities = answer.probabilities as Record<string, unknown>;
  if (
    Object.keys(probabilities).length !== allowed.length ||
    allowed.some((key) =>
      typeof probabilities[key] !== "number" ||
      !Number.isFinite(probabilities[key]) ||
      (probabilities[key] as number) < 0 || (probabilities[key] as number) > 1
    )
  ) return { reason: "invalid" };
  const numbers = allowed.map((key) => probabilities[key] as number);
  const selected = probabilities[answer.choice] as number;
  if (
    Math.abs(numbers.reduce((a, b) => a + b, 0) - 1) > 0.02 ||
    Math.abs(selected - answer.confidence) > 0.02 ||
    numbers.some((p) => p > selected) ||
    numbers.filter((p) => p === selected).length !== 1
  ) return { reason: "conflict" };
  if (answer.confidence < threshold) {
    return { reason: "low_confidence", confidence: answer.confidence };
  }
  return { value: answer.choice as T, confidence: answer.confidence };
}

/** Returns null when the caller must use its safe fallback. No provider text is logged. */
export function createDecisionsRouter(options: Options) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 1200;
  const threshold = options.minConfidence ?? 0.7;
  return async (
    question: string,
    signal: AbortSignal,
  ): Promise<MemoryRoute | null> => {
    const start = Date.now();
    const report = (observation: Omit<Observation, "elapsedMs">) => {
      try {
        options.observe?.({ elapsedMs: Date.now() - start, ...observation });
      } catch { /* telemetry must not affect routing */ }
    };
    let key: string | undefined | null;
    try {
      key = options.getApiKey();
    } catch {
      report({ fallbackReason: "credential" });
      return null;
    }
    if (!key?.trim()) {
      report({ fallbackReason: "credential" });
      return null;
    }
    if (signal.aborted || timeoutMs <= 0) {
      report({ fallbackReason: "timeout" });
      return null;
    }
    const controller = new AbortController();
    let timer: ReturnType<typeof setTimeout> | undefined;
    let onAbort: (() => void) | undefined;
    const stopped = new Promise<null>((resolve) => {
      const stop = () => {
        controller.abort();
        resolve(null);
      };
      onAbort = stop;
      signal.addEventListener("abort", stop, { once: true });
      timer = setTimeout(stop, timeoutMs);
    });
    try {
      const request = (async () => {
        const response = await fetchImpl(ENDPOINT, {
          method: "POST",
          signal: controller.signal,
          headers: {
            "Content-Type": "application/json",
            "x-goog-api-key": key!,
          },
          body: JSON.stringify({
            model: "gemini-decision-1",
            input: question,
            questions: {
              operation: {
                type: "choice",
                instructions: "Select what Lumen needs to do for this turn.",
                criteria: {
                  recall:
                    "Retrieve an explicitly recorded personal fact or event. No arithmetic requested.",
                  confirm_event:
                    "Distinguish whether an intended or proposed change was actually carried out.",
                  calculate:
                    "Compute a numeric total, change, or comparison using personal records.",
                  conversation:
                    "Respond conversationally. No explicit request for personal memory.",
                },
              },
              time_scope: {
                type: "choice",
                instructions:
                  "For recall, which version of a remembered fact does the user ask for? The user may ask for a fact with no version preference. Ignore dates or events that merely identify a memory.",
                criteria: {
                  previous:
                    "Explicitly asks for an earlier or previous value as opposed to the current value.",
                  current: "Explicitly asks for the latest or current value.",
                  compare_versions:
                    "Requests a difference or comparison between an earlier and a later value.",
                  as_of:
                    "Asks what the state or value was as of a specified date or period.",
                  unspecified:
                    "No requested version, or the request is about whether a proposed event was carried out. Choose this for ordinary conversation.",
                },
              },
            },
          }),
        });
        if (!response.ok) return { reason: "provider" as Reason };
        const body = await response.json();
        const operation = choice(
          body?.answers?.operation,
          OPERATIONS,
          threshold,
        );
        const scope = choice(body?.answers?.time_scope, SCOPES, threshold);
        if (!operation.value || !scope.value) {
          return {
            reason: operation.reason ?? scope.reason ?? "invalid" as Reason,
          };
        }
        // A conversational turn with a specific memory time scope is internally inconsistent.
        if (
          operation.value === "conversation" && scope.value !== "unspecified"
        ) return { reason: "conflict" as Reason };
        return {
          route: {
            operation: operation.value,
            timeScope: scope.value,
          } satisfies MemoryRoute,
        };
      })();
      const result = await Promise.race([request, stopped]);
      if (!result || signal.aborted || controller.signal.aborted) {
        report({ fallbackReason: "timeout" });
        return null;
      }
      if (!result.route) {
        report({
          fallbackReason: result.reason,
          confidenceRange: result.reason === "low_confidence"
            ? "low"
            : undefined,
        });
        return null;
      }
      report({ route: result.route, confidenceRange: "high" });
      return result.route;
    } catch {
      report({
        fallbackReason: controller.signal.aborted ? "timeout" : "provider",
      });
      return null;
    } finally {
      if (timer !== undefined) clearTimeout(timer);
      if (onAbort) signal.removeEventListener("abort", onAbort);
    }
  };
}
