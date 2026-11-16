#!/usr/bin/env bash
# Run one build command through xcodebuildmcp-queue when this machine has it, directly otherwise.
#
# The self-hosted runner shares its build machine with coding agents whose builds go through
# xcodebuildmcp-queue. A CI build outside the queue runs alongside whatever the queue admitted,
# and both slow down (PL-480). Cloud runners have no queue, so there the command runs as is.
#
# The queue wait gets its own budget, one execution timeout (90 minutes) plus five minutes.
# `~/actions-runner/_work` is a priority folder, so a CI step should only ever wait for the one
# job already running; a wait past that budget fails with exit code 71 (queue timeout), which
# names the queue as the cause instead of leaving the job to hit its `timeout-minutes`.
# A step can still set XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS itself.
#
# `exec` keeps the queue proxy as this step's process: when a run is cancelled, its exit is what
# tells the queue to cancel the job and terminate the build's whole process tree.
#
# Usage: queued.sh <executable> [arguments...]
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: queued.sh <executable> [arguments...]" >&2
  exit 64
fi

if command -v xcodebuildmcp-queue >/dev/null 2>&1; then
  export XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS="${XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS:-5700}"
  exec xcodebuildmcp-queue queue run -- "$@"
fi

exec "$@"
