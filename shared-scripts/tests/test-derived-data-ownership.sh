#!/usr/bin/env bash
# Asserts PL-377's DerivedData contract: cleanup deletes only directories whose
# info.plist records a workspace path inside the current checkout. DerivedData
# directory names embed a hash of the workspace path, so CI, agent worktrees, and
# interactive Xcode sessions of the same project each own a distinct directory —
# the old project-name glob crossed those boundaries and destroyed other
# checkouts' build products.
set -u -o pipefail

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

SCRIPT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/clear-xcode-derived-data.sh
[[ -x "${SCRIPT}" ]] || fail "clear-xcode-derived-data.sh is missing or not executable"

TMP=$(mktemp -d)
# Only the scratch directory is removed unconditionally. The fixture directories live
# in the real DerivedData base, so they are removed explicitly and individually below;
# a broad cleanup there could destroy unrelated DerivedData.
trap 'rm -rf "${TMP}"' EXIT

# The script resolves the DerivedData base exactly as in production: a custom
# location preference first, then the user default. Mirror that resolution so the
# fixture lands where the script will actually look, without touching preferences.
CUSTOM_DERIVED_DATA=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)
if [[ -n "${CUSTOM_DERIVED_DATA}" ]]; then
  FIXTURE_BASE="${CUSTOM_DERIVED_DATA}"
else
  FIXTURE_BASE="${HOME}/Library/Developer/Xcode/DerivedData"
fi
mkdir -p "${FIXTURE_BASE}" || fail "could not create the DerivedData fixture base"

# Unique per run so concurrent test invocations cannot collide on the shared base.
PROJECT="PL377Test-${RANDOM}"
DERIVED_DATA_BASE_NAME="${PROJECT// /_}"

plist_with() {
  mkdir -p "$1"
  cat > "$1/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WorkspacePath</key>
  <string>$2</string>
</dict>
</plist>
EOF
}

mkdir -p "${TMP}/workspace/${PROJECT}.xcodeproj"
mkdir -p "${TMP}/other-checkout/${PROJECT}.xcodeproj"

# Belongs to this checkout: must be deleted.
plist_with "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" "${TMP}/workspace/${PROJECT}.xcodeproj"
# Belongs to another checkout of the same project: must be kept.
plist_with "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-bbbb2222" "${TMP}/other-checkout/${PROJECT}.xcodeproj"
# No WorkspacePath recorded: cannot be attributed, so must be kept.
mkdir -p "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-cccc3333"
cat > "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-cccc3333/info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>LastAccessedDate</key>
  <date>2026-09-21T00:00:00Z</date>
</dict>
</plist>
EOF
# A stale workspace path that no longer exists: unattributable, so must be kept.
plist_with "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-dddd4444" "${TMP}/vanished/${PROJECT}.xcodeproj"

run_in_workspace() {
  local workspace="${TMP}/workspace"
  case "${1:-}" in
    with-github-workspace)
      (cd "${workspace}" && GITHUB_WORKSPACE="${workspace}" "${SCRIPT}")
      ;;
    with-broken-workspace)
      (cd "${workspace}" && GITHUB_WORKSPACE="${TMP}/does-not-exist" "${SCRIPT}")
      ;;
    *)
      (cd "${workspace}" && env -u GITHUB_WORKSPACE "${SCRIPT}")
      ;;
  esac
}

output=$(run_in_workspace with-github-workspace) || fail "the script failed under GITHUB_WORKSPACE"
printf 'ok - the script runs cleanly with GITHUB_WORKSPACE set\n'

[[ ! -e "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" ]] ||
  fail "DerivedData owned by the CI workspace survived cleanup"
printf 'ok - DerivedData owned by the CI workspace is deleted\n'

for kept in bbbb2222 cccc3333 dddd4444; do
  [[ -e "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-${kept}" ]] ||
    fail "DerivedData fixture -${kept} was deleted although its workspace is outside the boundary"
done
printf 'ok - foreign, unattributable, and stale-path DerivedData are all kept\n'

case "${output}" in
  *"Deleting derived data at: ${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-bbbb2222"*)
    fail "a foreign checkout's directory was selected for deletion"
    ;;
esac
printf 'ok - foreign checkouts are skipped with a diagnostic\n'

output=$(run_in_workspace without-github-workspace) || fail "the script failed without GITHUB_WORKSPACE"
[[ ! -e "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" ]] ||
  fail "local fallback cleanup did not delete the current checkout's DerivedData"
printf 'ok - without GITHUB_WORKSPACE the current directory is the ownership boundary\n'

# An unresolvable boundary must fail closed: the first run deleted the attributable
# directory, so recreate it and prove that a broken GITHUB_WORKSPACE deletes nothing
# (an empty boundary would otherwise match every absolute path).
plist_with "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" "${TMP}/workspace/${PROJECT}.xcodeproj"
if run_in_workspace with-broken-workspace; then
  fail "the script exited 0 although the GITHUB_WORKSPACE path does not exist"
fi
[[ -e "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" ]] ||
  fail "cleanup ran although the ownership boundary could not be resolved"
printf 'ok - an unresolvable boundary fails closed and deletes nothing\n'

rm -rf "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-aaaa1111" \
       "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-bbbb2222" \
       "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-cccc3333" \
       "${FIXTURE_BASE}/${DERIVED_DATA_BASE_NAME}-dddd4444"
printf 'all derived-data ownership checks passed\n'
