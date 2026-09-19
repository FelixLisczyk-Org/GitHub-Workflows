#!/usr/bin/env bash
# Covers `select-xcode/scripts/select-xcode.sh`: the Xcode used by a job is chosen
# per job and exported as `DEVELOPER_DIR`, never switched machine-wide (PL-374).
#
# The bundles are fake directories under a temporary search root. What matters is
# what the script does with the *selection* — which bundle it picks, which path it
# exports, and that the job's own `xcodebuild` resolves against it — not that it
# can read the runner's /Applications.
#
# `xcode-select` is shadowed by a fake that records calls: reaching it would mean
# the machine-wide switch came back, which is the regression this guards.
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly FAKE_BIN="${ACTION_ROOT}/tests/fakes"
readonly SCRIPT="${ACTION_ROOT}/scripts/select-xcode.sh"

RUN_OUTPUT=""
RUN_STATUS=0
TEST_TMP=""
SEARCH_DIR=""
ENV_FILE=""

setup() {
  TEST_TMP=$(mktemp -d)
  reset_fixtures
}

# The harness wipes `TEST_TMP` between tests, so anything a test needs to exist
# up front has to be recreated here rather than only once in `setup`.
reset_fixtures() {
  SEARCH_DIR="${TEST_TMP}/Applications"
  ENV_FILE="${TEST_TMP}/github_env"
  mkdir -p "${SEARCH_DIR}"
  : >"${ENV_FILE}"
}

teardown() {
  /bin/rm -rf "${TEST_TMP}"
}

# A bundle is only a real installation once it has the developer directory in it.
make_xcode() {
  mkdir -p "${SEARCH_DIR}/${1}/Contents/Developer"
}

make_bundle_without_developer_directory() {
  mkdir -p "${SEARCH_DIR}/${1}/Contents"
}

