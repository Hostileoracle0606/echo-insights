### LM-102: Idempotency keys for every text step
**Owner:** Claude · **Effort (estimate):** 1 week

**Why**
A retry after a crash, a timeout or a background task must never duplicate a card, an entity or a vector.

**Scope**
- **Existing:** `commit_notebook` already has a ledger, `notebook_commit_requests` with key `(notebook_id, request_id)` and a payload hash.
- Extend the same pattern to:
  - the card and the brief, keyed by notebook and revision;
  - extraction, keyed by turn id;
  - vector builds, keyed by entity id and content hash;
  - erase batches, keyed by job and batch.
- **Reads:** a repeat read must be safe too. "Is there a card for revision N?" must have a definite answer.

**Acceptance criteria:** for each step, a test runs it twice with the same key and checks for one result and no duplicates. A third run with a changed payload under the same key is refused.

**Dependencies:** LM-92.

**Out of scope:** retry timing (LM-103).

### LM-103: Launch-time catch-up
**Owner:** Claude · **Effort (estimate):** 1 week

**Why**
Today unsaved turns replay only when that notebook is opened, and the card retries only inside the close call. Under encryption, nothing else can finish the work. The app has to, every time it starts.

**Scope**
- On launch and on resume, after unlock:
  - find every notebook with unfinished work (turns not committed, no card for the latest revision, entities without vectors, erase jobs pending);
  - finish it in order, using LM-102's keys.
- Bounded and non-blocking: a session can start while catch-up runs. The open notebook goes first.
- A small "finishing up" state in the UI if a card is still pending, with no alarming copy.

**Acceptance tests (one per failure case)**
1. **Crash or OS kill mid-session:** kill the app after a turn is journalled but before commit. On relaunch, without opening the notebook, the turn is committed and the card follows.
2. **Offline at session end:** end a session with the network off. When the network returns (relaunch or resume), the card and brief are produced exactly once.
3. **Force quit:** force-quit right after ending a session. On the next launch, everything finishes. This is a simulator approximation; LM-104 checks it on a device.
4. **Search vectors lagging:** add an entity, then search before its vector exists. The result says nothing wrong, and the vector is built on the next catch-up.
5. **Second iPhone:** a session ended on phone A while phone A is then lost. Phone B, after phrase entry (LM-89), finishes A's unfinished server-side steps that need only ciphertext. Turns that were only in A's local journal are lost; the copy says so.

**Acceptance criteria:** all five tests pass on a simulator. Case 5 needs two simulators.

**Dependencies:** LM-102, LM-90.

**Out of scope:** iOS background execution (LM-104).
