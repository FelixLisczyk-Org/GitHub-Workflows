#!/usr/bin/env bash
set -euo pipefail

readonly MAX_ATTEMPTS=3

API_BODY=""
API_ERROR=""
API_OUTPUT=""
API_RATE_LIMIT_REMAINING=""
API_RATE_LIMIT_RESET=""
API_RETRY_AFTER=""
API_STATUS=""
DISCOVERY_CANDIDATE_FILE=""
DISCOVERY_PAGE_TOTAL=0
DISCOVERY_RUN_TOTAL=0
DISCOVERY_STATUS_TOTAL=0
PR_HEAD_REF_MATCH=""
PR_HEAD_REPO_MATCH=""
RUN_IDS=()
SELF_WORKFLOW_PATH=""

readonly ACTIVE_STATUSES=(queued in_progress requested waiting pending)

cleanup() {
  if [[ -n "${DISCOVERY_CANDIDATE_FILE}" ]]; then
    rm -f "${DISCOVERY_CANDIDATE_FILE}"
  fi
}

trap cleanup EXIT

log_error() {
  printf '::error::%s\n' "$*" >&2
}

log_warning() {
  printf '::warning::%s\n' "$*" >&2
}

validate_context() {
  if [[ -z "${PR_NUMBER:-}" || ! "${PR_NUMBER}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "PR_NUMBER must be a positive decimal integer."
    return 1
  fi

  if [[ -z "${GITHUB_RUN_ID:-}" || ! "${GITHUB_RUN_ID}" =~ ^[1-9][0-9]*$ ]]; then
    log_error "GITHUB_RUN_ID must be a positive decimal integer."
    return 1
  fi

  if [[ -z "${GITHUB_REPOSITORY:-}" || ! "${GITHUB_REPOSITORY}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    log_error "GITHUB_REPOSITORY must use the owner/repo format."
    return 1
  fi

  if [[ -z "${GH_TOKEN:-}" ]]; then
    log_error "GH_TOKEN is required."
    return 1
  fi

  # A blank head ref or head repository is tolerated (the head repository is null once a
  # deleted fork is garbage collected); a malformed one is not, because head-ref matching
  # decides which runs get cancelled.
  if [[ -n "${PR_HEAD_REF:-}" && "${PR_HEAD_REF}" =~ [[:space:][:cntrl:]] ]]; then
    log_error "PR_HEAD_REF must not contain whitespace or control characters."
    return 1
  fi

  if [[ -n "${PR_HEAD_REPO:-}" && ! "${PR_HEAD_REPO}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$ ]]; then
    log_error "PR_HEAD_REPO must use the owner/repo format."
    return 1
  fi
}

# GitHub only lists a workflow run's `pull_requests` associations while the pull request is
# open. This action runs on `pull_request_target: closed`, so by the time it executes the
# association has already been dropped from every run belonging to the closing PR, and PR
# number matching alone finds nothing. Matching the head ref recovers those runs; pairing it
# with the head repository keeps a same-named branch in a fork from matching.
resolve_matching_criteria() {
  local workflow_path

  if [[ -n "${PR_HEAD_REF:-}" && -n "${PR_HEAD_REPO:-}" ]]; then
    PR_HEAD_REF_MATCH=${PR_HEAD_REF}
    PR_HEAD_REPO_MATCH=${PR_HEAD_REPO}
  else
    PR_HEAD_REF_MATCH=""
    PR_HEAD_REPO_MATCH=""
    log_warning "Head ref metadata is unavailable; matching by PR number only, which misses runs whose pull request association was dropped when PR #${PR_NUMBER} closed."
  fi

  # Exclude sibling runs of this same cleanup workflow: they share the closing PR's head ref,
  # so concurrent cleanup runs would otherwise cancel each other.
  if [[ -n "${WORKFLOW_REF:-}" ]]; then
    workflow_path=${WORKFLOW_REF%%@*}
    workflow_path=${workflow_path#"${GITHUB_REPOSITORY}/"}
    if [[ "${workflow_path}" == .github/workflows/* ]]; then
      SELF_WORKFLOW_PATH=${workflow_path}
    fi
  fi

  if [[ -n "${PR_HEAD_REF_MATCH}" ]]; then
    printf 'Matching active runs by PR number %s and by head ref %s from %s.\n' \
      "${PR_NUMBER}" "${PR_HEAD_REF_MATCH}" "${PR_HEAD_REPO_MATCH}"
  else
    printf 'Matching active runs by PR number %s only.\n' "${PR_NUMBER}"
  fi

  if [[ -n "${SELF_WORKFLOW_PATH}" ]]; then
    printf 'Excluding other runs of this cleanup workflow (%s).\n' "${SELF_WORKFLOW_PATH}"
  fi
}

parse_api_response() {
  local in_headers=false
  local line

  API_BODY=""
  API_RATE_LIMIT_REMAINING=""
  API_RATE_LIMIT_RESET=""
  API_RETRY_AFTER=""
  API_STATUS=""

  while IFS= read -r line; do
    line=${line%$'\r'}

    if [[ "${line}" =~ ^HTTP/[0-9.]+[[:space:]]+([0-9]{3}) ]]; then
      API_STATUS=${BASH_REMATCH[1]}
      API_BODY=""
      in_headers=true
      continue
    fi

    if [[ "${in_headers}" == true ]]; then
      if [[ -z "${line}" ]]; then
        in_headers=false
      elif [[ "${line,,}" == retry-after:* ]]; then
        API_RETRY_AFTER=${line#*:}
        API_RETRY_AFTER=${API_RETRY_AFTER//[[:space:]]/}
      elif [[ "${line,,}" == x-ratelimit-remaining:* ]]; then
        API_RATE_LIMIT_REMAINING=${line#*:}
        API_RATE_LIMIT_REMAINING=${API_RATE_LIMIT_REMAINING//[[:space:]]/}
      elif [[ "${line,,}" == x-ratelimit-reset:* ]]; then
        API_RATE_LIMIT_RESET=${line#*:}
        API_RATE_LIMIT_RESET=${API_RATE_LIMIT_RESET//[[:space:]]/}
      fi
      continue
    fi

    if [[ -n "${API_BODY}" ]]; then
      API_BODY+=$'\n'
    fi
    API_BODY+="${line}"
  done <<< "${API_OUTPUT}"

  if [[ -z "${API_STATUS}" && "${API_ERROR}" =~ HTTP[^0-9]*([0-9]{3}) ]]; then
    API_STATUS=${BASH_REMATCH[1]}
  fi

  while IFS= read -r line; do
    line=${line%$'\r'}
    if [[ "${line,,}" == retry-after:* ]]; then
      API_RETRY_AFTER=${line#*:}
      API_RETRY_AFTER=${API_RETRY_AFTER//[[:space:]]/}
    elif [[ "${line,,}" == x-ratelimit-remaining:* ]]; then
      API_RATE_LIMIT_REMAINING=${line#*:}
      API_RATE_LIMIT_REMAINING=${API_RATE_LIMIT_REMAINING//[[:space:]]/}
    elif [[ "${line,,}" == x-ratelimit-reset:* ]]; then
      API_RATE_LIMIT_RESET=${line#*:}
      API_RATE_LIMIT_RESET=${API_RATE_LIMIT_RESET//[[:space:]]/}
    fi
  done <<< "${API_ERROR}"
}

request_api() {
  local error_file
  local output_file

  output_file=$(mktemp)
  error_file=$(mktemp)

  if gh api "$@" >"${output_file}" 2>"${error_file}"; then
    API_EXIT=0
  else
    API_EXIT=$?
  fi

  API_OUTPUT=$(<"${output_file}")
  API_ERROR=$(<"${error_file}")
  rm -f "${output_file}" "${error_file}"
  parse_api_response
}

is_rate_limit_message() {
  local error=${API_ERROR,,}
  [[ "${error}" == *"api rate limit"* \
    || "${error}" == *"secondary rate limit"* \
    || "${error}" == *"abuse detection"* ]]
}

is_rate_limited_403() {
  if [[ "${API_STATUS}" != "403" ]]; then
    return 1
  fi

  if [[ "${API_RETRY_AFTER}" =~ ^[0-9]+$ || "${API_RATE_LIMIT_REMAINING}" == "0" ]]; then
    return 0
  fi

  is_rate_limit_message
}

is_transient_failure() {
  if [[ -z "${API_STATUS}" || "${API_STATUS}" == "429" || "${API_STATUS}" =~ ^5[0-9][0-9]$ ]]; then
    return 0
  fi

  is_rate_limited_403
}

sleep_before_retry() {
  local attempt=$1
  local current_epoch
  local delay=$((1 << (attempt - 1)))

  if [[ "${API_RETRY_AFTER}" =~ ^[1-9][0-9]*$ ]]; then
    delay=${API_RETRY_AFTER}
  elif [[ "${API_RATE_LIMIT_REMAINING}" == "0" && "${API_RATE_LIMIT_RESET}" =~ ^[0-9]+$ ]]; then
    current_epoch=$(date +%s)
    delay=$((API_RATE_LIMIT_RESET - current_epoch))
    if (( delay < 1 )); then
      delay=1
    fi
  elif [[ "${API_STATUS}" == "429" ]]; then
    delay=60
  elif is_rate_limited_403; then
    delay=60
  fi

  sleep "${delay}"
}

discover_runs() {
  local attempt
  local endpoint
  local completed_count
  local page_count
  local run_count
  local status

  DISCOVERY_CANDIDATE_FILE=$(mktemp)
  : >"${DISCOVERY_CANDIDATE_FILE}"
  DISCOVERY_PAGE_TOTAL=0
  DISCOVERY_RUN_TOTAL=0
  DISCOVERY_STATUS_TOTAL=0

  for status in "${ACTIVE_STATUSES[@]}"; do
    endpoint="/repos/${GITHUB_REPOSITORY}/actions/runs?per_page=100&status=${status}"

    for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
      request_api --method GET --paginate --slurp "${endpoint}"

      # gh slurps one status query into memory; buffers are released before the next status,
      # limiting retention to the active runs for one status rather than repository history.
      if (( API_EXIT == 0 )); then
        if ! jq -e 'type == "array" and all(.[]; type == "object" and (.workflow_runs | type) == "array" and all(.workflow_runs[]; type == "object" and (.id | type) == "number" and .id > 0 and ((.id | floor) == .id) and ((.pull_requests? // []) | type) == "array" and all((.pull_requests? // [])[]; type == "object" and (.number? != null)) and ((.head_branch? // "") | type) == "string" and (((.head_repository? // {}) | .full_name? // "") | type) == "string" and ((.path? // "") | type) == "string"))' \
          >/dev/null <<< "${API_OUTPUT}"; then
          log_error "Workflow run discovery for status '${status}' returned an invalid response."
          return 1
        fi

        if ! page_count=$(jq -er 'length' <<< "${API_OUTPUT}") \
          || ! run_count=$(jq -er '[.[].workflow_runs[]] | length' <<< "${API_OUTPUT}") \
          || ! completed_count=$(jq -er '[.[].workflow_runs[] | select(.status == "completed")] | length' <<< "${API_OUTPUT}"); then
          log_error "Could not calculate workflow run discovery totals for status '${status}'."
          return 1
        fi

        if ! jq -r \
          --arg current_run_id "${GITHUB_RUN_ID}" \
          --arg head_ref "${PR_HEAD_REF_MATCH}" \
          --arg head_repo "${PR_HEAD_REPO_MATCH}" \
          --arg pr_number "${PR_NUMBER}" \
          --arg self_workflow_path "${SELF_WORKFLOW_PATH}" \
          '.[] | .workflow_runs[]
            | select(
                any(.pull_requests[]?; (.number | tostring) == $pr_number)
                or (
                  $head_ref != ""
                  and $head_repo != ""
                  and (.head_branch? // "") == $head_ref
                  and ((((.head_repository? // {}) | .full_name? // "") | ascii_downcase)
                        == ($head_repo | ascii_downcase))
                )
              )
            | select($self_workflow_path == "" or (.path? // "") != $self_workflow_path)
            | select(.status != "completed")
            | select((.id | tostring) != $current_run_id)
            | (.id | tostring)' \
          <<< "${API_OUTPUT}" >>"${DISCOVERY_CANDIDATE_FILE}"; then
          log_error "Workflow run filtering failed for status '${status}'."
          return 1
        fi

        DISCOVERY_STATUS_TOTAL=$((DISCOVERY_STATUS_TOTAL + 1))
        DISCOVERY_PAGE_TOTAL=$((DISCOVERY_PAGE_TOTAL + page_count))
        DISCOVERY_RUN_TOTAL=$((DISCOVERY_RUN_TOTAL + run_count))
        if (( completed_count > 0 )); then
          printf 'Ignored %s completed workflow run(s) returned for active status %s.\n' \
            "${completed_count}" "${status}" >&2
        fi
        printf 'Discovered status %s: %s page(s), %s workflow run(s).\n' \
          "${status}" "${page_count}" "${run_count}"
        break
      fi

      if is_transient_failure && (( attempt < MAX_ATTEMPTS )); then
        printf 'Workflow run discovery for status %s failed transiently (attempt %d/%d, HTTP %s). Retrying.\n' \
          "${status}" "${attempt}" "${MAX_ATTEMPTS}" "${API_STATUS:-transport error}" >&2
        sleep_before_retry "${attempt}"
        continue
      fi

      log_error "Workflow run discovery for status '${status}' failed after ${attempt} attempt(s) (HTTP ${API_STATUS:-transport error})."
      return 1
    done

    API_OUTPUT=""
    API_BODY=""
  done

  printf 'Discovered %s status query/queries, %s page(s), and %s active workflow run(s).\n' \
    "${DISCOVERY_STATUS_TOTAL}" "${DISCOVERY_PAGE_TOTAL}" "${DISCOVERY_RUN_TOTAL}"
}

select_run_ids() {
  local run_id
  local selection_file

  selection_file=$(mktemp)
  if ! sort -n -u "${DISCOVERY_CANDIDATE_FILE}" >"${selection_file}"; then
    rm -f "${selection_file}"
    log_error "Workflow run filtering failed."
    return 1
  fi

  mapfile -t RUN_IDS <"${selection_file}"
  rm -f "${selection_file}"

  for run_id in "${RUN_IDS[@]}"; do
    if [[ "${run_id}" == "" ]]; then
      continue
    fi
    if [[ ! "${run_id}" =~ ^[1-9][0-9]*$ ]]; then
      log_error "Workflow run discovery returned an invalid run ID."
      return 1
    fi
  done
}

recheck_conflicted_run() {
  local attempt
  local run_id=$1
  local status

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    request_api --method GET --include "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}"

    if [[ "${API_STATUS}" == "404" ]]; then
      printf 'Run %s disappeared during closed-PR cleanup; treating it as resolved.\n' "${run_id}"
      return 0
    fi

    if (( API_EXIT == 0 )) && [[ "${API_STATUS}" == "200" ]]; then
      if ! status=$(jq -er '.status' <<< "${API_BODY}"); then
        log_error "Could not read the status of run ${run_id} after a cancellation race."
        return 1
      fi

      if [[ "${status}" == "completed" ]]; then
        printf 'Run %s completed during closed-PR cleanup; no further action is needed.\n' "${run_id}"
        return 0
      fi

      log_error "Run ${run_id} still has status '${status}' after a cancellation race."
      return 1
    fi

    if is_transient_failure; then
      if (( attempt < MAX_ATTEMPTS )); then
        printf 'Rechecking run %s failed transiently (attempt %d/%d, HTTP %s). Retrying.\n' \
          "${run_id}" "${attempt}" "${MAX_ATTEMPTS}" "${API_STATUS:-transport error}" >&2
        sleep_before_retry "${attempt}"
        continue
      fi

      log_error "Could not resolve cancellation race for run ${run_id} after ${attempt} attempts (HTTP ${API_STATUS:-transport error})."
      return 1
    fi

    if [[ "${API_STATUS}" == "401" || "${API_STATUS}" == "403" ]]; then
      log_error "Authorization failed while rechecking run ${run_id} (HTTP ${API_STATUS})."
      return 1
    fi

    log_error "Could not resolve cancellation race for run ${run_id} (HTTP ${API_STATUS:-transport error})."
    return 1
  done
}

cancel_run() {
  local attempt
  local run_id=$1

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    request_api --method POST --include "/repos/${GITHUB_REPOSITORY}/actions/runs/${run_id}/cancel"

    if (( API_EXIT == 0 )) && [[ "${API_STATUS}" == "202" || "${API_STATUS}" == "204" ]]; then
      printf 'Cancellation accepted for workflow run %s (HTTP %s).\n' "${run_id}" "${API_STATUS}"
      return 0
    fi

    if [[ "${API_STATUS}" == "404" || "${API_STATUS}" == "409" ]]; then
      printf 'Cancellation of workflow run %s returned HTTP %s; rechecking its status.\n' \
        "${run_id}" "${API_STATUS}"
      recheck_conflicted_run "${run_id}"
      return $?
    fi

    if is_transient_failure; then
      if (( attempt < MAX_ATTEMPTS )); then
        printf 'Cancellation of run %s failed transiently (attempt %d/%d, HTTP %s). Retrying.\n' \
          "${run_id}" "${attempt}" "${MAX_ATTEMPTS}" "${API_STATUS:-transport error}" >&2
        sleep_before_retry "${attempt}"
        continue
      fi

      log_error "Failed to cancel workflow run ${run_id} after ${attempt} attempts (HTTP ${API_STATUS:-transport error})."
      return 1
    fi

    if [[ "${API_STATUS}" == "401" || "${API_STATUS}" == "403" ]]; then
      log_error "Authorization failed while cancelling run ${run_id} (HTTP ${API_STATUS})."
      return 1
    fi

    log_error "Failed to cancel workflow run ${run_id} after ${attempt} attempt(s) (HTTP ${API_STATUS:-transport error})."
    return 1
  done
}

main() {
  local failed=0
  local run_id

  validate_context
  printf 'Closing PR #%s in %s; cleaning up associated active workflow runs.\n' \
    "${PR_NUMBER}" "${GITHUB_REPOSITORY}"
  resolve_matching_criteria
  discover_runs
  select_run_ids
  rm -f "${DISCOVERY_CANDIDATE_FILE}"
  DISCOVERY_CANDIDATE_FILE=""

  if (( ${#RUN_IDS[@]} == 0 )); then
    printf 'No active workflow runs associated with closed PR #%s require cancellation.\n' "${PR_NUMBER}"
    return 0
  fi

  printf 'Selected %d active workflow run(s) associated with closed PR #%s: %s\n' \
    "${#RUN_IDS[@]}" "${PR_NUMBER}" "${RUN_IDS[*]}"

  for run_id in "${RUN_IDS[@]}"; do
    if ! cancel_run "${run_id}"; then
      failed=1
    fi
  done

  if (( failed != 0 )); then
    log_error "One or more active workflow runs could not be cancelled during closed-PR cleanup."
    return 1
  fi
}

main "$@"
