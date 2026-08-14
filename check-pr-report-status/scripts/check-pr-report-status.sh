#!/usr/bin/env bash
# Fail-open by construction: no `set -e`. Every failure mode below degrades to
# already_reported=false and the script always exits 0 — a lookup problem must never
# suppress the scan it's guarding.
set -uo pipefail

readonly MARKER_PREVIEW_LENGTH=100
readonly MAX_ATTEMPTS=2
readonly MAX_PAGES=50
readonly RETRY_DELAY_SECONDS=3

ALREADY_REPORTED=false
LATEST_MATCH_BODY=""
PAGE_BODY=""

log_warning() {
  printf '::warning::%s\n' "$*" >&2
}

# Writes the already_reported output (when possible) and terminates the script. This is the
# single exit point so every code path — success, no match, or any failure — funnels through
# the same fail-open, always-exit-0 contract.
finish() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'already_reported=%s\n' "${ALREADY_REPORTED}" >>"${GITHUB_OUTPUT}"
  else
    log_warning "GITHUB_OUTPUT is not set; already_reported output was not written."
  fi
  exit 0
}

validate_inputs() {
  if [[ -z "${PR_NUMBER:-}" || ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    log_warning "PR_NUMBER must be a positive decimal integer; treating as not yet reported."
    return 1
  fi

  if [[ -z "${HEADER:-}" ]]; then
    log_warning "HEADER is required; treating as not yet reported."
    return 1
  fi

  if [[ -z "${SUCCESS_PATTERN:-}" ]]; then
    log_warning "SUCCESS_PATTERN is required; treating as not yet reported."
    return 1
  fi

  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    log_warning "GITHUB_TOKEN is required; treating as not yet reported."
    return 1
  fi

  if [[ -z "${GITHUB_REPOSITORY:-}" || ! "${GITHUB_REPOSITORY}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    log_warning "GITHUB_REPOSITORY must use the owner/repo format; treating as not yet reported."
    return 1
  fi
}

fetch_comments_page() {
  local attempt
  local page=$1

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if PAGE_BODY=$(curl -sf \
      -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments?per_page=100&page=${page}"); then
      return 0
    fi

    if (( attempt < MAX_ATTEMPTS )); then
      log_warning "Fetching PR #${PR_NUMBER} comments (page ${page}) failed (attempt ${attempt}/${MAX_ATTEMPTS}). Retrying in ${RETRY_DELAY_SECONDS}s."
      sleep "${RETRY_DELAY_SECONDS}"
      continue
    fi

    log_warning "Fetching PR #${PR_NUMBER} comments (page ${page}) failed after ${MAX_ATTEMPTS} attempt(s); treating as not yet reported."
    return 1
  done
}

# Sets LATEST_MATCH_BODY to the body of the most recently created comment whose body contains
# the exact literal sticky-comment marker for HEADER (verified byte-for-byte against
# marocchino/sticky-pull-request-comment's source: `<!-- Sticky Pull Request Comment${header} -->`,
# no separator before the header value). Comments are processed one JSON object at a time
# (never flattened into one text blob), so an unrelated comment's marker and a different
# unrelated comment's success text can never combine into a false match. Returns 1 if no
# matching comment was found, or if any page could not be fetched or parsed.
find_latest_matching_comment() {
  local body
  local comment
  local comment_count=0
  local found=false
  local marker="<!-- Sticky Pull Request Comment${HEADER} -->"
  local page=1
  local page_count

  while :; do
    if ! fetch_comments_page "${page}"; then
      return 1
    fi

    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"${PAGE_BODY}"; then
      log_warning "PR #${PR_NUMBER} comments response (page ${page}) was not a JSON array; treating as not yet reported."
      return 1
    fi

    if ! page_count=$(jq -er 'length' <<<"${PAGE_BODY}" 2>/dev/null); then
      log_warning "Could not count PR #${PR_NUMBER} comments (page ${page}); treating as not yet reported."
      return 1
    fi

    comment_count=$((comment_count + page_count))

    while IFS= read -r comment; do
      [[ -z "${comment}" ]] && continue
      if ! body=$(jq -r '.body // ""' <<<"${comment}" 2>/dev/null); then
        continue
      fi
      if grep -qF -- "${marker}" <<<"${body}"; then
        LATEST_MATCH_BODY=${body}
        found=true
      fi
    done < <(jq -c '.[]' <<<"${PAGE_BODY}" 2>/dev/null)

    if (( page_count < 100 )); then
      break
    fi

    page=$((page + 1))
    if (( page > MAX_PAGES )); then
      log_warning "PR #${PR_NUMBER} has more than ${MAX_PAGES} pages of comments; stopping pagination early. A sticky comment beyond this point would not be found (never a false skip)."
      break
    fi
  done

  printf 'Fetched %s comment(s) across %s page(s) for PR #%s.\n' "${comment_count}" "${page}" "${PR_NUMBER}"

  if [[ "${found}" != true ]]; then
    printf 'No existing %s sticky comment found for PR #%s.\n' "${HEADER}" "${PR_NUMBER}"
    return 1
  fi
}

main() {
  if ! validate_inputs; then
    finish
  fi

  if ! find_latest_matching_comment; then
    finish
  fi

  if grep -Eq -- "${SUCCESS_PATTERN}" <<<"${LATEST_MATCH_BODY}"; then
    ALREADY_REPORTED=true
    printf 'Most recent %s comment matches the success pattern; already reported: %.*s\n' \
      "${HEADER}" "${MARKER_PREVIEW_LENGTH}" "${LATEST_MATCH_BODY}"
  else
    printf 'Most recent %s comment does not match the success pattern; scan will run.\n' "${HEADER}"
  fi

  finish
}

main "$@"
