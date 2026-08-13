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
assert_count 3 'FASTLANE_REUSE_GENERATED_PROJECT=${{ inputs.reuse_generated_project }} bundle exec fastlane'

printf 'ok - reuse_generated_project is forwarded to all Fastlane invocations\n'
