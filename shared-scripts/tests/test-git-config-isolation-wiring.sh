#!/usr/bin/env bash
# Asserts PL-378's contract: a job's git configuration is job-scoped, never
# machine-global.
#
# `prepare-xcode-build` used to run `git config --global url."git@github.com:".insteadOf
# "https://github.com/"` and `finish-xcode-build` undid it, both against
# `~/.gitconfig`, which every process on the machine shares. On a Mac Studio that
# runs one CI job alongside agent work under the same user account that is a race
# with no safe ordering: the job that finishes first removes the redirect the
# still-running job needs, and `--remove-section safe` deletes every
# `safe.directory` entry including ones another job just added.
#
# The redirect now lives in a file under `$RUNNER_TEMP` exported as
# `GIT_CONFIG_GLOBAL`, so it disappears with the job and nothing needs undoing.
# This fails if the global mutation or either cleanup step comes back.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly SCRIPT="${REPO_ROOT}/prepare-xcode-build/scripts/isolate-git-config.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Scanning `.git` would be wasteful and its packed objects are not text, so the
# check runs over the composite actions' metadata only.
shopt -s nullglob
action_files=("${REPO_ROOT}"/*/action.yml)
shopt -u nullglob
(( ${#action_files[@]} > 0 )) || fail "no action.yml files were found - the glob is wrong"

if offending=$(grep -l -e 'git config --global' -e 'git config --system' "${action_files[@]}"); then
  printf '%s\n' "${offending}" >&2
  fail "an action still mutates the machine-global git configuration"
fi
printf 'ok - no action writes machine-global git configuration\n'

# The cleanup steps only existed to undo the global mutation. Leaving either one
# behind would keep the cross-job interference they were written to cause: an
# unconditional `--remove-section safe` deletes another job's entries, and an
# unconditional unset removes a redirect a still-running job depends on.
for retired in "Revert Git SSH Redirect" "Remove [safe] section from gitconfig"; do
  if grep -Fq "${retired}" "${REPO_ROOT}/finish-xcode-build/action.yml"; then
    fail "finish-xcode-build still has a \"${retired}\" step"
  fi
done
printf 'ok - the machine-global git cleanup steps are gone\n'

grep -Fq 'isolate-git-config.sh' "${REPO_ROOT}/prepare-xcode-build/action.yml" ||
  fail "prepare-xcode-build no longer isolates its git configuration"
printf 'ok - prepare-xcode-build isolates its git configuration\n'

[[ -x "${SCRIPT}" ]] || fail "isolate-git-config.sh is missing or not executable"

grep -Fq 'GIT_CONFIG_GLOBAL' "${SCRIPT}" || fail "isolate-git-config.sh does not use GIT_CONFIG_GLOBAL"
grep -Fq 'RUNNER_TEMP' "${SCRIPT}" || fail "isolate-git-config.sh does not scope the file to \$RUNNER_TEMP"
grep -Fq 'GITHUB_ENV' "${SCRIPT}" || fail "isolate-git-config.sh does not export through \$GITHUB_ENV"
printf 'ok - isolate-git-config.sh exports GIT_CONFIG_GLOBAL from \$RUNNER_TEMP\n'

# `--file` has to precede the subcommand. A trailing `--file` is ignored, so
# `git config --get ... --file "$path"` silently reads the real global config
# instead - the exact leak this script exists to prevent, and one that would
# still pass a test that only checked the file's contents.
if grep -Eq 'git config [^|]*--(get|list|unset|add)[^|]*--file' "${SCRIPT}"; then
  fail "isolate-git-config.sh passes --file after the subcommand, where git ignores it"
fi
printf 'ok - isolate-git-config.sh puts --file before the subcommand\n'

# The redirect is the only global setting the job needs, and the isolation is the
# point: seeding the per-job file from ~/.gitconfig would re-import whatever a
# concurrently running agent wrote there moments earlier. The script documents
# that reasoning at length, so only executable lines count - the same treatment
# the PL-374 wiring test gives `xcode-select -s`.
if grep -v '^[[:space:]]*#' "${SCRIPT}" | grep -Eq '\.gitconfig'; then
  fail "isolate-git-config.sh reads the user's ~/.gitconfig instead of staying isolated"
fi
printf 'ok - isolate-git-config.sh does not read the user gitconfig\n'

# The behaviour test is what proves the redirect actually resolves; this wiring
# test only proves the pieces are still wired together.
[[ -x "${REPO_ROOT}/prepare-xcode-build/tests/test-isolate-git-config.sh" ]] ||
  fail "the git-config isolation behaviour test is missing or not executable"
printf 'ok - the git-config isolation behaviour test is present\n'
