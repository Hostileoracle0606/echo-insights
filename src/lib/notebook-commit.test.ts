import { describe, expect, it, vi } from "vitest";

const rpcMock = vi.fn();
vi.mock("@/lib/supabase/browser", () => ({
  supabase: { rpc: (...args: unknown[]) => rpcMock(...args) },
}));

// Imported after the mock is registered so the module under test picks up
// the stubbed client instead of the real one (which throws on import if
// VITE_SUPABASE_URL/KEY aren't set — never true in this unit-test process).
const { commitNotebook, getNotebookSnapshot, newRequestId } = await import("./notebook-commit");

describe("newRequestId", () => {
  it("returns distinct ids across calls", () => {
    const a = newRequestId();
    const b = newRequestId();
    expect(a).not.toEqual(b);
    expect(a).toMatch(/^[0-9a-f-]{36}$/);
  });
});

describe("commitNotebook", () => {
  it("calls commit_notebook with the exact snake_case RPC params and returns the outcome as-is", async () => {
    const outcome = { status: "committed", requestId: "r1", revision: 3, ids: { entryId: "e1" } };
    rpcMock.mockResolvedValueOnce({ data: outcome, error: null });

    const result = await commitNotebook({
      notebookId: "nb-1",
      expectedRevision: 2,
      requestId: "r1",
      change: { kind: "clearNotebook" },
    });

    expect(rpcMock).toHaveBeenCalledWith("commit_notebook", {
      p_notebook_id: "nb-1",
      p_expected_revision: 2,
      p_request_id: "r1",
      p_change: { kind: "clearNotebook" },
    });
    expect(result).toEqual(outcome);
  });

  it("throws when the RPC call itself errors (transport/auth failure, not a domain rejection)", async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: { message: "network down" } });

    await expect(
      commitNotebook({
        notebookId: "nb-1",
        expectedRevision: 0,
        requestId: "r1",
        change: { kind: "clearNotebook" },
      }),
    ).rejects.toThrow(/network down/);
  });
});

describe("getNotebookSnapshot", () => {
  it("calls get_notebook_snapshot and reshapes a raw snapshot into JournalState", async () => {
    rpcMock.mockResolvedValueOnce({
      data: {
        notebookId: "nb-1",
        revision: 5,
        state: {
          entries: [{ id: "e1", text: "hi", createdAt: "2026-01-01", entityIds: [], relationIds: [] }],
          entities: { maya: { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 1, firstSeen: "x", lastSeen: "x" } },
          relations: {},
          followUps: [],
          askedQuestions: [],
        },
      },
      error: null,
    });

    const snapshot = await getNotebookSnapshot("nb-1");

    expect(rpcMock).toHaveBeenCalledWith("get_notebook_snapshot", { p_notebook_id: "nb-1" });
    expect(snapshot).toEqual({
      notebookId: "nb-1",
      revision: 5,
      state: {
        entries: [{ id: "e1", text: "hi", createdAt: "2026-01-01", entityIds: [], relationIds: [] }],
        entities: { maya: { id: "maya", name: "Maya", type: "person", metadata: {}, mentions: 1, firstSeen: "x", lastSeen: "x" } },
        relations: {},
        followUps: [],
        askedQuestions: [],
      },
    });
  });

  it("returns null for a notebook that doesn't exist or isn't owned by the caller", async () => {
    rpcMock.mockResolvedValueOnce({ data: null, error: null });
    const snapshot = await getNotebookSnapshot("someone-elses-notebook");
    expect(snapshot).toBeNull();
  });

  it("defensively coalesces null aggregate fields to empty collections", async () => {
    rpcMock.mockResolvedValueOnce({
      data: { notebookId: "nb-1", revision: 0, state: { entries: null, entities: null, relations: null, followUps: null, askedQuestions: null } },
      error: null,
    });
    const snapshot = await getNotebookSnapshot("nb-1");
    expect(snapshot?.state).toEqual({ entries: [], entities: {}, relations: {}, followUps: [], askedQuestions: [] });
  });
});
