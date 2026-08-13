# Verification Issues

## Executive Summary
- **Commit**: `b61cababd92cc94b89f749dfc9a0dafa00ddbd3d` (`PL-381: Bound closed PR workflow discovery`)
- **Branch**: `main` (verification was explicitly requested against this commit)
- **Commits reviewed**: 1
- **Files changed**: 1 added, 3 modified, 0 deleted
- **Overall alignment**: Moderate — the bounded five-status implementation is substantially aligned and all 12 existing action tests pass, but several plan-mandated regression scenarios and the retained `--slurp` documentation are missing.

## Critical Discrepancies

No critical discrepancies found. The core bounded discovery, trusted PR association filtering, self-exclusion, deduplication, cancellation continuation, retry behavior, and race handling are implemented.

## Moderate Discrepancies

### 1. Multi-page and multi-status fixtures do not prove distinct matching runs are selected and cancelled
- **Category**: Insufficient regression coverage
- **Description**: The plan requires distinct matching run IDs across multiple pages and all five status queries. The `selection` fixture has matching run `200` repeated across two queued pages and matching run `201` only in `in_progress`; `requested`, `waiting`, and `pending` return empty defaults. The test therefore does not prove that distinct matching candidates from every status are selected and cancelled.
- **Evidence**: `cancel-pr-workflows/tests/fakes/gh:93-99`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:149-171`
- **Impact**: Medium — a regression that drops candidates from later statuses or pages could pass the suite.
- **Recommendation**: Add distinct associated IDs to at least two pages and each of the five status fixtures, include a cross-status duplicate, and assert exactly one cancellation attempt for every distinct selected ID.
- **Code Location**: `cancel-pr-workflows/tests/fakes/gh:93-136`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:149-171`

### 2. Fork-safety and `pull_request_target` association behavior are not explicitly tested
- **Category**: Missing security regression tests
- **Description**: The plan requires associated `pull_request_target` runs to be eligible, unrelated target-event runs to be excluded, and fork-shaped runs without a trusted pull-request association to remain untouched. Existing fixtures cover missing or empty associations and several other events, but contain no `pull_request_target` cases or explicit fork-shaped case.
- **Evidence**: `cancel-pr-workflows/tests/fakes/gh:93-136`; no `pull_request_target` fixture or assertion exists in `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`.
- **Impact**: Medium — future filtering changes could weaken the association safety boundary without failing tests.
- **Recommendation**: Add matching and unrelated `pull_request_target` runs plus an unassociated fork-shaped run, and assert only the matching association is cancelled.
- **Code Location**: `cancel-pr-workflows/tests/fakes/gh:93-136`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:149-171`

### 3. Required malformed-ID coverage is absent
- **Category**: Missing error-path test
- **Description**: The implementation validates positive integral IDs during response validation and selection, but the test suite covers malformed response structure and malformed `pull_requests` entries only. It does not provide a non-numeric, zero, negative, or fractional run ID fixture and does not assert that such a response fails closed before any cancellation.
- **Evidence**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:206-209`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:314-326`
- **Impact**: Medium — the fail-closed ID contract is untested.
- **Recommendation**: Add malformed-ID scenarios for a required status query and assert a fatal discovery error plus zero cancellation calls.
- **Code Location**: `cancel-pr-workflows/tests/fakes/gh:90-137`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:314-326`

### 4. Later-status fatal discovery and no-partial-cancellation behavior are not tested
- **Category**: Missing fail-closed regression test
- **Description**: The plan requires a terminal failure in any required status query to abort before cancellation, including after earlier statuses have produced candidates. The fake injects discovery failures only for `queued`, so the suite never exercises a failure in `in_progress`, `requested`, `waiting`, or `pending` after candidates have been accumulated.
- **Evidence**: `cancel-pr-workflows/tests/fakes/gh:147-167`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:295-312`
- **Impact**: Medium — an accidental future cancellation before discovery completion could partially cancel runs.
- **Recommendation**: Add a later-status failure scenario with an earlier matching candidate and assert all cancellation endpoints are absent.
- **Code Location**: `cancel-pr-workflows/tests/fakes/gh:147-167`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:295-312`

