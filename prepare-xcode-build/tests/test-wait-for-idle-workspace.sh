#!/usr/bin/env bash
# Covers `prepare-xcode-build/scripts/wait-for-idle-workspace.sh`: the clean step
# waits for a cancelled job's leftover `xcodebuild` to leave the workspace instead
# of racing it, and fails with the processes named when it never does. Other
# processes in the workspace, such as the runner hook's `caffeinate`, never hold it.
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly SCRIPT="${ACTION_ROOT}/scripts/wait-for-idle-workspace.sh"
readonly FAKES="${ACTION_ROOT}/tests/fakes"

RUN_OUTPUT=""
RUN_STATUS=0
TEST_TMP=""
WORKSPACE=""

setup() {
  TEST_TMP=$(mktemp -d)
  WORKSPACE="${TEST_TMP}/_work/App/App"
  mkdir -p "${WORKSPACE}"
}

teardown() {
  /bin/rm -rf "${TEST_TMP}"
}

run_script() {
  local busy_calls=$1
  local timeout_seconds=$2
  RUN_OUTPUT=$(
    cd "${WORKSPACE}" &&
      PATH="${FAKES}:${PATH}" \
      GITHUB_WORKSPACE="${WORKSPACE}" \
      FAKE_LSOF_STATE_DIR="${TEST_TMP}/lsof" \
      FAKE_LSOF_WORKSPACE="${WORKSPACE}" \
      FAKE_LSOF_BUSY_CALLS="${busy_calls}" \
      WORKSPACE_IDLE_TIMEOUT_SECONDS="${timeout_seconds}" \
      WORKSPACE_IDLE_POLL_SECONDS=0 \
        "${SCRIPT}" 2>&1
  )
  RUN_STATUS=$?
}

lsof_calls() {
  cat "${TEST_TMP}/lsof/calls"
}

assert_status() {
  local expected=$1
  [[ "${RUN_STATUS}" -eq "${expected}" ]] || {
    printf 'not ok - expected exit status %s, got %s\n%s\n' "${expected}" "${RUN_STATUS}" "${RUN_OUTPUT}" >&2
    exit 1
  }
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local description=$3
  [[ "${haystack}" == *"${needle}"* ]] || {
    printf 'not ok - %s\n%s\n' "${description}" "${haystack}" >&2
    exit 1
  }
}

assert_not_contains() {
  local haystack=$1
  local needle=$2
  local description=$3
  [[ "${haystack}" != *"${needle}"* ]] || {
    printf 'not ok - %s\n%s\n' "${description}" "${haystack}" >&2
    exit 1
  }
}

# The fake always lists a `caffeinate` and an `xcodebuild-helper` in the workspace
# and an `xcodebuild` in a sibling directory sharing the workspace prefix; none of
# them may hold the step.
test_idle_workspace_returns_immediately() {
  setup
  run_script 0 60
  assert_status 0
  [[ "$(lsof_calls)" -eq 1 ]] || {
    printf 'not ok - an idle workspace was polled %s times\n%s\n' "$(lsof_calls)" "${RUN_OUTPUT}" >&2
    exit 1
  }
  assert_not_contains "${RUN_OUTPUT}" "::warning::" "an idle workspace produced a warning"
  assert_not_contains "${RUN_OUTPUT}" "424240" "the runner hook's caffeinate held the step"
  assert_not_contains "${RUN_OUTPUT}" "424243" "a process merely prefixed xcodebuild held the step"

  teardown
  printf 'ok - an idle workspace does not wait\n'
}

test_waits_for_leftover_process() {
  setup
  run_script 2 60
  assert_status 0
  [[ "$(lsof_calls)" -eq 3 ]] || {
    printf 'not ok - expected 3 polls until the leftover process exited, got %s\n%s\n' "$(lsof_calls)" "${RUN_OUTPUT}" >&2
    exit 1
  }
  assert_contains "${RUN_OUTPUT}" "::warning::" "waiting did not emit a warning"
  assert_contains "${RUN_OUTPUT}" "424242 xcodebuild" "the leftover process was not named"
  assert_not_contains "${RUN_OUTPUT}" "424241" "a process in a sibling directory was treated as inside the workspace"
  assert_contains "${RUN_OUTPUT}" "The workspace is idle." "the end of the wait was not reported"

  teardown
  printf 'ok - a leftover process in the workspace is waited for\n'
}

test_times_out_naming_the_process() {
  setup
  run_script -1 0
  assert_status 1
  assert_contains "${RUN_OUTPUT}" "::error::" "the timeout did not emit an error"
  assert_contains "${RUN_OUTPUT}" "424242 xcodebuild" "the timeout did not name the leftover process"

  teardown
  printf 'ok - a process that never exits fails the step with its name\n'
}

test_fails_without_github_workspace() {
  setup
  RUN_OUTPUT=$(env -u GITHUB_WORKSPACE "${SCRIPT}" 2>&1)
  RUN_STATUS=$?
  [[ "${RUN_STATUS}" -ne 0 ]] || {
    printf 'not ok - the script succeeded without $GITHUB_WORKSPACE\n' >&2
    exit 1
  }
  assert_contains "${RUN_OUTPUT}" "GITHUB_WORKSPACE" "the failure does not name the missing variable"

  teardown
  printf 'ok - a missing $GITHUB_WORKSPACE fails the step\n'
}

test_idle_workspace_returns_immediately
test_waits_for_leftover_process
test_times_out_naming_the_process
test_fails_without_github_workspace
