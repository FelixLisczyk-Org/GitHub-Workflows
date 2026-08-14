#!/usr/bin/env bash
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly FAKE_BIN="${ACTION_ROOT}/tests/fakes"
readonly SCRIPT="${ACTION_ROOT}/scripts/check-pr-report-status.sh"

RUN_OUTCOME=""
RUN_OUTPUT=""
RUN_STATUS=0
TEST_TMP=""

setup() {
  TEST_TMP=$(mktemp -d)
}

teardown() {
  rm -rf "${TEST_TMP}"
}

run_script() {
  local scenario=$1
  local header=${2-periphery-scan}
  local success_pattern=${3-'^## (✅|🔍)'}
  local pr_number=${4-7}
  local repository=${5-example/project}
  local token=${6-test-token}

  RUN_OUTCOME="${TEST_TMP}/github-output"
  rm -f "${RUN_OUTCOME}"

  RUN_OUTPUT=$(
    GITHUB_OUTPUT="${RUN_OUTCOME}" \
    GITHUB_REPOSITORY="${repository}" \
    GITHUB_TOKEN="${token}" \
    HEADER="${header}" \
    PR_NUMBER="${pr_number}" \
    SUCCESS_PATTERN="${success_pattern}" \
    FAKE_CURL_SCENARIO="${scenario}" \
    FAKE_CURL_STATE_DIR="${TEST_TMP}" \
    PATH="${FAKE_BIN}:${PATH}" \
      "${SCRIPT}" 2>&1
  )
  RUN_STATUS=$?
}

assert_status() {
  local expected=$1
  if (( RUN_STATUS != expected )); then
    printf 'Expected status %s, got %s. Output:\n%s\n' "${expected}" "${RUN_STATUS}" "${RUN_OUTPUT}" >&2
    return 1
  fi
}

assert_contains() {
  local expected=$1
  if [[ "${RUN_OUTPUT}" != *"${expected}"* ]]; then
    printf 'Expected output to contain %q. Output:\n%s\n' "${expected}" "${RUN_OUTPUT}" >&2
    return 1
  fi
}

assert_already_reported() {
  local expected=$1
  local actual=""

  if [[ -f "${RUN_OUTCOME}" ]]; then
    actual=$(grep -F 'already_reported=' "${RUN_OUTCOME}" | tail -1 | cut -d= -f2)
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Expected already_reported=%s, got %q. Output:\n%s\n' "${expected}" "${actual}" "${RUN_OUTPUT}" >&2
    return 1
  fi
}

assert_call_count() {
  local expected=$1
  local actual=0

  if [[ -f "${TEST_TMP}/calls.log" ]]; then
    actual=$(wc -l <"${TEST_TMP}/calls.log")
  fi

  if (( actual != expected )); then
    printf 'Expected %s curl call(s), got %s. Calls:\n' "${expected}" "${actual}" >&2
    if [[ -f "${TEST_TMP}/calls.log" ]]; then
      cat "${TEST_TMP}/calls.log" >&2
    fi
    return 1
  fi
}

# (a) No comments at all -> false.
test_no_comments_runs_scan() {
  run_script no_comments

  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'No existing periphery-scan sticky comment found for PR #7.' || return 1
}

# (b) A comment matching the header marker but with error content -> false.
test_error_report_runs_scan() {
  run_script error_only

  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'does not match the success pattern' || return 1
}

# (c) A comment matching the header marker with success content (real emoji bytes) -> true.
test_clean_report_skips_scan() {
  run_script success_only

  assert_status 0 || return 1
  assert_already_reported true || return 1
  assert_contains 'already reported' || return 1
}

test_findings_report_skips_scan() {
  run_script findings_only

  assert_status 0 || return 1
  assert_already_reported true || return 1
}

# (d) Most-recent-wins: an older error followed by a newer success -> true; the reverse -> false.
test_most_recent_comment_wins() {
  run_script error_then_success

  assert_status 0 || return 1
  assert_already_reported true || return 1
}

test_stale_success_after_newer_error_runs_scan() {
  run_script success_then_error

  assert_status 0 || return 1
  assert_already_reported false || return 1
}

# (e) curl fails (network/transport error) -> false, exit 0.
test_transport_failure_fails_open() {
  run_script transport_error

  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'treating as not yet reported' || return 1
}

