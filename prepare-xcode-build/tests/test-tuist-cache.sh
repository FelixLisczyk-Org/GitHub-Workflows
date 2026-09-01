#!/usr/bin/env bash
# Covers project-local Tuist dependency-state handling in `prepare-xcode-build`:
# workspace cleanup preserves Tuist/.build without treating it as the global
# binary module cache, and `scripts/validate-tuist-cache.sh` validates its marker.
#
# The action runs its steps in a login shell, where the user profile redefines
# `rm` as a wrapper around `trash`. The harness exports an equivalent wrapper so
# the script is exercised under the same conditions as CI; a regression to a
# bare `rm` on a missing path fails these tests instead of the nightly runs.
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly FAKE_BIN="${ACTION_ROOT}/tests/fakes"
readonly SCRIPT="${ACTION_ROOT}/scripts/validate-tuist-cache.sh"
readonly CACHE_DIRECTORY="Tuist/.build"
readonly MARKER="${CACHE_DIRECTORY}/.package-resolved-hash"

RUN_OUTPUT=""
RUN_STATUS=0
TEST_TMP=""
WORKSPACE=""

# Mirrors the `rm` function in ~/.shared_aliases: drop the flags, hand the paths
# to `trash`. Exported so the script under test inherits it, exactly as it would
# inherit the profile definition in a `bash -l` step.
rm() {
  local args=()
  for arg in "$@"; do
    [[ "$arg" =~ ^-[rRfiv]+$ || "$arg" == "--" ]] && continue
    args+=("$arg")
  done
  command trash "${args[@]}"
}
export -f rm

setup() {
  TEST_TMP=$(mktemp -d)
}

teardown() {
  /bin/rm -rf "${TEST_TMP}"
}

# A git repository is required: the script hashes Tuist/Package.resolved with
# `git hash-object`.
make_workspace() {
  WORKSPACE="${TEST_TMP}/workspace"
  mkdir -p "${WORKSPACE}"
  cd "${WORKSPACE}" || return 1
  git init -q
  git config user.email test@example.com
  git config user.name test
}

write_manifest() {
  mkdir -p Tuist
  printf '%s\n' "${1-{\"pins\":[]\}}" >Tuist/Package.resolved
}

write_cache() {
  mkdir -p "${CACHE_DIRECTORY}/checkouts/Package"
  printf '%s\n' cache >"${CACHE_DIRECTORY}/checkouts/Package/state"
}

write_marker() {
  printf '%s\n' "$1" >"${MARKER}"
}

run_script() {
  RUN_OUTPUT=$(
    FAKE_TRASH_STATE_DIR="${TEST_TMP}" \
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

assert_exists() {
  if [[ ! -e "$1" ]]; then
    printf 'Expected %q to exist.\n' "$1" >&2
    return 1
  fi
}

assert_absent() {
  if [[ -e "$1" ]]; then
    printf 'Expected %q to be gone.\n' "$1" >&2
    return 1
  fi
}

assert_no_trash_calls() {
  if [[ -f "${TEST_TMP}/trash.log" ]]; then
    printf 'Expected deletions to bypass the profile trash wrapper. Calls:\n' >&2
    cat "${TEST_TMP}/trash.log" >&2
    return 1
  fi
}

# A Swift package repository: Tuist reads the root Package.swift, so Tuist/
# never exists. This is the layout that broke every Kit package.
test_package_layout_without_tuist_directory_is_a_no_op() {
  make_workspace || return 1
  printf '%s\n' 'import PackageDescription' >Package.swift

  run_script
  assert_status 0 || return 1
  assert_absent Tuist || return 1
  assert_no_trash_calls
}

# PL-371: a new or reset runner has no dependency state yet and must still build.
test_fresh_runner_without_cache_is_a_no_op() {
  make_workspace || return 1
  write_manifest

  run_script
  assert_status 0 || return 1
  assert_exists Tuist/Package.resolved || return 1
  assert_no_trash_calls
}

test_cache_without_manifest_is_cleared() {
  make_workspace || return 1
  write_cache

  run_script
  assert_status 0 || return 1
  assert_contains 'Tuist/Package.resolved is missing' || return 1
  assert_absent "${CACHE_DIRECTORY}" || return 1
  assert_no_trash_calls
}

test_cache_without_marker_is_cleared() {
  make_workspace || return 1
  write_manifest
  write_cache

  run_script
  assert_status 0 || return 1
  assert_contains 'missing a valid Package.resolved marker' || return 1
  assert_absent "${CACHE_DIRECTORY}" || return 1
  assert_no_trash_calls
}

test_cache_with_stale_marker_is_cleared() {
  make_workspace || return 1
  write_manifest
  write_cache
  write_marker stale

  run_script
  assert_status 0 || return 1
  assert_contains 'missing a valid Package.resolved marker' || return 1
  assert_absent "${CACHE_DIRECTORY}" || return 1
  assert_no_trash_calls
}

# PL-234: the marker is dropped up front, so a job that fails or is cancelled
# leaves dependency state the next job refuses to trust.
test_valid_marker_is_invalidated_and_cache_preserved() {
  make_workspace || return 1
  write_manifest
  write_cache
  write_marker "$(git hash-object Tuist/Package.resolved)"

  run_script
  assert_status 0 || return 1
  assert_exists "${CACHE_DIRECTORY}/checkouts/Package/state" || return 1
  assert_absent "${MARKER}" || return 1
  assert_no_trash_calls
}

# PL-371: checkout's broad clean would drop dependency state, so the action resets and
# cleans by hand. Other ignored output must still go.
test_workspace_cleanup_preserves_only_the_cache() {
  make_workspace || return 1
  write_manifest
  git add Tuist/Package.resolved
  git commit -qm initial

  write_cache
  mkdir -p build Derived
  printf '%s\n' ignored >build/output
  printf '%s\n' ignored >Derived/output
  printf '%s\n' untracked >workspace-file
  printf '%s\n' changed >Tuist/Package.resolved

  git reset --hard >/dev/null
  git clean -ffdx -e Tuist/.build >/dev/null

  assert_exists Tuist/Package.resolved || return 1
  assert_exists "${CACHE_DIRECTORY}/checkouts/Package/state" || return 1
  assert_absent build || return 1
  assert_absent Derived || return 1
  assert_absent workspace-file
}

main() {
  local failed=0
  local -a tests=(
    test_package_layout_without_tuist_directory_is_a_no_op
    test_fresh_runner_without_cache_is_a_no_op
    test_cache_without_manifest_is_cleared
    test_cache_without_marker_is_cleared
    test_cache_with_stale_marker_is_cleared
    test_valid_marker_is_invalidated_and_cache_preserved
    test_workspace_cleanup_preserves_only_the_cache
  )

  setup
  trap teardown EXIT

  for test in "${tests[@]}"; do
    /bin/rm -rf "${TEST_TMP:?}"/*
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
