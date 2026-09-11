#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT

prepare_script=$(ruby -ryaml -e '
  steps = YAML.load_file(ARGV[0])["runs"]["steps"]
  puts steps.find { |step| step["name"] == "Prepare Uploaded Build Identity" }.fetch("run")
' "${REPO_ROOT}/xcode-build-app/action.yml")
prepare_script=${prepare_script//'${{ inputs.platform }}'/ios}

rm() {
  printf 'not ok - the runner rm function was invoked\n' >&2
  return 5
}
export -f rm

run_prepare() {
  local fixture_dir=$1
  local identity_file="${fixture_dir}/xcode-build-app-123-build-ios.txt"
  local github_env="${fixture_dir}/github-env"

  printf 'stale\n' > "$identity_file"
  RUNNER_TEMP="$fixture_dir" GITHUB_RUN_ID=123 GITHUB_JOB=build GITHUB_ENV="$github_env" \
    bash -eo pipefail -c "$prepare_script"

  [[ ! -e "$identity_file" ]] || {
    printf 'not ok - stale upload identity was not removed\n' >&2
    exit 1
  }
  grep -Fqx "XCODE_BUILD_APP_IDENTITY_FILE=$identity_file" "$github_env" || {
    printf 'not ok - upload identity path was not exported\n' >&2
    exit 1
  }

  : > "$github_env"
  RUNNER_TEMP="$fixture_dir" GITHUB_RUN_ID=123 GITHUB_JOB=build GITHUB_ENV="$github_env" \
    bash -eo pipefail -c "$prepare_script"
}

fixture_dir=$(mktemp -d)
trap '/bin/rm -rf "$fixture_dir"' EXIT
run_prepare "$fixture_dir"

printf 'ok - upload identity cleanup bypasses the runner rm function\n'
