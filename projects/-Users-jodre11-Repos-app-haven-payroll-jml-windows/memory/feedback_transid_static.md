---
name: TransId static field is intentional
description: ImportGeneratorFactory._transId is deliberately static to persist the transaction ID counter across processor calls within a session
type: feedback
originSessionId: cd1a8ac4-c598-444f-b31a-56e8aea8151a
---
`ImportGeneratorFactory._transId` is `private static int` **by design** — it must persist across
processor calls within the same process so transaction IDs continuously increment without re-reading
the file between each processor invocation.

**Why:** The factory processes multiple files sequentially in a session. Each processor returns the
next available transaction ID, and the static field carries it forward to the next processor. The
file (`ImportReference.txt`) is the persistence mechanism for cross-session continuity.

**How to apply:** Don't flag `static` as accidental or suggest changing to instance. The real bugs
around transaction IDs are: (1) `UpdateNextTransactionId` writes `_transId + 1` causing a
double-increment (one ID skipped per file), and (2) `CallProcessorService` redundantly calls
`LoadReferenceData()` which re-reads the file and can overwrite the in-memory counter.
