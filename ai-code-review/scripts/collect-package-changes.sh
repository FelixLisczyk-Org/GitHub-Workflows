#!/usr/bin/env bash
# Collects changes that other repositories of the same owner (usually Swift
# packages) made for a ticket, so the AI review can see the whole change and
# not only the app PR's pin bump.
#
# Mirrors the Raycast "find-ticket-packages" lookup, but uses the GitHub API
# because the runner has no package checkouts:
#   1. Commits on a repository's default branch whose message references the
#      ticket ID (the package workflow's "Ref ABC-123" trailer).
#   2. Otherwise, a branch whose name contains the ticket ID, diffed against
#      the default branch.
#
# Writes a Markdown section to stdout and extracts a source snapshot of each
# matched repository into PACKAGES_DIR/<repo> so the model can read the code
# around the diff. Lookup problems are reported as warnings on stderr and never
# fail the review.
#
# Environment:
#   GH_TOKEN          token that can read the owner's repositories
#   OWNER             organization that owns the packages
#   CURRENT_REPO      owner/name of the reviewed repository (excluded)
#   TICKET_ID         ticket ID such as SX-914
#   PACKAGES_DIR      directory for source snapshots (created if missing)
#   PACKAGES_DISPLAY_DIR     optional path shown to the model for PACKAGES_DIR
#   MAX_PACKAGE_DIFF_CHARS   optional total diff budget (default 60000)
#   MAX_SNAPSHOT_BYTES       optional tarball size limit (default 50 MB)
set -uo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${OWNER:?OWNER is required}"
: "${CURRENT_REPO:?CURRENT_REPO is required}"
: "${TICKET_ID:?TICKET_ID is required}"
: "${PACKAGES_DIR:?PACKAGES_DIR is required}"

MAX_PACKAGE_DIFF_CHARS=${MAX_PACKAGE_DIFF_CHARS:-60000}
MAX_SNAPSHOT_BYTES=${MAX_SNAPSHOT_BYTES:-52428800}
PACKAGES_DISPLAY_DIR=${PACKAGES_DISPLAY_DIR:-${PACKAGES_DIR}}

TICKET_ID=$(printf '%s' "${TICKET_ID}" | tr '[:lower:]' '[:upper:]')
if ! [[ "${TICKET_ID}" =~ ^[A-Z][A-Z0-9]*-[0-9]+$ ]]; then
  echo "::warning::Invalid ticket ID '${TICKET_ID}'. Skipping package lookup." >&2
  exit 0
fi
TICKET_LOWER=$(printf '%s' "${TICKET_ID}" | tr '[:upper:]' '[:lower:]')
# Same boundary rule as the Raycast script: SX-914 must not match SX-9140.
TICKET_REGEX="(^|[^[:alnum:]])${TICKET_ID}([^[:alnum:]]|$)"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

warn() {
  echo "::warning::$*" >&2
}

matches_ticket() {
  grep -Eiq "${TICKET_REGEX}"
}

# --- Default-branch commits that reference the ticket ---
# Commit search only indexes default branches, which is exactly the "main"
# check of the Raycast script. Matches land in commits/<repo>.tsv as
# sha<TAB>date<TAB>base64(message), oldest first. Plain files instead of
# associative arrays keep the script compatible with macOS's bash 3.2.
COMMITS_DIR="${WORK_DIR}/commits"
mkdir -p "${COMMITS_DIR}"
if gh api -X GET search/commits \
  -f q="${TICKET_ID} user:${OWNER}" -f per_page=100 \
  >"${WORK_DIR}/search.json" 2>"${WORK_DIR}/search.err"; then
  jq -r --arg current "${CURRENT_REPO}" '
    [.items[]
      | select(.repository.full_name != $current)
      | {repo: .repository.name, sha, date: .commit.committer.date, message: .commit.message}]
    | sort_by(.date)
    | .[]
    | [.repo, .sha, .date, (.message | @base64)]
    | @tsv' "${WORK_DIR}/search.json" >"${WORK_DIR}/search.tsv" 2>/dev/null || : >"${WORK_DIR}/search.tsv"
