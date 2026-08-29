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
  fireworks-ai) export FIREWORKS_API_KEY="${API_KEY}" ;;
  anthropic)    export ANTHROPIC_API_KEY="${API_KEY}" ;;
  openai)       export OPENAI_API_KEY="${API_KEY}" ;;
  openrouter)   export OPENROUTER_API_KEY="${API_KEY}" ;;
  groq)         export GROQ_API_KEY="${API_KEY}" ;;
  ollama)       export OLLAMA_API_KEY="${API_KEY}" ;;
  *)
    echo "::warning::Unknown provider '${PROVIDER}', setting generic API key env vars"
    export OPENAI_API_KEY="${API_KEY}"
    ;;
esac

# --- Check if review already exists ---
# The hidden marker is appended by this script, so it is present on every posted
# review even when the model omits the visible "Reviewed by AI" footer. The
# footer is still matched so reviews posted before the marker existed count too.
REVIEW_STICKY_MARKER="<!-- ai-code-review -->"
REVIEW_FOOTER_MARKER="Reviewed by AI using OpenCode"
EXISTING_REVIEW=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json comments --jq ".comments[].body" 2>/dev/null | grep -c -e "${REVIEW_STICKY_MARKER}" -e "${REVIEW_FOOTER_MARKER}" || true)

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
PR_COMMENTS=""
LINEAR_CONTEXT=""
for attempt in 1 2 3 4; do
  PR_COMMENTS=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json comments --jq '.comments[].body' 2>/dev/null || true)

  if [ -n "${PR_COMMENTS}" ]; then
    LINEAR_CONTEXT=$(echo "${PR_COMMENTS}" | grep -A 1000 -i "linear" | head -200 || true)
    if [ -n "${LINEAR_CONTEXT}" ]; then
      echo "Found Linear ticket context on attempt ${attempt}."
      break
    fi
  fi

  if [ "${attempt}" -lt 4 ]; then
    echo "Linear ticket context not available yet (attempt ${attempt}/4). Retrying in 30s..."
    sleep 30
  fi
done

# Also get PR body which often contains ticket links
PR_BODY=$(gh pr view "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --json body --jq '.body' 2>/dev/null || true)

echo "::endgroup::"

# --- Write PR context to workspace file for OpenCode to read ---
CONTEXT_FILE="${GITHUB_WORKSPACE}/.ai-review-context.md"
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

# Copy guidelines into workspace so OpenCode can read without external_directory permission
GUIDELINES_FILE="${GITHUB_WORKSPACE}/.ai-review-guidelines.md"
cp "${ACTION_PATH}/review-guidelines.md" "${GUIDELINES_FILE}"
echo "Context file: $(wc -c < "${CONTEXT_FILE}") bytes"

# --- Configure OpenCode ---
export OPENCODE_DISABLE_PROJECT_CONFIG=true
export OPENCODE_DISABLE_AUTOUPDATE=true

# Disable session-title generation so headless reviews do not make an auxiliary
# model request. Pin the small model to the review model as a fallback in case
# title generation is re-enabled later.
if [ "${PROVIDER}" = "ollama" ]; then
  export OPENCODE_CONFIG_CONTENT=$(cat <<JSONEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": {
      "disable": true
    }
  },
  "tools": {
    "bash": false
  },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Cloud",
      "options": {
        "baseURL": "https://ollama.com/v1",
        "apiKey": "${API_KEY}"
      },
      "models": {
        "${MODEL}": { "name": "${MODEL}" }
      }
    }
  },
  "model": "ollama/${MODEL}",
  "small_model": "ollama/${MODEL}"
}
JSONEOF
)
elif [ "${PROVIDER}" = "openrouter" ]; then
  OPENROUTER_MODEL="${MODEL#openrouter/}"

  export OPENCODE_CONFIG_CONTENT=$(cat <<JSONEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": {
      "disable": true
    }
  },
  "tools": {
    "bash": false
  },
  "provider": {
    "openrouter": {
      "models": {
        "${OPENROUTER_MODEL}": {
          "variants": {
            "max": {
              "reasoningEffort": "xhigh"
            }
          }
        }
      }
    }
  },
  "model": "openrouter/${OPENROUTER_MODEL}",
  "small_model": "openrouter/${OPENROUTER_MODEL}"
}
JSONEOF
)
elif [ "${PROVIDER}" = "fireworks-ai" ]; then
  FIREWORKS_MODEL="${MODEL#fireworks-ai/}"

  export OPENCODE_CONFIG_CONTENT=$(cat <<JSONEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": {
      "disable": true
    }
  },
  "tools": {
    "bash": false
  },
  "provider": {
    "fireworks-ai": {
      "models": {
        "${FIREWORKS_MODEL}": {
          "variants": {
            "max": {
              "reasoningEffort": "xhigh"
            }
          }
        }
      }
    }
  },
  "model": "fireworks-ai/${FIREWORKS_MODEL}",
  "small_model": "fireworks-ai/${FIREWORKS_MODEL}"
}
JSONEOF
)
else
  export OPENCODE_CONFIG_CONTENT=$(cat <<JSONEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "agent": {
    "title": {
      "disable": true
    }
  },
  "tools": {
    "bash": false
  },
  "model": "${MODEL}",
  "small_model": "${MODEL}"
}
JSONEOF
)
fi

# --- Run OpenCode ---
echo "::group::Running AI Code Review"
echo "Running OpenCode in headless mode..."

