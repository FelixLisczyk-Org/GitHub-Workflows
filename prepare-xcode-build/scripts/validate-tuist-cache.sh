#!/usr/bin/env bash
# Validate the local Tuist cache that persistent self-hosted runners keep
# between jobs (PL-371). The cache is trustworthy only while it carries a
# marker written by a successful job (PL-234), so this script drops the cache
# whenever it cannot be validated against Tuist/Package.resolved, and always
# invalidates the marker afterwards.
#
# `rm` is invoked through `command` throughout: the calling step uses a login
# shell, whose profile redefines `rm` as a wrapper around `trash`. Unlike
# `rm -rf`, `trash` fails on paths that do not exist, and it would move
# regenerable build artifacts into the runner's Trash instead of deleting them.
set -euo pipefail

cache_directory="Tuist/.build"
marker="$cache_directory/.package-resolved-hash"

# Nothing cached locally: a fresh or reset runner, or a repository that
# resolves its packages outside Tuist/ (Swift packages use the root
# Package.swift and never create this directory). The build recreates whatever
# it needs, so there is nothing to validate or invalidate.
if [[ ! -d "$cache_directory" ]]; then
  exit 0
fi

if [[ ! -f "Tuist/Package.resolved" ]]; then
  echo "Tuist/Package.resolved is missing; clearing the local Tuist cache."
  command rm -rf "$cache_directory"
  if [[ -e "$cache_directory" ]]; then
    echo "Unable to clear local Tuist cache at $cache_directory" >&2
    exit 1
  fi
  exit 0
fi

package_hash=$(git hash-object Tuist/Package.resolved)
if [[ ! -f "$marker" ]] || [[ "$(<"$marker")" != "$package_hash" ]]; then
  echo "Tuist cache is missing a valid Package.resolved marker; clearing it."
  command rm -rf "$cache_directory"
  if [[ -e "$cache_directory" ]]; then
    echo "Unable to clear stale Tuist cache at $cache_directory" >&2
    exit 1
  fi
  exit 0
fi

# A cache is authoritative only after a successful job writes this marker.
command rm -f "$marker"
if [[ -e "$marker" ]]; then
  echo "Unable to invalidate Tuist cache marker at $marker" >&2
  exit 1
fi
