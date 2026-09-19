#!/usr/bin/env bash
# Covers `prepare-xcode-build/scripts/isolate-git-config.sh` (PL-378): the job's
# git configuration lives in a file under `$RUNNER_TEMP` that is exported as
# `GIT_CONFIG_GLOBAL`, so the SSH redirect for Swift Package checkouts never
# reaches `~/.gitconfig` and needs no cleanup step.
#
# The step runs in a login shell, where the user profile redefines `rm` as a
# wrapper around `trash`, so the harness exports an equivalent wrapper: a
# regression to a bare `rm` on a missing path fails here instead of in CI.
set -u -o pipefail

ACTION_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ACTION_ROOT
readonly SCRIPT="${ACTION_ROOT}/scripts/isolate-git-config.sh"
readonly REDIRECT_KEY='url.git@github.com:.insteadOf'
# `git config --list` reports the key lowercased, so the comparison uses that form.
readonly REDIRECT_KEY_LISTED='url.git@github.com:.insteadof'

RUN_OUTPUT=""
RUN_STATUS=0
TEST_TMP=""
RUNNER_TEMP_DIR=""
ENV_FILE=""
HOME_DIR=""

# Mirrors the `rm` function in ~/.shared_aliases: drop the flags, hand the paths
# to `trash`. Exported so the script under test inherits it, exactly as it would
# inherit the profile definition in a `bash -l` step.
rm() {
  local args=()
  for arg in "$@"; do
    [[ "$arg" =~ ^-[rRfiv]+$ || "$arg" == "--" ]] && continue
    args+=("$arg")
  done
  command trash "${args[@]}"
}
export -f rm

setup() {
  TEST_TMP=$(mktemp -d)
  RUNNER_TEMP_DIR="${TEST_TMP}/runner-temp"
  ENV_FILE="${TEST_TMP}/github-env"
  HOME_DIR="${TEST_TMP}/home"
  mkdir -p "${RUNNER_TEMP_DIR}" "${HOME_DIR}"
  : >"${ENV_FILE}"
}

teardown() {
  /bin/rm -rf "${TEST_TMP}"
}

# The user's global config is what the job must not touch, so it starts out with
# a setting of its own: any write the script makes through `--global` would land
# here and be visible to every other process on the machine.
write_user_gitconfig() {
  printf '[user]\n\tname = Studio Owner\n[credential]\n\thelper = osxkeychain\n' >"${HOME_DIR}/.gitconfig"
}

run_script() {
  RUN_OUTPUT=$(
    HOME="${HOME_DIR}" \
    RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
    GITHUB_ENV="${ENV_FILE}" \
      "${SCRIPT}" 2>&1
  )
  RUN_STATUS=$?
}

assert_status() {
  local expected=$1
  [[ "${RUN_STATUS}" -eq "${expected}" ]] || {
    printf 'not ok - expected exit status %s, got %s\n%s\n' "${expected}" "${RUN_STATUS}" "${RUN_OUTPUT}" >&2
    exit 1
  }
}

assert_contains() {
  local haystack=$1
  local needle=$2
  local description=$3
  [[ "${haystack}" == *"${needle}"* ]] || {
    printf 'not ok - %s\n%s\n' "${description}" "${haystack}" >&2
    exit 1
  }
}

# The keys the per-job file itself defines. `git config --list` is not usable
# here: it merges repo-local, system and global scope into one view, and the test
# runs inside the GitHub-Workflows repository. `--file` reads exactly that file,
# and has to come *before* the subcommand — a trailing `--file` is ignored and
# git reads the real global config instead, which is the leak this ticket is
# about.
per_job_keys() {
  git config --file "$1" --list --name-only | LC_ALL=C sort
}

# The redirect as git resolves it from the per-job file alone.
per_job_redirect() {
  git config --file "$1" --get "${REDIRECT_KEY}"
}

exported_config_path() {
  local line
  line=$(grep -F 'GIT_CONFIG_GLOBAL=' "${ENV_FILE}" | tail -n 1) || return 1
  printf '%s\n' "${line#GIT_CONFIG_GLOBAL=}"
}

