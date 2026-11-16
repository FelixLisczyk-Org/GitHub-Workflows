#!/usr/bin/env bash
set -u -o pipefail

ACTION_FILE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/action.yml
readonly ACTION_FILE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  local expected=$1
  grep -Fq -- "$expected" "${ACTION_FILE}" || fail "action.yml is missing ${expected@Q}"
}

assert_count() {
  local expected=$1
  local fragment=$2
  local actual
  actual=$(grep -F -c -- "$fragment" "${ACTION_FILE}" || true)
  [[ "${actual}" -eq "${expected}" ]] || fail "expected ${expected} occurrences of ${fragment@Q}, got ${actual}"
}

assert_contains 'reuse_generated_project:'
assert_contains 'default: false'
assert_contains 'same checkout/job'
# The flag travels in each step's `env:` rather than as a command prefix, so it reaches Fastlane
# through the queue proxy, which forwards the step's environment but runs a single executable.
assert_count 3 'FASTLANE_REUSE_GENERATED_PROJECT: ${{ inputs.reuse_generated_project }}'
assert_count 3 'queued.sh bundle exec fastlane'
assert_count 0 'FASTLANE_REUSE_GENERATED_PROJECT=${{'

printf 'ok - reuse_generated_project is forwarded to all Fastlane invocations\n'
