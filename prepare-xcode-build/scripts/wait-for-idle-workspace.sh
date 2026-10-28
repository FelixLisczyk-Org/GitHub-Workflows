#!/usr/bin/env bash
# Wait until no `xcodebuild` left behind by a previous job still runs inside this
# job's workspace.
#
# Cancelling a job on a persistent runner does not reliably stop the
# `xcodebuild` that fastlane started: it can keep running its tests for minutes
# and then write its result bundle under `log/` in the workspace, which the next
# job on this runner reuses. `git clean` alone cannot cover that: it succeeds
# while the orphan is still testing, and the bundle reappears later, so `scan`
# fails with "Existing file at -resultBundlePath" before building anything.
#
# Killing Xcode processes is off the table on a machine that runs CI next to
# agent work under the same user (PL-377), so this only waits. The orphan is
# identified by its name and working directory: fastlane runs `xcodebuild` from
# the repository root. Only `xcodebuild` counts, because other processes
# legitimately run there: the runner's job hooks start `caffeinate` from the
# workspace, both for the current job and for two minutes after the previous
# one. No step of this job has started an `xcodebuild` yet at this point.
#
# Times out with a failure that names the processes rather than letting the
# test step fail later on a collision whose cause is no longer visible.
set -euo pipefail

workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
timeout_seconds="${WORKSPACE_IDLE_TIMEOUT_SECONDS:-1200}"
poll_seconds="${WORKSPACE_IDLE_POLL_SECONDS:-15}"

# Prints "<pid> <command>" for every `xcodebuild` whose working directory is the
# workspace or lies inside it.
workspace_processes() {
  local listing
  # `lsof` exits 1 when no process matches, which is the normal idle case.
  listing=$(lsof -a -c xcodebuild -d cwd -F pcn 2>/dev/null) || true
  awk -v workspace="$workspace" '
    /^p/ { pid = substr($0, 2); next }
    /^c/ { command = substr($0, 2); next }
    /^n/ {
      path = substr($0, 2)
      if (command == "xcodebuild" && (path == workspace || index(path, workspace "/") == 1)) print pid, command
    }
  ' <<<"$listing"
}

deadline=$((SECONDS + timeout_seconds))
announced=false
while busy=$(workspace_processes) && [[ -n "$busy" ]]; do
  if ((SECONDS >= deadline)); then
    echo "::error::A previous job's xcodebuild is still running in the workspace after ${timeout_seconds}s:"
    printf '%s\n' "$busy"
    exit 1
  fi
  if [[ "$announced" == false ]]; then
    echo "::warning::A previous job's xcodebuild is still running in the workspace; waiting for it to exit."
    announced=true
  fi
  printf '%s\n' "$busy"
  sleep "$poll_seconds"
done

if [[ "$announced" == true ]]; then
  echo "The workspace is idle."
fi