test_writes_redirect_into_runner_temp() {
  setup
  write_user_gitconfig
  run_script
  assert_status 0

  local config_path
  config_path=$(exported_config_path) || {
    printf 'not ok - the script did not export GIT_CONFIG_GLOBAL\n' >&2
    exit 1
  }

  [[ "${config_path}" == "${RUNNER_TEMP_DIR}/"* ]] || {
    printf 'not ok - GIT_CONFIG_GLOBAL points outside $RUNNER_TEMP: %s\n' "${config_path}" >&2
    exit 1
  }
  [[ -f "${config_path}" ]] || {
    printf 'not ok - the per-job gitconfig was not created: %s\n' "${config_path}" >&2
    exit 1
  }

  # Read through git rather than the raw file: the contract is what git resolves,
  # not any particular serialization of it.
  #
  # `insteadOf` reads "when you see <value>, substitute <base>", so the value is
  # the HTTPS URL to be replaced and the base is the SSH URL it becomes. Asserting
  # the base is what proves the redirect points at SSH; a value-only check would
  # pass for a redirect that rewrote SSH to HTTPS.
  local redirect
  redirect=$(per_job_redirect "${config_path}") || {
    printf 'not ok - the per-job gitconfig does not set the SSH redirect\n' >&2
    exit 1
  }
  [[ "${redirect}" == "https://github.com/" ]] || {
    printf 'not ok - the SSH redirect has the wrong value: %s\n' "${redirect}" >&2
    exit 1
  }
  git config --file "${config_path}" --get-regexp '^url\.' | grep -Fq 'git@github.com:' || {
    printf 'not ok - the redirect does not rewrite to the SSH host\n' >&2
    exit 1
  }

  teardown
  printf 'ok - the SSH redirect is written to a file under $RUNNER_TEMP\n'
}

test_leaves_user_gitconfig_untouched() {
  setup
  write_user_gitconfig
  local before
  before=$(cat "${HOME_DIR}/.gitconfig")

  run_script
  assert_status 0

  local after
  after=$(cat "${HOME_DIR}/.gitconfig")
  [[ "${before}" == "${after}" ]] || {
    printf 'not ok - the user gitconfig was modified\n--- before ---\n%s\n--- after ---\n%s\n' \
      "${before}" "${after}" >&2
    exit 1
  }

  # The redirect must not be readable from the user's config either: that is the
  # leak that made a finishing job break a still-running one.
  if HOME="${HOME_DIR}" GIT_CONFIG_GLOBAL="${HOME_DIR}/.gitconfig" \
      git config --get "${REDIRECT_KEY}" >/dev/null 2>&1; then
    printf 'not ok - the SSH redirect leaked into the user gitconfig\n' >&2
    exit 1
  fi

  teardown
  printf 'ok - the user gitconfig is left untouched\n'
}

test_does_not_seed_from_user_gitconfig() {
  setup
  write_user_gitconfig
  run_script
  assert_status 0

  local config_path
  config_path=$(exported_config_path)

  # Isolation is the point: importing the user's config would re-import whatever
  # a concurrently running agent wrote there moments earlier.
  local keys
  keys=$(per_job_keys "${config_path}")
  [[ "${keys}" == "${REDIRECT_KEY_LISTED}" ]] || {
    printf 'not ok - the per-job gitconfig carries settings beyond the redirect:\n%s\n' "${keys}" >&2
    exit 1
  }

  teardown
  printf 'ok - the per-job gitconfig holds only the SSH redirect\n'
}

test_truncates_a_leftover_file() {
  setup
  write_user_gitconfig
  printf '[stale]\n\tvalue = from-an-earlier-attempt\n' >"${RUNNER_TEMP_DIR}/gitconfig"

  run_script
  assert_status 0

  local config_path
  config_path=$(exported_config_path)
  local keys
  keys=$(per_job_keys "${config_path}")
  [[ "${keys}" == "${REDIRECT_KEY_LISTED}" ]] || {
    printf 'not ok - a leftover per-job gitconfig was appended to, not replaced:\n%s\n' "${keys}" >&2
    exit 1
  }

  teardown
  printf 'ok - a leftover per-job gitconfig is replaced\n'
}

test_fails_without_runner_temp() {
  setup
  write_user_gitconfig
  RUN_OUTPUT=$(
    HOME="${HOME_DIR}" GITHUB_ENV="${ENV_FILE}" \
      "${SCRIPT}" 2>&1
  )
  RUN_STATUS=$?
  [[ "${RUN_STATUS}" -ne 0 ]] || {
    printf 'not ok - the script succeeded without $RUNNER_TEMP\n' >&2
    exit 1
  }
  assert_contains "${RUN_OUTPUT}" "RUNNER_TEMP" "the failure does not name the missing variable"

  teardown
  printf 'ok - a missing $RUNNER_TEMP fails the step\n'
}

test_fails_without_github_env() {
  setup
  write_user_gitconfig
  RUN_OUTPUT=$(
    HOME="${HOME_DIR}" RUNNER_TEMP="${RUNNER_TEMP_DIR}" \
      "${SCRIPT}" 2>&1
  )
  RUN_STATUS=$?
  [[ "${RUN_STATUS}" -ne 0 ]] || {
    printf 'not ok - the script succeeded without $GITHUB_ENV\n' >&2
    exit 1
  }
  assert_contains "${RUN_OUTPUT}" "GITHUB_ENV" "the failure does not name the missing variable"

  teardown
  printf 'ok - a missing $GITHUB_ENV fails the step\n'
}

test_writes_redirect_into_runner_temp
test_leaves_user_gitconfig_untouched
test_does_not_seed_from_user_gitconfig
test_truncates_a_leftover_file
test_fails_without_runner_temp
test_fails_without_github_env