### 5. Per-status zero-page/zero-run logging and bounded-result guard are not asserted
- **Category**: Observability and performance test gap
- **Description**: The plan asks for stable per-status totals including zero-page/zero-run statuses and a bounded-result regression guard. The suite checks only the aggregate no-match summary; it does not assert individual status log lines, exercise a zero-page response, or directly verify that only filtered candidate IDs are retained rather than a complete historical fixture.
- **Evidence**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:232-260`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:210-225`
- **Impact**: Low to medium — logging or memory-regression changes could pass without detection.
- **Recommendation**: Assert all five per-status log lines, add an empty-page fixture where supported by the fake, and add a scenario that records/validates the retained candidate set without exposing full payloads.
- **Code Location**: `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:210-225`; `cancel-pr-workflows/tests/fakes/gh:134-136`

### 6. Retained `--slurp` memory trade-off is not documented
- **Category**: Divergence from architecture plan
- **Description**: The implementation correctly clears `API_OUTPUT` and `API_BODY` between status queries, but retains `--paginate --slurp` and adds no comment or documentation stating that one complete active-status response is held at a time or explaining the memory trade-off. The plan explicitly required this documentation when retaining slurp.
- **Evidence**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:199-205,255-257`
- **Impact**: Low to medium — a future reader could incorrectly assume incremental page processing and underestimate memory use for a large active status.
- **Recommendation**: Add a concise implementation comment documenting the per-status slurp behavior and its bounded-active-runs, non-full-history scope, or switch to reliable incremental page processing.
- **Code Location**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:199-205`

## Minor Discrepancies

### 1. Unused completed-run accumulator remains
- **Description**: `DISCOVERY_COMPLETED_TOTAL` is declared and initialized but never incremented or read. The per-status `completed_count` log is present, so this is dead scaffolding rather than a missing behavior.
- **Assessment**: Minor cleanup issue; remove the unused variable or use it for the aggregate completed-run total promised by the observability design.
- **Optional Action**: Remove `DISCOVERY_COMPLETED_TOTAL` or add an aggregate completed-run summary.
- **Code Location**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:14`

### 2. Malformed association errors now fail during response validation
- **Description**: The `malformed_filter` scenario now reports an invalid discovery response instead of the previous filtering-stage error because structural validation became stricter.
- **Assessment**: Acceptable defensive behavior and covered by the updated test; only the error-path categorization changed.
- **Optional Action**: Keep as-is, or rename the scenario to reflect response validation.
- **Code Location**: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh:206-209`; `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh:314-326`

## LLM Fix Instructions

### Instructions for Addressing Discrepancies

If you are an LLM tasked with fixing these discrepancies, follow this priority order:

**Priority 1 - Critical Issues** (Must Fix):

```
No critical fixes required.
```

**Priority 2 - Moderate Issues** (Should Fix):

