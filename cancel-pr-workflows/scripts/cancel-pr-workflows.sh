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
DISCOVERY_JSON=""
DISCOVERY_PAGE_TOTAL=""
DISCOVERY_RUN_TOTAL=""
RUN_IDS=()

log_error() {
  printf '::error::%s\n' "$*" >&2
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
  local endpoint="/repos/${GITHUB_REPOSITORY}/actions/runs?per_page=100"

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    request_api --method GET --paginate --slurp "${endpoint}"

    if (( API_EXIT == 0 )); then
      DISCOVERY_JSON=${API_OUTPUT}
      if ! jq -e 'type == "array" and all(.[]; type == "object" and (.workflow_runs | type) == "array")' \
        >/dev/null <<< "${DISCOVERY_JSON}"; then
        log_error "Workflow run discovery returned an invalid response."
        return 1
      fi
      if ! DISCOVERY_PAGE_TOTAL=$(jq -er 'length' <<< "${DISCOVERY_JSON}") \
        || ! DISCOVERY_RUN_TOTAL=$(jq -er '[.[].workflow_runs[]] | length' <<< "${DISCOVERY_JSON}"); then
        log_error "Could not calculate workflow run discovery totals."
        return 1
      fi
      return 0
    fi

    if is_transient_failure && (( attempt < MAX_ATTEMPTS )); then
      printf 'Workflow run discovery failed transiently (attempt %d/%d, HTTP %s). Retrying.\n' \
        "${attempt}" "${MAX_ATTEMPTS}" "${API_STATUS:-transport error}" >&2
      sleep_before_retry "${attempt}"
      continue
    fi

    log_error "Workflow run discovery failed after ${attempt} attempt(s) (HTTP ${API_STATUS:-transport error})."
    return 1
  done
}

select_run_ids() {
  local run_id
  local selection_file

  selection_file=$(mktemp)
  if ! jq -r \
    --arg current_run_id "${GITHUB_RUN_ID}" \
    --arg pr_number "${PR_NUMBER}" \
    '
      [.[].workflow_runs[]]
      | [
          .[]
          | select(any(.pull_requests[]?; (.number | tostring) == $pr_number))
          | select(.status != "completed")
          | select((.id | tostring) != $current_run_id)
          | (.id | tostring)
        ]
      | unique[]
    ' <<< "${DISCOVERY_JSON}" >"${selection_file}"; then
    rm -f "${selection_file}"
    log_error "Workflow run filtering failed."
    return 1
  fi

  mapfile -t RUN_IDS <"${selection_file}"
  rm -f "${selection_file}"

  for run_id in "${RUN_IDS[@]}"; do
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
  discover_runs
  printf 'Discovered %s page(s) containing %s workflow run(s).\n' \
    "${DISCOVERY_PAGE_TOTAL}" "${DISCOVERY_RUN_TOTAL}"
  select_run_ids

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
