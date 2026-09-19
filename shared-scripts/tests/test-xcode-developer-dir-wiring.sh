#!/usr/bin/env bash
# Asserts PL-374's contract: the Xcode a job builds with is chosen per job via
# `DEVELOPER_DIR`, never switched machine-wide via `sudo xcode-select -s`.
#
# `xcode-select -s` is global state on the Mac, so concurrent jobs only worked by
# accident — a `beta` job and a `main` job each selected their own Xcode, and a
# finishing job restored the developer directory captured at its own start, which
# could put it back under a job still running. The switch and the action that
# undid it are gone; this fails if either comes back.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# Scanning `.git` for `sudo` would be wasteful and its packed objects are not
# text, so the check runs over the composite actions' metadata only.
shopt -s nullglob
action_files=("${REPO_ROOT}"/*/action.yml)
shopt -u nullglob
(( ${#action_files[@]} > 0 )) || fail "no action.yml files were found - the glob is wrong"

for retired in xcode-select-version xcode-restore-version; do
  [[ ! -e "${REPO_ROOT}/${retired}" ]] || fail "${retired}/ still exists"
done
printf 'ok - the machine-global Xcode actions are gone\n'

if offending=$(grep -l -e 'xcode-select -s' -e 'sudo' "${action_files[@]}"); then
  printf '%s\n' "${offending}" >&2
  fail "an action still switches the developer directory machine-wide"
fi
printf 'ok - no action calls xcode-select or sudo\n'

if offending=$(grep -l -e 'xcode-select-version' -e 'xcode-restore-version' -e 'ORIGINAL_XCODE_PATH' "${action_files[@]}"); then
  printf '%s\n' "${offending}" >&2
  fail "an action still references the retired Xcode actions"
fi
printf 'ok - nothing references the retired Xcode actions\n'

# The input survives only so that callers passing it keep working; consuming it
# again would mean the root password found a new use.
if offending=$(grep -l -e 'inputs.runner_root_password' "${action_files[@]}"); then
  printf '%s\n' "${offending}" >&2
  fail "an action still consumes runner_root_password"
fi
printf 'ok - runner_root_password is accepted but never consumed\n'

ruby -ryaml -e '
  %w[prepare-xcode-build finish-xcode-build].each do |action|
    inputs = YAML.load_file(File.join(ARGV[0], action, "action.yml"))["inputs"] || {}
    next unless inputs.key?("runner_root_password")

    if inputs["runner_root_password"]["required"]
      warn "not ok - #{action}: runner_root_password is still required, so callers cannot drop it"
      exit 1
    end
  end
  puts "ok - runner_root_password is optional wherever it is still declared"
' "${REPO_ROOT}" || exit 1

grep -Fq 'GitHub-Workflows/select-xcode@' "${REPO_ROOT}/prepare-xcode-build/action.yml" ||
  fail "prepare-xcode-build no longer selects its Xcode through select-xcode"
grep -Fq "use_beta_xcode: \${{ github.ref == 'refs/heads/beta' }}" "${REPO_ROOT}/prepare-xcode-build/action.yml" ||
  fail "prepare-xcode-build no longer requests beta Xcode on the beta branch"
printf 'ok - prepare-xcode-build selects its Xcode per job\n'

script="${REPO_ROOT}/select-xcode/scripts/select-xcode.sh"
[[ -x "${script}" ]] || fail "select-xcode.sh is missing or not executable"
grep -Fq 'DEVELOPER_DIR=' "${script}" || fail "select-xcode.sh does not export DEVELOPER_DIR"
grep -Fq 'GITHUB_ENV' "${script}" || fail "select-xcode.sh does not write to \$GITHUB_ENV"
# The script documents why the switch was removed, so only executable lines count.
grep -v '^[[:space:]]*#' "${script}" | grep -q 'xcode-select -s' &&
  fail "select-xcode.sh still switches the developer directory machine-wide"
printf 'ok - select-xcode exports DEVELOPER_DIR into $GITHUB_ENV\n'