```
1. Expand the fake discovery fixtures and selection test to include distinct associated matching IDs across multiple pages and all five active statuses, with a duplicate across statuses. Assert every distinct selected ID receives exactly one cancellation request.
   - Files: cancel-pr-workflows/tests/fakes/gh; cancel-pr-workflows/tests/test-cancel-pr-workflows.sh
   - Acceptance: the test proves page and status coverage, deduplication, deterministic selection, and cancellation of every distinct candidate.

2. Add explicit fork-safety and pull_request_target fixtures: an associated target-event run that is cancelled, an unrelated target-event run that is untouched, and an unassociated fork-shaped run that is untouched.
   - Files: cancel-pr-workflows/tests/fakes/gh; cancel-pr-workflows/tests/test-cancel-pr-workflows.sh
   - Acceptance: only the run whose pull_requests[].number matches trusted PR_NUMBER is cancelled.

3. Add malformed run-ID fixtures covering at least a non-numeric, zero, negative, or fractional ID and assert discovery fails closed before any cancellation.
   - Files: cancel-pr-workflows/tests/fakes/gh; cancel-pr-workflows/tests/test-cancel-pr-workflows.sh
   - Acceptance: fatal error is observable and the calls log contains no /cancel request.

4. Add a later-status discovery failure scenario after an earlier status has returned a matching candidate; assert the action aborts before all cancellation requests.
   - Files: cancel-pr-workflows/tests/fakes/gh; cancel-pr-workflows/tests/test-cancel-pr-workflows.sh
   - Acceptance: retries remain scoped to the failing status and no partial cancellation occurs.

5. Assert stable per-status zero-run/zero-page logging and add a bounded-result regression guard. Document the retained per-status --slurp memory trade-off, or replace it with reliable incremental page processing.
   - Files: cancel-pr-workflows/tests/test-cancel-pr-workflows.sh; cancel-pr-workflows/scripts/cancel-pr-workflows.sh
   - Acceptance: logs cover all five statuses, the test guards against full-history retention, and the implementation explicitly documents its memory behavior.
```

**Priority 3 - Minor Issues** (Optional):

```
1. Remove the unused DISCOVERY_COMPLETED_TOTAL variable or use it in an aggregate completed-run summary.
   - File: cancel-pr-workflows/scripts/cancel-pr-workflows.sh
   - Acceptance: no dead discovery counter remains.

2. Rename malformed_filter to reflect that malformed pull_requests data is now rejected during response validation.
   - File: cancel-pr-workflows/tests/test-cancel-pr-workflows.sh
   - Acceptance: test names describe the current failure path.
```

### Implementation Checklist

- [ ] **Multi-status/page coverage**: Add distinct matching fixtures across all five statuses and multiple pages; verify every distinct ID is cancelled once.
  - Files to change: `cancel-pr-workflows/tests/fakes/gh`, `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - Verification: run the full action suite and inspect exact cancellation calls.
- [ ] **Fork and target-event safety**: Add associated/unrelated `pull_request_target` and unassociated fork-shaped cases.
  - Files to change: `cancel-pr-workflows/tests/fakes/gh`, `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - Verification: matching association is cancelled; all other cases remain untouched.
- [ ] **Malformed IDs**: Add invalid-ID discovery scenarios.
  - Files to change: `cancel-pr-workflows/tests/fakes/gh`, `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - Verification: fatal response and zero cancellation requests.
- [ ] **Later-status fail-closed behavior**: Fail a non-queued status after a candidate is found.
  - Files to change: `cancel-pr-workflows/tests/fakes/gh`, `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - Verification: no cancellation occurs after discovery failure.
- [ ] **Logging and memory contract**: Assert per-status totals and document or replace `--slurp`.
  - Files to change: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh`, `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - Verification: shell suite passes and logs contain stable per-status totals.
- [ ] **Minor cleanup**: Remove or use the unused completed counter.
  - Files to change: `cancel-pr-workflows/scripts/cancel-pr-workflows.sh`
  - Verification: shell syntax check passes.

### Testing Requirements After Fixes

After implementing fixes, ensure:
- [ ] All planned unit/integration shell tests exist and pass.
- [ ] All five status queries are paginated and status-filtered.
- [ ] Multi-page and cross-status candidates are deduplicated and all selected runs are cancelled.
- [ ] Fork and `pull_request_target` association safety is covered.
- [ ] Malformed responses and IDs fail closed before cancellation.
- [ ] Later-status discovery failures cannot cause partial cancellation.
- [ ] Retry, rate-limit, race, idempotency, continuation, and authorization tests remain passing.
- [ ] `git diff --check` passes and only intended shared-repository files change.
