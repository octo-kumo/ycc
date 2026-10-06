# List of all bugs of YCC
Only include bugs of the compiler, make sure to include minimal reproduction.

This ledger is for the **examples** campaign: findings made while
writing programs under `examples/`. It is separate from the
compiler's own ledger at the repo root. The protocol — when a
finding is a bug versus a suggestion, the entry template, the
dedup rule — is in `examples/ORCHESTRATOR.md` §8.

A bug is something Y gets **wrong**. A missing feature is not a
bug; it goes in `SUGGESTIONS.md`. The absence of `sqrt` or of a
termios helper is a suggestion, never a bug. When you are unsure,
it is a suggestion.

Before appending: grep this file for the diagnostic text, re-read
any matching entry in case it is already fixed, and never renumber
what is here.

***INSTRUCTIONS WHEN FINISH*** remove the BUG item from this file when it has been completed
