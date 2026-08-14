#!/usr/bin/env bash
# Marks the start of a build/test invocation so that `check-build-errors.py` and
# `show-test-failures.py` analyse only the logs that invocation writes.
#
# Every platform step in a job shares one `log` directory and nothing clears it between
# steps, so without this marker a *passing* platform's log can drive another platform's
# failure recovery. Run this immediately before each Fastlane/xcodebuild invocation,
# including every retry, so each analysis sees only its own attempt.
#
# `date +%s` is deliberately not used: it floors to whole seconds, and back-to-back
# platform steps write their logs well inside one second of each other.
set -euo pipefail

epoch=$(python3 -c 'import time; print(time.time())')
echo "CI_LOG_SCOPE_EPOCH=${epoch}" >> "${GITHUB_ENV}"
echo "Scoping log analysis to entries modified at or after ${epoch}"