else
  warn "Commit search for ${TICKET_ID} failed: $(head -c 300 "${WORK_DIR}/search.err")"
  : >"${WORK_DIR}/search.tsv"
fi

COMMIT_REPOS=()
while IFS=$'\t' read -r repo sha date message_b64; do
  [ -n "${repo}" ] || continue
  # Search is word-based, so re-check the exact ticket boundary.
  printf '%s' "${message_b64}" | base64 --decode 2>/dev/null | matches_ticket || continue
  if [ ! -f "${COMMITS_DIR}/${repo}.tsv" ]; then
    COMMIT_REPOS+=("${repo}")
  fi
  printf '%s\t%s\t%s\n' "${sha}" "${date}" "${message_b64}" >>"${COMMITS_DIR}/${repo}.tsv"
done <"${WORK_DIR}/search.tsv"

# --- Ticket branches in repositories without matching default-branch commits ---
# Matches land in branches.tsv as repo<TAB>branch<TAB>default_branch.
BRANCHES_FILE="${WORK_DIR}/branches.tsv"
: >"${BRANCHES_FILE}"
if gh api --paginate "orgs/${OWNER}/repos?per_page=100&type=all" \
  >"${WORK_DIR}/repos.json" 2>"${WORK_DIR}/repos.err"; then
  jq -r -s --arg current "${CURRENT_REPO}" '
    add // []
    | .[]
    | select(.full_name != $current and (.archived | not))
    | [.name, .default_branch]
    | @tsv' "${WORK_DIR}/repos.json" >"${WORK_DIR}/repos.tsv" 2>/dev/null || : >"${WORK_DIR}/repos.tsv"
else
  warn "Listing ${OWNER} repositories failed, so ticket branches are not checked: $(head -c 300 "${WORK_DIR}/repos.err")"
  : >"${WORK_DIR}/repos.tsv"
fi

while IFS=$'\t' read -r repo default_branch; do
  [ -n "${repo}" ] || continue
  [ ! -f "${COMMITS_DIR}/${repo}.tsv" ] || continue

  # Ticket branches start with the lowercase ticket ID (sx-914, sx-914-fix).
  # matching-refs is a case-sensitive prefix match, hence the second filter.
  refs=$(gh api "repos/${OWNER}/${repo}/git/matching-refs/heads/${TICKET_LOWER}" </dev/null 2>/dev/null) || continue
  branch=$(printf '%s' "${refs}" | jq -r '.[].ref | sub("^refs/heads/"; "")' 2>/dev/null \
    | grep -Ei "${TICKET_REGEX}" | sort | head -n 1)
  [ -n "${branch}" ] || continue
  [ "${branch}" != "${default_branch}" ] || continue

  printf '%s\t%s\t%s\n' "${repo}" "${branch}" "${default_branch}" >>"${BRANCHES_FILE}"
done <"${WORK_DIR}/repos.tsv"

if [ "${#COMMIT_REPOS[@]}" -eq 0 ] && [ ! -s "${BRANCHES_FILE}" ]; then
  echo "No package changes found for ${TICKET_ID}." >&2
  exit 0
fi

# --- Diffs and source snapshots ---
DIFF_FILE="${WORK_DIR}/diff.md"
: >"${DIFF_FILE}"
SUMMARY_FILE="${WORK_DIR}/summary.md"
: >"${SUMMARY_FILE}"

snapshot() {
  local repo=$1
  local ref=$2
  local tarball="${WORK_DIR}/${repo}.tar.gz"
  local destination="${PACKAGES_DIR}/${repo}"

  if ! gh api "repos/${OWNER}/${repo}/tarball/${ref}" </dev/null >"${tarball}" 2>/dev/null; then
    warn "Could not download a source snapshot of ${repo} at ${ref}."
    return 1
  fi
  if [ "$(wc -c <"${tarball}" | tr -d ' ')" -gt "${MAX_SNAPSHOT_BYTES}" ]; then
    warn "Source snapshot of ${repo} exceeds ${MAX_SNAPSHOT_BYTES} bytes. Skipping it."
    return 1
  fi
  rm -rf "${destination}"
  mkdir -p "${destination}"
  if ! tar -xzf "${tarball}" -C "${destination}" --strip-components=1 2>/dev/null; then
    warn "Could not extract the source snapshot of ${repo}."
    rm -rf "${destination}"
    return 1
  fi
  rm -f "${tarball}"
}

