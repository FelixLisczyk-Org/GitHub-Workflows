#!/usr/bin/env bash
# Wait until no process left behind by a previous job still runs inside this
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
# identified by its working directory: fastlane runs `xcodebuild` from the
# repository root, and no other process on the machine works inside a runner's
# `_work` directory. The job's own processes (this script's ancestors, and the
# `lsof` it starts) are excluded.
#
# Times out with a failure that names the processes rather than letting the
# test step fail later on a collision whose cause is no longer visible.
set -euo pipefail

workspace="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is not set}"
timeout_seconds="${WORKSPACE_IDLE_TIMEOUT_SECONDS:-1200}"
poll_seconds="${WORKSPACE_IDLE_POLL_SECONDS:-15}"

ancestor_pids() {
  local pid=$$
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    printf '%s ' "$pid"
    pid=$(ps -o ppid= -p "$pid" | tr -d ' ') || break
  done
}

own_pids=$(ancestor_pids)

# Prints "<pid> <command>" for every foreign process whose working directory is
# the workspace or lies inside it.
workspace_processes() {
  local listing
  # `lsof` exits 1 when some process could not be inspected, which is normal.
  listing=$(lsof -a -d cwd -F pRcn 2>/dev/null) || true
  # The subshells and `lsof` this script forks run in the workspace too, so every
  # descendant of this script is skipped, found through the parent links in the
  # listing itself (it covers every process, since every process has a cwd).
  awk -v workspace="$workspace" -v own="$own_pids" -v self="$$" '
    BEGIN { count = split(own, list, " "); for (i = 1; i <= count; i++) skip[list[i]] = 1 }
    /^p/ { pid = substr($0, 2); next }
    /^R/ { parent[pid] = substr($0, 2); next }
    /^c/ { command[pid] = substr($0, 2); next }
    /^n/ { path[pid] = substr($0, 2); next }
    END {
      for (pid in path) {
        if (pid in skip) continue
        if (path[pid] != workspace && index(path[pid], workspace "/") != 1) continue
        ancestor = parent[pid]
        while (ancestor != "" && ancestor != self && ancestor > 1) ancestor = parent[ancestor]
        if (ancestor == self) continue
        print pid, command[pid]
      }
    }
  ' <<<"$listing"
}

deadline=$((SECONDS + timeout_seconds))
announced=false
while busy=$(workspace_processes) && [[ -n "$busy" ]]; do
  if ((SECONDS >= deadline)); then
    echo "::error::Processes from a previous job are still running in the workspace after ${timeout_seconds}s:"
    printf '%s\n' "$busy"
    exit 1
  fi
  if [[ "$announced" == false ]]; then
    echo "::warning::A previous job left processes running in the workspace; waiting for them to exit."
    announced=true
  fi
  printf '%s\n' "$busy"
  sleep "$poll_seconds"
done

if [[ "$announced" == true ]]; then
  echo "The workspace is idle."
fi
