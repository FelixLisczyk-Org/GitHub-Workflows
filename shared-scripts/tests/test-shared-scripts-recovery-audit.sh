#!/usr/bin/env bash
# Asserts PL-377's audit contract: no script in shared-scripts performs machine-wide
# destructive recovery. The Studio runs one CI build beside agent and manual work as
# the same user, so CI recovery may mutate only the current job's workspace and the
# CI-owned simulator device — never shared developer applications, global simulator
# services, or home-level caches that every process on the machine depends on.
#
# The patterns are command-shaped on purpose: prose in comments and docstrings that
# documents *why* these operations are banned must not trip the audit.
set -u -o pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# The retired script deleted the global SwiftPM cache and the workspace DerivedData
# with a project-name glob; it has no callers and must stay gone.
[[ ! -e "${SCRIPTS}/clear-xcode-cache.sh" ]] ||
  fail "clear-xcode-cache.sh still exists"
printf 'ok - the retired clear-xcode-cache.sh stays gone\n'

# Every pattern is an operation that would mutate state shared by all processes on
# the Studio. Workspace-owned cleanup (`rm -rf Tuist/.build`, the workspace-scoped
# DerivedData script) intentionally does not match any of them.
patterns=(
  'killall'                                # broad process termination
  'osascript'                              # quitting shared developer applications
  'quit app'
  'rm -rf ~'                               # home-level deletions
  'rm -rf "\$HOME'                         # home-level deletions, quoted
  'rm -rf .*\$HOME'                        # home-level deletions, expanded
  'rm -rf .*\.cache/tuist'                 # the global Tuist binary cache
  'rm -rf .*org\.swift\.swiftpm'           # the global SwiftPM cache
  'rm -rf .*CoreSimulator'                 # the global CoreSimulator state
  'xcode-select'                           # machine-global developer-dir switching
  'defaults write'                         # machine-global preference mutation
  'defaults delete'
  'launchctl'                              # machine-global service control
)

offending=$(grep -H -n -E "$(IFS='|'; echo "${patterns[*]}")" \
  "${SCRIPTS}"/*.py "${SCRIPTS}"/*.sh 2>/dev/null | grep -v '/tests/')
if [[ -n "${offending}" ]]; then
  printf '%s\n' "${offending}" >&2
  fail "a shared script still performs machine-wide destructive recovery"
fi
printf 'ok - no shared script performs machine-wide destructive recovery\n'

# The simulator recovery path must act device-scoped through simctl, not by killing
# services or wiping shared state.
if ! grep -q 'simctl' "${SCRIPTS}/check-build-errors.py"; then
  fail "check-build-errors.py no longer recovers simulators through device-scoped simctl"
fi
printf 'ok - simulator recovery goes through device-scoped simctl\n'

printf 'all machine-wide recovery audit checks passed\n'