run_script() {
  local use_beta_xcode="${1:-false}"
  RUN_OUTPUT=$(
    XCODE_SEARCH_DIR="${SEARCH_DIR}" \
    GITHUB_ENV="${ENV_FILE}" \
    USE_BETA_XCODE="${use_beta_xcode}" \
    FAKE_XCODE_STATE_DIR="${TEST_TMP}" \
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

assert_developer_dir() {
  local expected="DEVELOPER_DIR=$1"
  if ! grep -Fxq "${expected}" "${ENV_FILE}"; then
    printf 'Expected %q in the env file. Contents:\n' "${expected}" >&2
    cat "${ENV_FILE}" >&2
    return 1
  fi
}

assert_no_developer_dir() {
  if grep -q '^DEVELOPER_DIR=' "${ENV_FILE}"; then
    printf 'Expected no DEVELOPER_DIR to be exported. Contents:\n' >&2
    cat "${ENV_FILE}" >&2
    return 1
  fi
}

assert_xcodebuild_ran_under() {
  local expected=$1
  local log="${TEST_TMP}/xcodebuild.log"
  if [[ ! -f "${log}" ]]; then
    printf 'Expected the selection to be verified with xcodebuild, but it never ran.\n' >&2
    return 1
  fi
  if ! grep -Fxq "${expected}" "${log}"; then
    printf 'Expected xcodebuild to run under %q. Recorded values:\n' "${expected}" >&2
    cat "${log}" >&2
    return 1
  fi
}

assert_no_machine_wide_switch() {
  local log="${TEST_TMP}/xcode-select.log"
  if [[ -f "${log}" ]]; then
    printf 'Expected xcode-select not to be invoked. Calls:\n' >&2
    cat "${log}" >&2
    return 1
  fi
}

test_newest_stable_is_selected_by_default() {
  make_xcode "Xcode-26.5.0.app" || return 1
  make_xcode "Xcode-26.6.0.app" || return 1

  run_script
  assert_status 0 || return 1
  assert_contains "Selecting Xcode: ${SEARCH_DIR}/Xcode-26.6.0.app" || return 1
  assert_developer_dir "${SEARCH_DIR}/Xcode-26.6.0.app/Contents/Developer" || return 1
  assert_xcodebuild_ran_under "${SEARCH_DIR}/Xcode-26.6.0.app/Contents/Developer" || return 1
  assert_no_machine_wide_switch
}

# The bug PL-374 fixes: a job on `main` must not be dragged onto a beta just
# because a concurrent job on `beta` selected one.
test_beta_is_ignored_unless_requested() {
  make_xcode "Xcode-26.6.0.app" || return 1
  make_xcode "Xcode-27.0.0-Beta-2.app" || return 1

  run_script
  assert_status 0 || return 1
  assert_developer_dir "${SEARCH_DIR}/Xcode-26.6.0.app/Contents/Developer" || return 1
  assert_no_machine_wide_switch
}

# Version-aware ordering: `Beta-10` is newer than `Beta-2`, though it sorts
# earlier as a plain string.
test_newest_beta_is_selected_when_requested() {
  make_xcode "Xcode-26.6.0.app" || return 1
  make_xcode "Xcode-27.0.0-Beta-2.app" || return 1
  make_xcode "Xcode-27.0.0-Beta-10.app" || return 1

  run_script true
  assert_status 0 || return 1
  assert_developer_dir "${SEARCH_DIR}/Xcode-27.0.0-Beta-10.app/Contents/Developer" || return 1
  assert_no_machine_wide_switch
}

test_missing_beta_falls_back_to_stable() {
  make_xcode "Xcode-26.6.0.app" || return 1

  run_script true
  assert_status 0 || return 1
  assert_contains "No Beta Xcode version found" || return 1
  assert_developer_dir "${SEARCH_DIR}/Xcode-26.6.0.app/Contents/Developer" || return 1
  assert_no_machine_wide_switch
}

# No install at all must fail loudly rather than let the job inherit whatever the
# machine happens to have selected.
test_no_xcode_is_an_error() {
  run_script
  assert_status 1 || return 1
  assert_contains "::error title=No Xcode found::No suitable Xcode version was found" || return 1
  assert_no_developer_dir || return 1
  assert_no_machine_wide_switch
}

# A search root that does not exist must not fail `find` under `set -e`; it is the
# same situation as an empty one and is reported the same way.
test_missing_search_root_is_an_error() {
  SEARCH_DIR="${TEST_TMP}/nowhere"

  run_script
  assert_status 1 || return 1
  assert_contains "No suitable Xcode version was found" || return 1
  assert_no_developer_dir
}

test_install_without_developer_directory_is_rejected() {
  make_bundle_without_developer_directory "Xcode-26.6.0.app" || return 1

  run_script
  assert_status 1 || return 1
  assert_contains "Contents/Developer is missing" || return 1
  assert_no_developer_dir || return 1
  assert_no_machine_wide_switch
}

test_unrelated_applications_are_not_selected() {
  make_xcode "Safari.app" || return 1
  make_xcode "Instruments.app" || return 1

  run_script
  assert_status 1 || return 1
  assert_contains "No suitable Xcode version was found" || return 1
  assert_no_developer_dir || return 1
  assert_no_machine_wide_switch
}

# `$GITHUB_ENV` is shared with every other step that writes to it, so the
# selection has to append rather than replace the file.
test_existing_env_file_contents_are_survived() {
  make_xcode "Xcode-26.6.0.app" || return 1
  printf '%s\n' "SOME_OTHER_VARIABLE=kept" >"${ENV_FILE}"

  run_script
  assert_status 0 || return 1
  if ! grep -Fxq "SOME_OTHER_VARIABLE=kept" "${ENV_FILE}"; then
    printf 'Expected the pre-existing env file contents to survive. Contents:\n' >&2
    cat "${ENV_FILE}" >&2
    return 1
  fi
  assert_developer_dir "${SEARCH_DIR}/Xcode-26.6.0.app/Contents/Developer"
}

main() {
  local failed=0
  local -a tests=(
    test_newest_stable_is_selected_by_default
    test_beta_is_ignored_unless_requested
    test_newest_beta_is_selected_when_requested
    test_missing_beta_falls_back_to_stable
    test_no_xcode_is_an_error
    test_missing_search_root_is_an_error
    test_install_without_developer_directory_is_rejected
    test_unrelated_applications_are_not_selected
    test_existing_env_file_contents_are_survived
  )

  setup
  trap teardown EXIT

  for test in "${tests[@]}"; do
    /bin/rm -rf "${TEST_TMP:?}"/*
    reset_fixtures
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
