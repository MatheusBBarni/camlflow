# Alpha (MVP) Remaining Tasks

This document turns the two remaining unchecked Alpha items in `README.md` into a concrete, spec-driven checklist.

Canonical reference:
- `docs/mvp-spec-camlflow.md`

## Goal

Ship a spec-conformant Alpha without expanding language scope.

Constraints:
- freeze syntax and features
- fix only MVP-spec conformance gaps
- prefer check-time failures over runtime failures where the spec requires them
- add minimal spec-covering examples, not broad showcase examples

---

## Task 1 — Improve MVP stability, diagnostics, and language ergonomics

### P0 semantic blockers
- [x] Fix check-time exhaustiveness enforcement for `match`
- [ ] Audit remaining spec-required check-time failures and close any gaps:
  - [x] wrong argument labels
  - [x] `let*` misuse
  - [x] effectful top-level bindings
  - [x] unsaturated agent calls
  - [x] unsaturated skill calls
  - [x] unreachable match cases
  - [x] unsupported library/module calls
- [x] Ensure no known case that should fail at check-time still slips to runtime

### P1 targeted diagnostics
- [x] Improve invalid provider output shape errors with invocation kind/name and declared return type
- [x] Improve diagnostics for unsupported library/module calls
- [x] Confirm non-exhaustive and unreachable match diagnostics remain clear and source-located
- [x] Confirm effect misuse diagnostics remain clear (`let*`, top-level effects)

### Done criteria for Task 1
- [x] `dune test` passes with the new conformance tests
- [x] Non-exhaustive matches fail during checking, not runtime
- [x] Provider output shape mismatches report invocation context clearly
- [x] No newly added spec test exposes an unresolved Alpha conformance bug

---

## Task 2 — Expand examples and test coverage for more workflow patterns

### Required tests
- [x] zero-arg `main`
- [x] single-arg `main`
- [x] unresolved `open`
- [x] wrong argument labels
- [x] unsupported library/module calls
- [x] non-exhaustive match
- [x] unreachable match case
- [x] effectful top-level bindings
- [x] unsaturated agent call
- [x] unsaturated skill call
- [x] invalid provider output shape
- [x] invalid runtime input shape
- [x] local skill resolution
- [x] `Agent.define` / provider hook execution
- [x] qualified imports
- [x] recursion and builtin operators
- [x] compiled IR roundtrip

### Minimal example additions
- [x] Add one runnable example covering variants + pattern matching
- [x] Prefer combining records + variants + `match` in that example if it keeps the example small
- [x] Add a Make target only if it materially improves discoverability

### Docs follow-up
- [x] Update `README.md` example list once the new example exists
- [x] Mark the two Alpha checklist items complete only after tests/examples are in place

### Done criteria for Task 2
- [x] Every spec-required negative behavior has an automated test
- [x] At least one runnable example covers variants + `match`
- [x] README Alpha status can be updated honestly

---

## Recommended execution order

1. Add failing tests for check-time conformance gaps
2. Fix semantics and targeted diagnostics
3. Add the remaining required negative tests
4. Add the minimal variants + match example
5. Update `README.md` and close Alpha
