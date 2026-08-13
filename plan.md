# Implementation Plan

## Task Overview
- **Source**: PL-381
- **Title**: Cancel Closed PR Workflows without scanning repository history
- **Description**: Replace unbounded workflow-run discovery in the shared `cancel-pr-workflows` composite action with bounded discovery of active workflow runs, while preserving trusted pull-request association filtering, cancellation races, retries, security behavior, and the existing env-only caller interface.
- **Repository scope**: `/Users/felix/Developer/Misc/GitHub-Workflows` only. The SnipNotes-Next checkout and all other callers are compatibility-audit references; no caller edits are planned unless the existing interface unexpectedly proves incompatible.

## Requirements Analysis
- **Core Functionality**:
  - Discover cancellable workflow runs through separate paginated API queries for `queued`, `in_progress`, `requested`, `waiting`, and `pending` statuses.
  - Examine every page returned by every status query, without scanning terminal historical runs.
  - Filter candidates by the trusted `PR_NUMBER` association in `pull_requests[].number`, exclude the cleanup run itself, and deduplicate run IDs across statuses/pages.
  - Cancel every selected run, continue after individual cancellation failures, and preserve 404/409 completion-race handling.
- **Acceptance Criteria**:
  - Discovery uses bounded status-filtered requests and reaches cancellation promptly in a repository with thousands of historical runs.
  - Tests prove distinct matching runs on multiple pages/status queries are all selected and cancelled.
  - Completed, unrelated, unassociated, self, scheduled, release, manual-dispatch, and push-only runs remain untouched.
  - No-match, repeat-run, reopen/re-close, fork PR, retry, race, authorization, and unrecoverable API-error behavior remains safe and observable.
  - Logs report status-query/page/run totals, selected IDs, cancellations, no-match outcomes, retries, races, and fatal errors without dumping full payloads.
  - Existing env-only `action.yml` contract remains unchanged and callers remain compatible.
- **Technical Constraints**:
  - Use Bash, `gh api`, `jq`, and the existing custom executable test harness.
  - Retain bounded retry/backoff and rate-limit-header handling for discovery, cancellation, and race rechecks.
  - Verify the workflow-runs endpoint accepts every required active status (`queued`, `in_progress`, `requested`, `waiting`, and `pending`) before finalizing the request contract; do not silently fall back to an unfiltered query if a status is rejected.
  - Do not use branch, SHA, fork-controlled data, or event filtering as the PR identity; `PR_NUMBER` from the trusted caller remains authoritative.
  - Do not change PL-245 concurrency behavior, caller workflow permissions/events/runners, or unrelated actions.
- **Integration Points**:
  - `cancel-pr-workflows/action.yml` continues to provide `GH_TOKEN`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, and `PR_NUMBER`.
  - The GitHub workflow-runs endpoint is queried with `status` and pagination.
  - The shared action tests and `tests/fakes/gh` define and assert the exact request contract.

## Codebase Analysis
- **Existing Patterns**:
  - `scripts/cancel-pr-workflows.sh` centralizes context validation, HTTP parsing, retries, discovery, filtering, cancellation, and race rechecks.
  - Discovery currently uses one `--paginate --slurp` request with no status filter, then aggregates all pages in `DISCOVERY_JSON` before `jq` filtering.
  - Tests use a temporary state directory, a fake `gh`, recorded exact calls, deterministic response fixtures, and a fake `sleep` for retry assertions.
- **Available Infrastructure**:
  - Existing API response parser handles status codes, transport errors, retry-after, and rate-limit headers.
  - Existing test helpers assert output, status, exact API call counts, cancellation exclusions, and sleep delays.
  - Existing fake supports paginated/slurped discovery fixtures and scenario-specific cancellation/race responses; it will be extended for status-filtered requests and page-distinct fixtures.
- **Dependencies**:
  - `cancel-pr-workflows/scripts/cancel-pr-workflows.sh`
  - `cancel-pr-workflows/tests/fakes/gh`
  - `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`
  - `cancel-pr-workflows/action.yml` should be audited and remain unchanged.
  - Caller workflows, including SnipNotes-Next, should be audited externally but are out of implementation scope.
  - **Architecture Notes**:
  - Avoid a global full-history JSON variable. Discovery should process one status query at a time, validate its paginated response, extract only relevant candidate records/IDs into a bounded temporary file, and release both the raw response and `API_OUTPUT` before the next status.
  - Prefer incremental page processing (`--paginate` without `--slurp`) if supported reliably by the existing `gh` invocation and fake; if `--slurp` is retained, document that only one status response is held at a time and treat the per-status payload as a bounded active-run result. The implementation must not claim full memory-boundedness while retaining a potentially large per-status slurp.
  - The five status queries intentionally omit `event` filtering. Association filtering must remain the safety boundary because relevant PR-associated runs can originate from multiple PR event types, including `pull_request_target`.
  - Discovery totals should distinguish status queries/pages examined and active runs examined; define a stable summary format (including zero-page/zero-run statuses) and assert it in tests. Selected IDs should be deduplicated before cancellation, with deterministic ordering preserved or explicitly declared non-contractual.
  - A terminal failure, malformed response, or invalid run ID for any required status query is fail-closed and aborts before cancellation; candidates from earlier successful statuses are not partially cancelled.

