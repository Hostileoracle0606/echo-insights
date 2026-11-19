# Excluded: first retrieval run (edge runtime could not boot)

The first retrieval run (16:21–16:46 local) hit a leftover edge-runtime
container whose `retrieve-memory` failed to boot (`Unsupported lockfile
version '5'`): 149 of 150 calls returned 503. That measures a broken local
environment, not retrieval, so these files are kept as a record and left out
of `timing.json`. The runs in the parent folder were made after serving the
functions from this worktree.
