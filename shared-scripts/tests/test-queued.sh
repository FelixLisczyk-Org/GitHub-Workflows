#!/usr/bin/env bash
# Exercises `shared-scripts/queued.sh` against a stub `xcodebuildmcp-queue`: queued when the
# queue is on PATH, direct when it is not, and the queue-wait budget defaulted but overridable.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly WRAPPER="${REPO_ROOT}/shared-scripts/queued.sh"

WORK=$(mktemp -d)
readonly WORK
trap '/bin/rm -rf "${WORK}"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# The stub records its arguments and the timeout it was given, then runs the command after `--`
# the way `queue run` would.
mkdir -p "${WORK}/queue-bin" "${WORK}/tools"
cat > "${WORK}/queue-bin/xcodebuildmcp-queue" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${RECORD_DIR}/arguments"
printf '%s\n' "${XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS-unset}" > "${RECORD_DIR}/timeout"
[[ "$1 $2 $3" == "queue run --" ]] || exit 70
shift 3
exec "$@"
STUB
chmod +x "${WORK}/queue-bin/xcodebuildmcp-queue"
cat > "${WORK}/tools/build-tool" <<'TOOL'
#!/usr/bin/env bash
printf 'ran %s\n' "$*"
exit "${BUILD_TOOL_EXIT:-0}"
TOOL
chmod +x "${WORK}/tools/build-tool"

base_path="${WORK}/tools:/usr/bin:/bin"
export RECORD_DIR="${WORK}"

# Queued: arguments are forwarded unchanged after `queue run --`.
output=$(env -u XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS PATH="${WORK}/queue-bin:${base_path}" \
  "${WRAPPER}" build-tool "two words" --flag) || fail "queued command failed"
[[ "${output}" == "ran two words --flag" ]] || fail "queued command printed ${output@Q}"
expected=$'queue\nrun\n--\nbuild-tool\ntwo words\n--flag'
[[ "$(cat "${WORK}/arguments")" == "${expected}" ]] ||
  fail "queue received $(cat "${WORK}/arguments" | tr '\n' ' ')"
printf 'ok - the command is submitted through queue run with its arguments intact\n'

[[ "$(cat "${WORK}/timeout")" == "5700" ]] || fail "default queue timeout was $(cat "${WORK}/timeout")"
printf 'ok - the queue wait defaults to one execution timeout plus five minutes\n'

XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS=120 PATH="${WORK}/queue-bin:${base_path}" \
  "${WRAPPER}" build-tool >/dev/null || fail "queued command with own timeout failed"
[[ "$(cat "${WORK}/timeout")" == "120" ]] || fail "a step's own queue timeout was replaced"
printf 'ok - a queue timeout set by the step is kept\n'

BUILD_TOOL_EXIT=65 PATH="${WORK}/queue-bin:${base_path}" "${WRAPPER}" build-tool >/dev/null
[[ $? -eq 65 ]] || fail "queued exit status was not passed through"
printf 'ok - the queued exit status is passed through\n'

# Direct: no queue on PATH, so the stub must not run.
/bin/rm -f "${WORK}/arguments"
output=$(PATH="${base_path}" "${WRAPPER}" build-tool direct) || fail "direct command failed"
[[ "${output}" == "ran direct" ]] || fail "direct command printed ${output@Q}"
[[ ! -e "${WORK}/arguments" ]] || fail "the queue was used although it is not on PATH"
BUILD_TOOL_EXIT=3 PATH="${base_path}" "${WRAPPER}" build-tool >/dev/null
[[ $? -eq 3 ]] || fail "direct exit status was not passed through"
printf 'ok - without the queue the command runs directly with its exit status\n'

PATH="${base_path}" "${WRAPPER}" 2>/dev/null
[[ $? -eq 64 ]] || fail "a missing command was not rejected"
printf 'ok - a missing command is a usage error\n'