# Prints the summary line for a repository's source snapshot.
snapshot_note() {
  local repo=$1
  local ref=$2
  local ref_label=$3
  if snapshot "${repo}" "${ref}"; then
    printf '  - Source at `%s`: `%s/%s/`\n' "${ref_label}" "${PACKAGES_DISPLAY_DIR}" "${repo}"
  else
    printf '  - Source snapshot unavailable; review from the diff only.\n'
  fi
}

append_diff() {
  local heading=$1
  local endpoint=$2
  local diff

  if ! diff=$(gh api -H "Accept: application/vnd.github.diff" "${endpoint}" </dev/null 2>/dev/null); then
    warn "Could not fetch the diff for ${heading}."
    diff="(diff unavailable)"
  fi
  printf '#### %s\n\n```diff\n%s\n```\n\n' "${heading}" "${diff}" >>"${DIFF_FILE}"
}

mkdir -p "${PACKAGES_DIR}"

for repo in ${COMMIT_REPOS[@]+"${COMMIT_REPOS[@]}"}; do
  commits_file="${COMMITS_DIR}/${repo}.tsv"
  newest_sha=""
  printf -- '- **%s**: %s commit(s) on the default branch referencing %s\n' \
    "${repo}" "$(grep -c . "${commits_file}")" "${TICKET_ID}" >>"${SUMMARY_FILE}"

  while IFS=$'\t' read -r sha date message_b64; do
    [ -n "${sha}" ] || continue
    subject=$(printf '%s' "${message_b64}" | base64 --decode 2>/dev/null | head -n 1)
    printf '  - `%s` %s (%s)\n' "${sha:0:8}" "${subject}" "${date}" >>"${SUMMARY_FILE}"
    append_diff "${repo} \`${sha:0:8}\` ${subject}" "repos/${OWNER}/${repo}/commits/${sha}"
    newest_sha=${sha}
  done <"${commits_file}"

  snapshot_note "${repo}" "${newest_sha}" "${newest_sha:0:8}" >>"${SUMMARY_FILE}"
done

while IFS=$'\t' read -r repo branch default_branch; do
  [ -n "${repo}" ] || continue
  printf -- '- **%s**: unmerged branch `%s` compared with `%s`\n' \
    "${repo}" "${branch}" "${default_branch}" >>"${SUMMARY_FILE}"
  append_diff "${repo} \`${default_branch}...${branch}\`" \
    "repos/${OWNER}/${repo}/compare/${default_branch}...${branch}"
  snapshot_note "${repo}" "${branch}" "${branch}" >>"${SUMMARY_FILE}"
done <"${BRANCHES_FILE}"

DIFF_CONTENT=$(cat "${DIFF_FILE}")
if [ "${#DIFF_CONTENT}" -gt "${MAX_PACKAGE_DIFF_CHARS}" ]; then
  warn "Package diffs are very large (${#DIFF_CONTENT} chars). Truncating to ${MAX_PACKAGE_DIFF_CHARS} chars."
  DIFF_CONTENT="${DIFF_CONTENT:0:${MAX_PACKAGE_DIFF_CHARS}}

... (package diffs truncated due to size; read the source snapshots for the rest)"
fi

printf '%s\n\n' "Repositories other than ${CURRENT_REPO} that changed for ${TICKET_ID}. The app PR usually only bumps their pins, so these diffs are part of the change under review."
cat "${SUMMARY_FILE}"
printf '\n%s\n' "${DIFF_CONTENT}"