test_retries_once_then_succeeds() {
  run_script flaky_then_success

  assert_status 0 || return 1
  assert_already_reported true || return 1
  assert_call_count 2 || return 1
}

test_exhausted_retries_fail_open() {
  run_script always_fails

  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_call_count 2 || return 1
}

test_malformed_json_fails_open() {
  run_script malformed_json

  assert_status 0 || return 1
  assert_already_reported false || return 1
}

test_non_array_response_fails_open() {
  run_script not_an_array

  assert_status 0 || return 1
  assert_already_reported false || return 1
}

# (f) An unrelated comment matches success_pattern but not this header's marker -> false.
test_wrong_header_marker_is_not_a_match() {
  run_script unrelated_success_wrong_header

  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'No existing periphery-scan sticky comment found for PR #7.' || return 1
}

# (g) Required inputs missing/empty -> false, exit 0, no API calls made.
test_missing_required_inputs_fail_open_without_calling_api() {
  run_script no_comments '' '^## (✅|🔍)'
  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'HEADER is required' || return 1
  assert_call_count 0 || return 1

  run_script no_comments periphery-scan ''
  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'SUCCESS_PATTERN is required' || return 1
  assert_call_count 0 || return 1

  run_script no_comments periphery-scan '^## (✅|🔍)' ''
  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'PR_NUMBER must be a positive decimal integer' || return 1
  assert_call_count 0 || return 1

  run_script no_comments periphery-scan '^## (✅|🔍)' 7 example/project ''
  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'GITHUB_TOKEN is required' || return 1
  assert_call_count 0 || return 1

  run_script no_comments periphery-scan '^## (✅|🔍)' 7 not-a-repository
  assert_status 0 || return 1
  assert_already_reported false || return 1
  assert_contains 'GITHUB_REPOSITORY must use the owner/repo format' || return 1
  assert_call_count 0 || return 1
}

# Pagination: a full 100-comment first page has no match, but the second page's comment does.
test_paginates_across_full_pages() {
  run_script two_pages

  assert_status 0 || return 1
  assert_already_reported true || return 1
  assert_contains 'Fetched 101 comment(s) across 2 page(s) for PR #7.' || return 1
  assert_call_count 2 || return 1
}

test_missing_github_output_still_fails_open() {
  local run_output
  local run_status

  run_output=$(
    GITHUB_REPOSITORY=example/project \
    GITHUB_TOKEN=test-token \
    HEADER=periphery-scan \
    PR_NUMBER=7 \
    SUCCESS_PATTERN='^## (✅|🔍)' \
    FAKE_CURL_SCENARIO=success_only \
    FAKE_CURL_STATE_DIR="${TEST_TMP}" \
    PATH="${FAKE_BIN}:${PATH}" \
      "${SCRIPT}" 2>&1
  )
  run_status=$?

  if (( run_status != 0 )); then
    printf 'Expected status 0, got %s. Output:\n%s\n' "${run_status}" "${run_output}" >&2
    return 1
  fi
  if [[ "${run_output}" != *'GITHUB_OUTPUT is not set'* ]]; then
    printf 'Expected a GITHUB_OUTPUT warning. Output:\n%s\n' "${run_output}" >&2
    return 1
  fi
}

main() {
  local failed=0
  local test
  local -a tests=(
    test_no_comments_runs_scan
    test_error_report_runs_scan
    test_clean_report_skips_scan
    test_findings_report_skips_scan
    test_most_recent_comment_wins
    test_stale_success_after_newer_error_runs_scan
    test_transport_failure_fails_open
    test_retries_once_then_succeeds
    test_exhausted_retries_fail_open
    test_malformed_json_fails_open
    test_non_array_response_fails_open
    test_wrong_header_marker_is_not_a_match
    test_missing_required_inputs_fail_open_without_calling_api
    test_paginates_across_full_pages
    test_missing_github_output_still_fails_open
  )

  setup
  trap teardown EXIT

  for test in "${tests[@]}"; do
    rm -rf "${TEST_TMP:?}"/*
    if "${test}"; then
      printf 'ok - %s\n' "${test}"
    else
      printf 'not ok - %s\n' "${test}"
      failed=1
    fi
  done

  if (( failed != 0 )); then
    return 1
  fi

  printf 'All %d tests passed.\n' "${#tests[@]}"
}

main "$@"
