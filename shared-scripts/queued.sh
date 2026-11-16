#!/usr/bin/env bash
# Run one build command through xcodebuildmcp-queue when this machine has it, directly otherwise.
#
# The self-hosted runner shares its build machine with coding agents whose builds go through
# xcodebuildmcp-queue. A CI build outside the queue runs alongside whatever the queue admitted,
# and both slow down (PL-480). GitHub-hosted runners have no queue, so there the command runs as
# is; a self-hosted runner without the queue is an error (see below).
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

# Only a GitHub-hosted runner may build without the queue. A self-hosted runner without it
# (not installed, or missing from PATH) would quietly build next to the agents' queued jobs
# again, which is exactly the contention this wrapper exists to prevent, so it fails loudly.
# 72 is the queue's own "unavailable" exit code.
if [[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]]; then
  echo "::error::xcodebuildmcp-queue is not on PATH on this self-hosted runner; refusing to build outside the queue." >&2
  exit 72
fi

exec "$@"
