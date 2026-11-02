#!/usr/bin/env bash
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly FAKE_BIN="${ACTION_ROOT}/tests/fakes"
readonly SCRIPT="${ACTION_ROOT}/scripts/collect-package-changes.sh"

RUN_OUTPUT=""
RUN_STDOUT=""
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
  local ticket=${2-SX-914}
  local max_diff=${3-60000}

  RUN_STDOUT=$(
    GH_TOKEN=test-token \
    OWNER=example \
    CURRENT_REPO=example/App \
    TICKET_ID="${ticket}" \
    PACKAGES_DIR="${TEST_TMP}/packages" \
    PACKAGES_DISPLAY_DIR=.ai-review-packages \
    MAX_PACKAGE_DIFF_CHARS="${max_diff}" \
    FAKE_GH_SCENARIO="${scenario}" \
    FAKE_GH_STATE_DIR="${TEST_TMP}/gh" \
    PATH="${FAKE_BIN}:${PATH}" \
      "${SCRIPT}" 2>"${TEST_TMP}/stderr"
  )
  RUN_STATUS=$?
  RUN_OUTPUT="${RUN_STDOUT}
$(cat "${TEST_TMP}/stderr")"
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

assert_not_contains() {
  local unexpected=$1
  if [[ "${RUN_OUTPUT}" == *"${unexpected}"* ]]; then
    printf 'Expected output not to contain %q. Output:\n%s\n' "${unexpected}" "${RUN_OUTPUT}" >&2
    return 1
  fi
}

assert_no_call() {
  local fragment=$1
  if grep -Fq -- "${fragment}" "${TEST_TMP}/gh/calls.log"; then
    printf 'Expected no gh call containing %q. Calls:\n%s\n' "${fragment}" "$(cat "${TEST_TMP}/gh/calls.log")" >&2
    return 1
  fi
}

test_collects_default_branch_commits_oldest_first() {
  run_script default || return 1
  assert_status 0 || return 1
  assert_contains '**FileKit**: 2 commit(s) on the default branch referencing SX-914' || return 1
  assert_contains 'repos/example/FileKit/commits/aaaa1111aaaa1111' || return 1
  assert_contains 'repos/example/FileKit/commits/bbbb2222bbbb2222' || return 1
  [[ "${RUN_STDOUT}" == *'Replace payloads'*'Keep metadata'* ]] || {
    printf 'Expected commits oldest first. Output:\n%s\n' "${RUN_STDOUT}" >&2
    return 1
  }
  # The newest matching commit is the snapshot ref.
  assert_contains 'Source at `bbbb2222`: `.ai-review-packages/FileKit/`' || return 1
  [[ -f "${TEST_TMP}/packages/FileKit/Sources/FileKit.swift" ]] || {
    printf 'Expected FileKit snapshot to be extracted\n' >&2
    return 1
  }
}

test_excludes_current_repo_and_partial_ticket_matches() {
  run_script default || return 1
  assert_status 0 || return 1
  assert_not_contains 'App change' || return 1
  assert_not_contains 'OtherKit' || return 1
  assert_not_contains 'NoiseKit' || return 1
  assert_not_contains 'OldKit' || return 1
  assert_no_call 'repos/example/App/git/matching-refs' || return 1
  assert_no_call 'repos/example/OldKit/git/matching-refs' || return 1
}

test_skips_branch_lookup_for_repos_with_default_branch_commits() {
  run_script default || return 1
  assert_no_call 'repos/example/FileKit/git/matching-refs' || return 1
}

test_collects_unmerged_ticket_branch() {
  run_script default || return 1
  assert_status 0 || return 1
  assert_contains '**BranchKit**: unmerged branch `sx-914-fix` compared with `trunk`' || return 1
  assert_contains 'repos/example/BranchKit/compare/trunk...sx-914-fix' || return 1
  assert_contains 'Source at `sx-914-fix`: `.ai-review-packages/BranchKit/`' || return 1
}

test_normalizes_lowercase_ticket_id() {
  run_script default sx-914 || return 1
  assert_status 0 || return 1
  grep -Fxq 'SX-914 user:example' "${TEST_TMP}/gh/search-query" || {
    printf 'Unexpected search query: %s\n' "$(cat "${TEST_TMP}/gh/search-query")" >&2
    return 1
  }
}

test_prints_nothing_without_matches() {
  run_script none || return 1
  assert_status 0 || return 1
  [[ -z "${RUN_STDOUT}" ]] || {
    printf 'Expected empty stdout, got:\n%s\n' "${RUN_STDOUT}" >&2
    return 1
  }
  assert_contains 'No package changes found for SX-914.' || return 1
}

test_search_failure_still_checks_branches() {
  run_script search-fails || return 1
  assert_status 0 || return 1
  assert_contains '::warning::Commit search for SX-914 failed' || return 1
  assert_contains '**BranchKit**: unmerged branch `sx-914-fix`' || return 1
}

test_truncates_large_diffs() {
  run_script large-diff SX-914 200 || return 1
  assert_status 0 || return 1
  assert_contains 'Truncating to 200 chars' || return 1
  assert_contains '(package diffs truncated due to size' || return 1
}

test_rejects_invalid_ticket_id() {
  run_script default 'not a ticket' || return 1
  assert_status 0 || return 1
  assert_contains "Invalid ticket ID 'NOT A TICKET'" || return 1
  [[ ! -f "${TEST_TMP}/gh/calls.log" ]] || {
    printf 'Expected no gh calls\n' >&2
    return 1
  }
}

main() {
  local failures=0
  local test_name
  for test_name in $(declare -F | awk '{print $3}' | grep '^test_'); do
    setup
    if "${test_name}"; then
      printf 'ok - %s\n' "${test_name}"
    else
      printf 'not ok - %s\n' "${test_name}"
      failures=$((failures + 1))
    fi
    teardown
  done
  if (( failures > 0 )); then
    printf '%d test(s) failed\n' "${failures}"
    exit 1
  fi
  printf 'All tests passed\n'
}

main "$@"