## Implementation Strategy
- **Problem Complexity**: Complex reliability/performance bug in a security-sensitive shared GitHub Action.
- **Core Problem**: The current discovery request paginates over every historical workflow run and materializes the complete repository history before filtering.
- **Approach**: Iterate over a single readonly list of the five verified cancellable statuses, issue a paginated status-filtered request for each, retry only the failing status query up to the existing bounded attempt count, and fail closed if any required query cannot complete. Prefer incremental page processing; if `--slurp` is retained, consume and release one status response at a time and never retain the full repository history. Append only PR-associated non-self run IDs to a temporary candidate file, deduplicate deterministically before cancellation, then reuse the existing cancellation and race-handling pipeline. Keep the action interface and callers unchanged.
- **Testing Approach**: Automated shell integration tests in the shared action repository, followed by a representative live performance check if API access is available. No manual UI verification is required.
- **Phases**:
  1. **Refactor discovery to bounded status queries**
     - **Implementation**:
       - Replace the single unfiltered discovery endpoint with a readonly status list containing the five verified active statuses: `queued`, `in_progress`, `requested`, `waiting`, and `pending`.
       - Verify the endpoint's accepted status values against the REST contract before implementation; preserve `--method GET` and pagination, prefer `--paginate` without `--slurp` for incremental page processing, and do not add `event` or branch filters. If `--slurp` is retained for compatibility, consume one status response at a time and release `API_OUTPUT` before the next query.
       - Add temporary-file lifecycle management for filtered candidate IDs and ensure cleanup on success/failure; use deterministic sorting/deduplication (or an explicitly tested equivalent) before populating `RUN_IDS`.
       - Validate each page response as an object containing a `workflow_runs` array, count pages and runs per status, and define stable logs for zero pages and zero runs.
       - Extract only runs associated with `PR_NUMBER`, exclude `completed` defensively with an observable counter/log if encountered, exclude `GITHUB_RUN_ID`, validate numeric IDs, and deduplicate across all queries/pages.
       - Retry only the status query that failed transiently, preserving existing backoff/header behavior; a terminal error, malformed response, or invalid run ID in any required status query fails closed before any cancellation.
       - Remove the full-history `DISCOVERY_JSON` accumulation and update logs to identify each status query plus aggregate page/run totals and selected candidates.
       - Keep existing cancellation and race functions unchanged unless required by the new discovery data flow.
       - Audit `action.yml` and document that its env-only interface remains stable; do not modify caller workflows.
     - **Verification**: Because the existing fake and assertions intentionally encode the old unfiltered request, verify this phase with `bash -n`, focused local checks of the new discovery function, and a review that failure is fail-closed; do not require the complete legacy suite to pass until Phase 2 updates its fake and fixtures.
  2. **Update fakes and regression tests for the new API contract**
     - **Implementation**:
       - Update `tests/fakes/gh` to parse and assert the `status` query, return status-specific paginated fixtures, and retain deterministic retry/race/auth responses. The fake must match query parameters structurally and reject the old unfiltered endpoint.
       - Add fixtures with distinct matching run IDs on at least two pages and across all five statuses; include duplicate IDs across queries to prove deduplication before cancellation and retain excluded `pull_request`, `pull_request_target`, `schedule`, `release`, `workflow_dispatch`, and `push` event cases.
       - Add/adjust exact-call assertions for all five status-filtered discovery requests and ensure no unfiltered endpoint is accepted.
       - Add explicit fork-safety and `pull_request_target` association tests: runs with no association remain untouched, associated target-event runs are eligible, and unrelated target-event runs are not.
       - Cover all cancellable statuses, no matches (including zero-page/zero-run logging), completed/unrelated/unassociated/self exclusions, malformed responses/IDs, retries at the individual status-query boundary, authorization failures, exhausted discovery failures, and cancellation continuation.
       - Add a bounded-result regression guard demonstrating that only filtered active candidates are retained/processed rather than the complete historical fixture; avoid relying on duplicate page artifacts.
       - Preserve existing tests for cancellation races, retry delays, idempotency, reopen/re-close behavior, and continuation after failure; assert that a fatal failure in any status query aborts before any cancellation request.
     - **Verification**: Run `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh`; require every scenario to pass and inspect recorded calls to confirm every status query is paginated and status-filtered.
  3. **Compatibility and operational verification**
     - **Implementation**:
       - Audit `action.yml` and all maintained caller references against the unchanged env contract, including SnipNotes-Next as a reference only; make no edits outside `GitHub-Workflows`.
       - Review logs and error paths for actionable annotations, absence of full payload dumps, and clear no-match/race behavior.
       - Review the diff for preservation of PR-number association, fork safety, self-exclusion, PL-245 concurrency independence, and minimal permissions assumptions.
       - If feasible, run a representative API-backed benchmark or document the measured request count/latency using a repository with at least 5,000 historical runs; the deterministic test remains the mandatory regression guard.
     - **Verification**: Re-run the complete shared action suite and shell/static checks, then confirm `git diff --check` and that only intended files in `GitHub-Workflows` changed. Report any unavailable live benchmark explicitly.

