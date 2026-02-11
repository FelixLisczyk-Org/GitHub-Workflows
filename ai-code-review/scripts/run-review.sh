#!/usr/bin/env bash
set -euo pipefail

# --- Validate required environment variables ---
: "${PR_NUMBER:?PR_NUMBER is required}"
: "${API_KEY:?API_KEY is required}"
: "${MODEL:?MODEL is required}"
: "${PROVIDER:?PROVIDER is required}"
: "${ACTION_PATH:?ACTION_PATH is required}"

echo "::group::AI Code Review Setup"
echo "Provider: ${PROVIDER}"
echo "Model: ${MODEL}"
echo "PR: #${PR_NUMBER}"

# --- Map API key to provider-specific environment variable ---
case "${PROVIDER}" in
  fireworks)   export FIREWORKS_API_KEY="${API_KEY}" ;;
  anthropic)   export ANTHROPIC_API_KEY="${API_KEY}" ;;
  openai)      export OPENAI_API_KEY="${API_KEY}" ;;
  openrouter)  export OPENROUTER_API_KEY="${API_KEY}" ;;
  groq)        export GROQ_API_KEY="${API_KEY}" ;;
  *)
    echo "::warning::Unknown provider '${PROVIDER}', setting generic API key env vars"
    export OPENAI_API_KEY="${API_KEY}"
    ;;
esac

# --- Check if review already exists ---
REVIEW_MARKER="Reviewed by AI using OpenCode"
EXISTING_REVIEW=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json comments --jq ".comments[].body" 2>/dev/null | grep -c "${REVIEW_MARKER}" || true)

if [ "${EXISTING_REVIEW}" -gt 0 ]; then
  echo "AI review comment already exists on PR #${PR_NUMBER}. Skipping."
  echo "::endgroup::"
  exit 0
fi

# --- Fetch PR diff ---
echo "Fetching PR diff..."
DIFF=$(gh pr diff "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" 2>/dev/null || true)

if [ -z "${DIFF}" ]; then
  echo "::warning::No diff found for PR #${PR_NUMBER}. Skipping review."
  echo "::endgroup::"
  exit 0
fi

# Truncate very large diffs to avoid token limits
MAX_DIFF_CHARS=100000
if [ "${#DIFF}" -gt "${MAX_DIFF_CHARS}" ]; then
  echo "::warning::Diff is very large (${#DIFF} chars). Truncating to ${MAX_DIFF_CHARS} chars."
  DIFF="${DIFF:0:${MAX_DIFF_CHARS}}"
  DIFF="${DIFF}

... (diff truncated due to size)"
fi

# --- Fetch PR comments for Linear ticket context ---
echo "Fetching PR comments for ticket context..."
PR_COMMENTS=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json comments --jq '.comments[].body' 2>/dev/null || true)

# Extract Linear bot comment (usually contains ticket description)
LINEAR_CONTEXT=""
if [ -n "${PR_COMMENTS}" ]; then
  LINEAR_CONTEXT=$(echo "${PR_COMMENTS}" | grep -A 1000 -i "linear" | head -200 || true)
fi

# Also get PR body which often contains ticket links
PR_BODY=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null || true)

echo "::endgroup::"

# --- Write PR context to temp file (avoids CLI argument length limits) ---
CONTEXT_FILE=$(mktemp --suffix=.md)
cat > "${CONTEXT_FILE}" <<CTXEOF
## PR Information

PR #${PR_NUMBER} in ${GITHUB_REPOSITORY}

### PR Description
${PR_BODY:-No PR description provided.}

### Ticket Context (from PR comments)
${LINEAR_CONTEXT:-No Linear ticket context found in PR comments. Proceed with review based on the diff alone.}

### PR Diff
\`\`\`diff
${DIFF}
\`\`\`
CTXEOF

echo "Context file: $(wc -c < "${CONTEXT_FILE}") bytes"

# --- Configure OpenCode ---
export OPENCODE_DISABLE_PROJECT_CONFIG=true
export OPENCODE_DISABLE_AUTOUPDATE=true

export OPENCODE_CONFIG_CONTENT=$(cat <<JSONEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "${MODEL}"
}
JSONEOF
)

# --- Run OpenCode ---
echo "::group::Running AI Code Review"
echo "Running OpenCode in headless mode..."

REVIEW_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

# Attach context and guidelines as files to avoid argument length limits
opencode run \
  --file "${CONTEXT_FILE}" \
  --file "${ACTION_PATH}/review-guidelines.md" \
  "You are performing an AI code review on a pull request.

Read the two attached files:
1. The first file contains the PR description, ticket context, and diff.
2. The second file contains the review guidelines and output format.

Instructions:
1. Read the diff carefully.
2. For each changed file, use the file read tools to explore the surrounding code for context.
3. If ticket context was found, compare changes against ticket requirements.
4. Apply the review guidelines and verification checklist to identify issues.
5. Output your review in the exact Markdown format specified in the review guidelines.
6. Focus on the most impactful issues. Prioritize potential bugs and security issues.
7. If the code looks good, say so briefly and still provide the requirements verification section.
8. Do NOT suggest purely stylistic changes not covered by the guidelines.
9. Output ONLY the review Markdown — no preamble, no explanation outside the format." \
  > "${REVIEW_FILE}" 2>"${STDERR_FILE}" || true

# Show stderr for debugging (visible in GitHub Actions logs)
if [ -s "${STDERR_FILE}" ]; then
  echo "::warning::OpenCode stderr output:"
  cat "${STDERR_FILE}"
fi

rm -f "${CONTEXT_FILE}" "${STDERR_FILE}"
echo "::endgroup::"

# --- Validate output ---
if [ ! -s "${REVIEW_FILE}" ]; then
  echo "::warning::OpenCode produced no review output."
  rm -f "${REVIEW_FILE}"
  exit 1
fi

echo "::group::Posting Review Comment"
echo "Posting review comment to PR #${PR_NUMBER}..."
gh pr comment "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --body-file "${REVIEW_FILE}"
echo "Review comment posted successfully."
echo "::endgroup::"

# Cleanup
rm -f "${REVIEW_FILE}"
