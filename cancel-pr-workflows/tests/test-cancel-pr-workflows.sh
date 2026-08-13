#!/usr/bin/env bash
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly FAKE_BIN="${ACTION_ROOT}/tests/fakes"
readonly SCRIPT="${ACTION_ROOT}/scripts/cancel-pr-workflows.sh"

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
  local pr_number=${2-7}
  local repository=${3-example/project}
  local run_id=${4-103}
  local token=${5-test-token}

  RUN_OUTPUT=$(
    GH_TOKEN="${token}" \
    GITHUB_REPOSITORY="${repository}" \
    GITHUB_RUN_ID="${run_id}" \
    PR_NUMBER="${pr_number}" \
    FAKE_GH_SCENARIO="${scenario}" \
    FAKE_GH_STATE_DIR="${TEST_TMP}" \
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

assert_failure() {
  if (( RUN_STATUS == 0 )); then
    printf 'Expected failure. Output:\n%s\n' "${RUN_OUTPUT}" >&2
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

assert_not_contains() {
  local unexpected=$1
  if [[ "${RUN_OUTPUT}" == *"${unexpected}"* ]]; then
    printf 'Expected output not to contain %q. Output:\n%s\n' "${unexpected}" "${RUN_OUTPUT}" >&2
    return 1
  fi
}

assert_call_count() {
  local expected=$1
  local fragment=$2
  local actual=0

  if [[ -f "${TEST_TMP}/calls.log" ]]; then
    actual=$(grep -F -c -- "${fragment}" "${TEST_TMP}/calls.log" || true)
  fi

  if (( actual != expected )); then
    printf 'Expected %s call(s) containing %q, got %s. Calls:\n' "${expected}" "${fragment}" "${actual}" >&2
    if [[ -f "${TEST_TMP}/calls.log" ]]; then
      grep -F -- "${fragment}" "${TEST_TMP}/calls.log" >&2 || true
    fi
    return 1
  fi
}

assert_exact_call_count() {
  local expected=$1
  local call=$2
  local actual=0

  if [[ -f "${TEST_TMP}/calls.log" ]]; then
    actual=$(grep -F -x -c -- "${call}" "${TEST_TMP}/calls.log" || true)
  fi

  if (( actual != expected )); then
    printf 'Expected exact call %q %s time(s), got %s. All calls:\n' "${call}" "${expected}" "${actual}" >&2
    if [[ -f "${TEST_TMP}/calls.log" ]]; then
      while IFS= read -r line; do
        printf '%s\n' "${line}" >&2
      done <"${TEST_TMP}/calls.log"
    fi
    return 1
  fi
}

assert_sleep_delay() {
  local expected=$1
  local actual=""

  if [[ -f "${TEST_TMP}/sleep.log" ]]; then
    actual=$(<"${TEST_TMP}/sleep.log")
  fi

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Expected sleep delay %q, got %q.\n' "${expected}" "${actual}" >&2
    return 1
  fi
}

assert_sleep_delay_range() {
  local minimum=$1
  local maximum=$2
  local actual=""

  if [[ -f "${TEST_TMP}/sleep.log" ]]; then
    actual=$(<"${TEST_TMP}/sleep.log")
  fi

  if [[ ! "${actual}" =~ ^[0-9]+$ ]] || (( actual < minimum || actual > maximum )); then
    printf 'Expected sleep delay from %s through %s, got %q.\n' "${minimum}" "${maximum}" "${actual}" >&2
    return 1
  fi
}

assert_no_api_calls() {
  if [[ -f "${TEST_TMP}/calls.log" ]]; then
    printf 'Expected no gh calls. Calls:\n' >&2
    while IFS= read -r line; do
      printf '%s\n' "${line}" >&2
    done <"${TEST_TMP}/calls.log"
    return 1
  fi
}

test_paginated_selection_associations_exclusions_and_success() {
  run_script selection 7 example/project 9007199254740993

  assert_status 0 || return 1
  assert_contains 'Closing PR #7 in example/project; cleaning up associated active workflow runs.' || return 1
  assert_contains 'Discovered status queued: 2 page(s), 14 workflow run(s).' || return 1
  assert_contains 'Discovered status in_progress: 1 page(s), 2 workflow run(s).' || return 1
  assert_contains 'Discovered status requested: 1 page(s), 1 workflow run(s).' || return 1
  assert_contains 'Discovered status waiting: 1 page(s), 1 workflow run(s).' || return 1
  assert_contains 'Discovered status pending: 1 page(s), 2 workflow run(s).' || return 1
  assert_contains 'Discovered 5 status query/queries, 6 page(s), and 20 active workflow run(s).' || return 1
  assert_contains 'Selected 7 active workflow run(s) associated with closed PR #7: 200 201 202 203 204 205 210' || return 1
  for selected_id in 200 201 202 203 204 205 210; do
    assert_exact_call_count 1 "api --method POST --include /repos/example/project/actions/runs/${selected_id}/cancel" || return 1
  done
  assert_contains 'Cancellation accepted for workflow run 200 (HTTP 202).' || return 1
  assert_contains 'Cancellation accepted for workflow run 201 (HTTP 204).' || return 1
  assert_not_contains 'test-token' || return 1

  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=queued' || return 1
  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=in_progress' || return 1
  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=requested' || return 1
  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=waiting' || return 1
  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=pending' || return 1
  assert_exact_call_count 1 'api --method POST --include /repos/example/project/actions/runs/201/cancel' || return 1

  local excluded_id
  for excluded_id in 101 102 104 105 106 107 108 109 211 212 9007199254740993; do
    assert_call_count 0 "/actions/runs/${excluded_id}/cancel" || return 1
  done
}

test_malformed_context_is_rejected_before_api_calls() {
  local pr_number
  local -a invalid_pr_numbers=(
    ''
    '-7'
    '7.5'
    ' 7'
    '7;printf injected'
  )

  for pr_number in "${invalid_pr_numbers[@]}"; do
    rm -f "${TEST_TMP}/calls.log"
    run_script no_match "${pr_number}"
    assert_failure || return 1
    assert_contains 'PR_NUMBER must be a positive decimal integer.' || return 1
    assert_no_api_calls || return 1
  done

  rm -f "${TEST_TMP}/calls.log"
  run_script no_match 7 not-a-repository
  assert_failure || return 1
  assert_contains 'GITHUB_REPOSITORY must use the owner/repo format.' || return 1
  assert_no_api_calls || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script no_match 7 example/project invalid
  assert_failure || return 1
  assert_contains 'GITHUB_RUN_ID must be a positive decimal integer.' || return 1
  assert_no_api_calls || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script no_match 7 example/project 103 ''
  assert_failure || return 1
  assert_contains 'GH_TOKEN is required.' || return 1
  assert_no_api_calls || return 1
}

test_no_match_and_repeat_are_idempotent() {
  run_script no_match
  assert_status 0 || return 1
  assert_contains 'Discovered status queued: 1 page(s), 0 workflow run(s).' || return 1
  assert_contains 'Discovered status in_progress: 1 page(s), 0 workflow run(s).' || return 1
  assert_contains 'Discovered status requested: 1 page(s), 0 workflow run(s).' || return 1
  assert_contains 'Discovered status waiting: 1 page(s), 0 workflow run(s).' || return 1
  assert_contains 'Discovered status pending: 1 page(s), 0 workflow run(s).' || return 1
  assert_contains 'Discovered 5 status query/queries, 5 page(s), and 0 active workflow run(s).' || return 1
  assert_contains 'No active workflow runs associated with closed PR #7 require cancellation.' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script repeat
  assert_status 0 || return 1
  assert_exact_call_count 1 'api --method POST --include /repos/example/project/actions/runs/301/cancel' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script repeat
  assert_status 0 || return 1
  assert_contains 'No active workflow runs associated with closed PR #7 require cancellation.' || return 1
  assert_call_count 0 '/actions/runs/301/cancel' || return 1
}

test_409_and_404_cancellation_races_recheck_state() {
  run_script race

  assert_status 0 || return 1
  assert_contains 'Cancellation of workflow run 401 returned HTTP 409; rechecking its status.' || return 1
  assert_contains 'Run 401 completed during closed-PR cleanup; no further action is needed.' || return 1
  assert_contains 'Run 402 disappeared during closed-PR cleanup; treating it as resolved.' || return 1
  assert_contains 'Cancellation of workflow run 403 returned HTTP 404; rechecking its status.' || return 1
  assert_contains 'Run 403 disappeared during closed-PR cleanup; treating it as resolved.' || return 1

  local run_id
  for run_id in 401 402 403; do
    assert_exact_call_count 1 "api --method POST --include /repos/example/project/actions/runs/${run_id}/cancel" || return 1
    assert_exact_call_count 1 "api --method GET --include /repos/example/project/actions/runs/${run_id}" || return 1
  done
}

test_429_and_server_failures_retry_then_succeed() {
  run_script cancel_retry

  assert_status 0 || return 1
  assert_contains 'Cancellation of run 501 failed transiently (attempt 1/3, HTTP 429). Retrying.' || return 1
  assert_contains 'Cancellation of run 501 failed transiently (attempt 2/3, HTTP 500). Retrying.' || return 1
  assert_contains 'Cancellation accepted for workflow run 501 (HTTP 202).' || return 1
  assert_exact_call_count 3 'api --method POST --include /repos/example/project/actions/runs/501/cancel' || return 1
  assert_sleep_delay $'60\n2' || return 1
}

test_rate_limited_403_honors_large_retry_after() {
  run_script rate_limit_403

  assert_status 0 || return 1
  assert_contains 'Cancellation of run 551 failed transiently (attempt 1/3, HTTP 403). Retrying.' || return 1
  assert_contains 'Cancellation accepted for workflow run 551 (HTTP 202).' || return 1
  assert_exact_call_count 2 'api --method POST --include /repos/example/project/actions/runs/551/cancel' || return 1
  assert_sleep_delay 60 || return 1
}

test_rate_limit_headers_wait_until_reset() {
  run_script rate_limit_reset

  assert_status 0 || return 1
  assert_contains 'Cancellation of run 552 failed transiently (attempt 1/3, HTTP 429). Retrying.' || return 1
  assert_contains 'Cancellation accepted for workflow run 552 (HTTP 202).' || return 1
  assert_exact_call_count 2 'api --method POST --include /repos/example/project/actions/runs/552/cancel' || return 1
  assert_sleep_delay_range 85 90 || return 1
}

test_discovery_transport_failure_retries_then_succeeds() {
  run_script discovery_retry

  assert_status 0 || return 1
  assert_contains 'Workflow run discovery for status queued failed transiently (attempt 1/3, HTTP transport error). Retrying.' || return 1
  assert_contains 'Discovered 5 status query/queries, 5 page(s), and 0 active workflow run(s).' || return 1
  assert_exact_call_count 2 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=queued' || return 1
}

test_discovery_rate_limit_403_retries_with_safe_delay() {
  run_script discovery_rate_limit

  assert_status 0 || return 1
  assert_contains 'Workflow run discovery for status queued failed transiently (attempt 1/3, HTTP 403). Retrying.' || return 1
  assert_contains 'Discovered 5 status query/queries, 5 page(s), and 0 active workflow run(s).' || return 1
  assert_exact_call_count 2 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=queued' || return 1
  assert_sleep_delay 60 || return 1
}

test_auth_and_exhausted_discovery_failures_are_fatal() {
  run_script auth_cancel
  assert_failure || return 1
  assert_contains 'Authorization failed while cancelling run 601 (HTTP 403).' || return 1
  assert_exact_call_count 1 'api --method POST --include /repos/example/project/actions/runs/601/cancel' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script discovery_auth
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'queued' failed after 1 attempt(s) (HTTP 401)." || return 1
  assert_exact_call_count 1 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=queued' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script discovery_failure
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'queued' failed after 3 attempt(s) (HTTP 500)." || return 1
  assert_exact_call_count 3 'api --method GET --paginate --slurp /repos/example/project/actions/runs?per_page=100&status=queued' || return 1
}

test_malformed_discovery_and_filter_failures_are_fatal() {
  run_script malformed_discovery
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'queued' returned an invalid response." || return 1
  assert_call_count 0 '/cancel' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script malformed_id
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'queued' returned an invalid response." || return 1
  assert_call_count 0 '/cancel' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script malformed_zero
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'queued' returned an invalid response." || return 1
  assert_call_count 0 '/cancel' || return 1

  rm -f "${TEST_TMP}/calls.log"
  run_script malformed_response
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'in_progress' returned an invalid response." || return 1
  assert_not_contains 'No active workflow runs associated with closed PR' || return 1
  assert_call_count 0 '/cancel' || return 1
}

test_later_status_discovery_failure_is_fail_closed() {
  run_script later_failure
  assert_failure || return 1
  assert_contains "Workflow run discovery for status 'in_progress' failed after 3 attempt(s) (HTTP 500)." || return 1
  assert_call_count 0 '/cancel' || return 1
}

test_continues_after_one_cancellation_fails() {
  run_script continue

  assert_failure || return 1
  assert_contains 'Failed to cancel workflow run 701 after 1 attempt(s) (HTTP 422).' || return 1
  assert_contains 'Cancellation accepted for workflow run 702 (HTTP 202).' || return 1
  assert_contains 'One or more active workflow runs could not be cancelled during closed-PR cleanup.' || return 1
  assert_exact_call_count 1 'api --method POST --include /repos/example/project/actions/runs/701/cancel' || return 1
  assert_exact_call_count 1 'api --method POST --include /repos/example/project/actions/runs/702/cancel' || return 1
}

main() {
  local failed=0
  local test
  local -a tests=(
    test_paginated_selection_associations_exclusions_and_success
    test_malformed_context_is_rejected_before_api_calls
    test_no_match_and_repeat_are_idempotent
    test_409_and_404_cancellation_races_recheck_state
    test_429_and_server_failures_retry_then_succeed
    test_rate_limited_403_honors_large_retry_after
    test_rate_limit_headers_wait_until_reset
    test_discovery_transport_failure_retries_then_succeeds
    test_discovery_rate_limit_403_retries_with_safe_delay
    test_auth_and_exhausted_discovery_failures_are_fatal
    test_malformed_discovery_and_filter_failures_are_fatal
    test_later_status_discovery_failure_is_fail_closed
    test_continues_after_one_cancellation_fails
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
