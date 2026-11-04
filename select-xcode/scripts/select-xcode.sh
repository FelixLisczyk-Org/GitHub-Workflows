#!/usr/bin/env bash
# Select the Xcode version for this job and export it as `DEVELOPER_DIR` (PL-374).
#
# This used to run `sudo xcode-select -s`, which changes the developer directory
# machine-wide: it is global state on the Mac, not state belonging to the job.
# With several Xcode installations present (a stable one plus several betas) two
# concurrent jobs fight over it — a `beta` job and a `main` job each select their
# own Xcode and the second one silently changes the toolchain out from under the
# first, mid-build.
#
# `DEVELOPER_DIR` is inherited by the job's process tree instead, which
# `xcodebuild`, `xcrun` and fastlane all honour, and it disappears with the job.
# It is also why `xcode-restore-version` no longer exists: there is no
# machine-wide state left to put back.
#
# `XCODE_SEARCH_DIR` exists so the selection can be exercised against fake Xcode
# bundles in tests; the action always uses the default.
set -euo pipefail

search_dir="${XCODE_SEARCH_DIR:-/Applications}"
use_beta_xcode="${USE_BETA_XCODE:-false}"
env_file="${GITHUB_ENV:?GITHUB_ENV is not set}"

# `sort -V` compares the version numbers, so `Xcode-27.0.0-Beta-10` sorts after
# `Xcode-27.0.0-Beta-9`; within a group the last entry is therefore the newest.
#
# A name match alone is not enough: other apps share the prefix (the Xcodes
# version manager installs `/Applications/Xcodes.app`), and as the last entry in
# sort order such an app would win the selection. Only bundles that contain a
# developer directory count as Xcode installations.
all_xcode_bundles() {
  local bundle
  if [[ ! -d "$search_dir" ]]; then
    return 0
  fi
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    if [[ -d "$bundle/Contents/Developer" ]]; then
      printf '%s\n' "$bundle"
    else
      echo "Notice: Skipping $bundle, it is not an Xcode installation: Contents/Developer is missing" >&2
    fi
  done < <(
    find "$search_dir" -maxdepth 1 \
      \( -name "Xcode.app" -o -name "Xcode-*.app" -o -name "Xcode *.app" \) \
      2>/dev/null | sort -V || true
  )
}

# Prints the selected bundle, or prints nothing when no bundle qualifies. Betas
# and stable releases are tracked separately because the fallback from a missing
# beta is to the newest stable one, not to the newest bundle overall.
select_bundle() {
  local bundle
  local newest_beta=""
  local newest_stable=""

  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    if [[ "$bundle" == *"Beta"* ]]; then
      newest_beta="$bundle"
    else
      newest_stable="$bundle"
    fi
  done < <(all_xcode_bundles)

  if [[ "$use_beta_xcode" == "true" ]]; then
    if [[ -n "$newest_beta" ]]; then
      printf '%s\n' "$newest_beta"
      return 0
    fi
    echo "Notice: No Beta Xcode version found, falling back to stable" >&2
  fi

  if [[ -n "$newest_stable" ]]; then
    printf '%s\n' "$newest_stable"
  fi
}

xcode_bundle=$(select_bundle)
if [[ -z "$xcode_bundle" ]]; then
  echo "::error title=No Xcode found::No suitable Xcode version was found under $search_dir"
  exit 1
fi

# `xcode-select -s` accepted the bundle itself and appended `Contents/Developer`
# internally; `DEVELOPER_DIR` has to name that directory outright.
developer_dir="$xcode_bundle/Contents/Developer"

echo "Selecting Xcode: $xcode_bundle"
echo "DEVELOPER_DIR=$developer_dir" >> "$env_file"

# `$GITHUB_ENV` only reaches later steps, so the current shell has to be given the
# value explicitly to prove here that the selection resolves to a usable Xcode.
DEVELOPER_DIR="$developer_dir" xcodebuild -version