REVIEW_FILE=$(mktemp)
STDERR_FILE=$(mktemp)

WORKSPACE_CONTEXT_FILE=".ai-review-context.md"
WORKSPACE_GUIDELINES_FILE=".ai-review-guidelines.md"

echo "::group::OpenCode Environment"
echo "OpenCode version: $(opencode --version 2>/dev/null || echo unavailable)"
echo "Initial working directory: $(pwd)"
echo "GITHUB_WORKSPACE: ${GITHUB_WORKSPACE}"
echo "ACTION_PATH: ${ACTION_PATH}"
cd "${GITHUB_WORKSPACE}"
echo "Working directory after cd: $(pwd)"
echo "Workspace context file present: $(test -f "${WORKSPACE_CONTEXT_FILE}" && echo yes || echo no)"
echo "Workspace guidelines file present: $(test -f "${WORKSPACE_GUIDELINES_FILE}" && echo yes || echo no)"
echo "::endgroup::"

# Pass a short prompt; OpenCode reads context via its own file tools.
# The model occasionally ends its turn after a few tool calls without emitting
# the final review Markdown — typically leaving stdout empty, but sometimes
# leaving only a line of preamble ("Let me check X first...") when a rejected
# tool call cuts the turn short. Both cases are incomplete turns, so an attempt
# only counts as successful once the review headline is present. Retry a few
# times before giving up so a single incomplete turn doesn't waste the run.
REVIEW_PROMPT="You are performing an AI code review on a pull request. Read the file at ${WORKSPACE_CONTEXT_FILE} for the PR description, ticket context, and diff. Read the file at ${WORKSPACE_GUIDELINES_FILE} for review guidelines and output format. Then: 1) For each changed file in the diff, use your read tools to explore surrounding code for context. 2) Apply the review guidelines to identify issues. 3) Output ONLY the review Markdown in the format specified in the guidelines — no preamble. Only files inside the repository are readable; tool calls outside it are rejected. If a tool call fails, continue with the context you have and still emit the full review."

REVIEW_HEADLINE_PATTERN='^## AI Code Review'
MAX_REVIEW_ATTEMPTS=3
REVIEW_COMPLETE=false

for attempt in $(seq 1 "${MAX_REVIEW_ATTEMPTS}"); do
  echo "Running OpenCode (attempt ${attempt}/${MAX_REVIEW_ATTEMPTS})..."

  : > "${REVIEW_FILE}"
  : > "${STDERR_FILE}"

  opencode run \
    --variant max \
    "${REVIEW_PROMPT}" \
    > "${REVIEW_FILE}" 2>"${STDERR_FILE}" || true

  # Show stderr for debugging (visible in GitHub Actions logs)
  if [ -s "${STDERR_FILE}" ]; then
    echo "::warning::OpenCode stderr output:"
    cat "${STDERR_FILE}"
  fi

  if [ ! -s "${REVIEW_FILE}" ]; then
    echo "::warning::OpenCode produced no review output (attempt ${attempt}/${MAX_REVIEW_ATTEMPTS})."
  elif ! grep -q "${REVIEW_HEADLINE_PATTERN}" "${REVIEW_FILE}"; then
    echo "::warning::OpenCode output has no '## AI Code Review' headline (attempt ${attempt}/${MAX_REVIEW_ATTEMPTS}). Discarding it as an incomplete turn."
    echo "Discarded output (first 500 chars):"
    head -c 500 "${REVIEW_FILE}"
    echo
  else
    echo "OpenCode produced a complete review on attempt ${attempt}."
    REVIEW_COMPLETE=true
    break
  fi

  if [ "${attempt}" -lt "${MAX_REVIEW_ATTEMPTS}" ]; then
    echo "Retrying in 10s..."
    sleep 10
  fi
done

rm -f "${CONTEXT_FILE}" "${STDERR_FILE}"
echo "::endgroup::"

# --- Validate output ---
# Nothing is posted unless a complete review was produced. Posting an incomplete
# turn leaves preamble noise on the PR and, worse, no marker for the dedup check
# above, so every re-run would pile on another junk comment.
if [ "${REVIEW_COMPLETE}" != "true" ]; then
  echo "::warning::OpenCode did not produce a complete review after ${MAX_REVIEW_ATTEMPTS} attempts. Nothing posted."
  rm -f "${REVIEW_FILE}"
  exit 1
fi

# --- Strip preamble text before the review headline ---
# OpenCode may output "thinking" text before the actual review Markdown.
# Find the first Markdown headline (## AI Code Review) and discard everything before it.
HEADLINE_LINE=$(grep -n "${REVIEW_HEADLINE_PATTERN}" "${REVIEW_FILE}" | head -1 | cut -d: -f1)
tail -n "+${HEADLINE_LINE}" "${REVIEW_FILE}" > "${REVIEW_FILE}.trimmed"
mv "${REVIEW_FILE}.trimmed" "${REVIEW_FILE}"

# Append the hidden marker so the dedup check recognises this review on re-runs.
printf '\n%s\n' "${REVIEW_STICKY_MARKER}" >> "${REVIEW_FILE}"

echo "::group::Posting Review Comment"
echo "Posting review comment to PR #${PR_NUMBER}..."
gh pr comment "${PR_NUMBER}" --repo "${GITHUB_REPOSITORY}" --body-file "${REVIEW_FILE}"
echo "Review comment posted successfully."
echo "::endgroup::"

# Cleanup
rm -f "${REVIEW_FILE}" "${GUIDELINES_FILE}"