**Phase Verification Approach**: Complete and pass each phase's automated verification before starting the next. Tests are written/updated after the implementation change within the relevant phase. No GUI or simulator verification applies.

## Quality Assurance Plan
- **Testing Strategy**: Custom shell integration suite with fake GitHub API, exact request assertions, fixture-based pagination/filtering tests, retry/race/error tests, plus optional live performance validation.
- **Edge Cases**:
  - Runs split across multiple pages and statuses.
  - Same run returned by more than one status query/page.
  - A run transitions to completed or disappears before cancellation.
  - No active associated runs, repeated cleanup, and reopen/re-close sequences.
  - Malformed discovery JSON or non-numeric IDs.
  - Transport, 429, rate-limited 403, 5xx, 401/403 authorization, and non-retryable API failures.
  - Fork PRs and runs without pull-request associations.
- **Regression Prevention**:
  - Preserve exact trusted PR-number association filtering and self-exclusion.
  - Assert completed and unrelated run IDs never receive cancellation requests.
  - Assert every selected ID receives one cancellation attempt and failures do not prevent later candidates.
  - Assert caller interface and caller files remain unchanged.
- **Success Verification**: All action tests pass; discovery requests are limited to the five active statuses and paginate fully; no full repository-history response is retained; logs and fatal errors satisfy the ticket's observability contract; diff scope is limited to the shared repository.

## Development Environment
- **Setup Requirements**: Bash, `jq`, `gh` (fake `gh` for tests), and the existing GitHub-Workflows checkout. No app project generation or Xcode verification is needed.
- **Debugging Strategy**: Use recorded fake API calls, scenario-specific fixture output, `bash -n`, and targeted test execution; inspect API status/header parsing without exposing tokens or full payloads.
- **Iteration Approach**: First change discovery and run focused shell tests; then update fake/test contract; finally run the complete suite and static/diff checks.

## Risk Assessment
- **Potential Issues**:
  - Five queries increase request count and could miss a status if the API supports additional cancellable states; this is mitigated by verifying the documented endpoint contract before implementation.
  - `gh --paginate --slurp` may still materialize a large active-status response; incremental page processing is preferred, and retaining slurp is acceptable only with explicit per-status memory/logging bounds.
  - A status-filtered run can change state between discovery and cancellation.
  - A transient failure on one status query can increase API usage; retries are scoped to that status rather than restarting successful queries.
  - Filtering too early could accidentally remove relevant PR-associated runs or alter existing safety behavior.
  - A fatal or malformed response for any required status after earlier statuses succeed could otherwise produce partial cancellation; the plan explicitly fails closed before cancellation.
- **Mitigation Strategies**:
  - Enumerate and test all five required statuses explicitly after verifying the REST contract; surface a rejected status as a fatal actionable error rather than silently broadening discovery.
  - Process pages incrementally where possible; otherwise process one status response at a time, release API buffers, and test multi-page behavior.
  - Preserve and test existing 404/409 recheck handling and bounded retries, with retry attempts scoped to the failing status query.
  - Keep PR-number association as the only identity match and omit event/branch/SHA substitutions; explicitly test associated and unrelated `pull_request_target` runs and fork-shaped runs with no association.
  - Use exact fake request assertions, structural query parsing, distinct fixture IDs, and duplicate-cancellation assertions to prevent false pagination or deduplication passes.
  - Fail closed on any status-query discovery failure before cancellation so earlier partial results cannot be acted on.
- **Backup Approaches**:
  - If incremental pagination cannot be made reliable with `gh` and the fake, retain `--paginate --slurp` only per status, document the memory trade-off, and use a bounded active-result regression guard; do not revert to an unfiltered query.
  - If the REST contract supports a single comma-separated status query with identical semantics, evaluate it as a simpler lower-request alternative, but retain explicit coverage of all five statuses and reject any approach that silently omits a required state.
  - If the endpoint rejects one required status value after contract verification, stop with a documented API incompatibility rather than silently broadening to an unbounded query.
  - Keep the action interface and caller workflows unchanged unless a concrete compatibility failure is demonstrated.

## Files Likely to Change
- `cancel-pr-workflows/scripts/cancel-pr-workflows.sh` - Replace unfiltered full-history discovery with five status-filtered paginated queries and bounded candidate processing.
- `cancel-pr-workflows/tests/fakes/gh` - Model status-filtered discovery requests, pagination, and new fixtures.
- `cancel-pr-workflows/tests/test-cancel-pr-workflows.sh` - Assert request contract, multi-page/multi-status selection, bounded processing, and regressions.
- `cancel-pr-workflows/action.yml` - Audit only; expected to remain unchanged.
- `plan.md` - This implementation plan; no other repositories or caller workflow files are in scope.
