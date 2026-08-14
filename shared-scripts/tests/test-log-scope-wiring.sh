#!/usr/bin/env bash
# Asserts the contract `check-build-errors.py` and `show-test-failures.py` rely on: every
# Fastlane/xcodebuild invocation in a composite action is immediately preceded by a
# "Scope Build Logs" step guarded by the same condition.
#
# Without that marker an analysis step falls back to reading the whole shared `log`
# directory, which is how a passing platform's build log came to trigger another
# platform's Tuist cache rebuild and two pointless lane reruns.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly ACTIONS=(xcode-test-app xcode-build-app xcode-update-app xcode-test-package)

for action in "${ACTIONS[@]}"; do
  ruby -ryaml -e '
    action = ARGV[0]
    path = File.join(ARGV[1], action, "action.yml")
    steps = YAML.load_file(path)["runs"]["steps"]
    failures = []
    scoped = 0

    steps.each_with_index do |step, index|
      run = step["run"].to_s
      next unless run.match?(/bundle exec fastlane|xcodebuild /)

      name = step["name"].to_s
      previous = index.zero? ? nil : steps[index - 1]

      if previous.nil? || !previous["name"].to_s.start_with?("Scope Build Logs")
        failures << "#{name.inspect} is not preceded by a Scope Build Logs step"
        next
      end

      if previous["run"].to_s !~ %r{shared-scripts/scope-build-logs\.sh}
        failures << "the Scope Build Logs step before #{name.inspect} does not run scope-build-logs.sh"
        next
      end

      if previous["if"].to_s != step["if"].to_s
        failures << "the Scope Build Logs step before #{name.inspect} has condition " \
                    "#{previous["if"].inspect}, expected #{step["if"].inspect}"
        next
      end

      scoped += 1
    end

    if scoped.zero?
      failures << "no Fastlane/xcodebuild invocation found - the matcher is probably wrong"
    end

    unless failures.empty?
      failures.each { |failure| warn "not ok - #{action}: #{failure}" }
      exit 1
    end

    puts "ok - #{action}: all #{scoped} invocations are preceded by a matching scope marker"
  ' "$action" "$REPO_ROOT" || exit 1
done

# The marker has to be readable by the analysis scripts, so keep the contract in one place.
grep -Fq 'CI_LOG_SCOPE_EPOCH' "${REPO_ROOT}/shared-scripts/scope-build-logs.sh" ||
  { printf 'not ok - scope-build-logs.sh does not export CI_LOG_SCOPE_EPOCH\n' >&2; exit 1; }
grep -Fq 'CI_LOG_SCOPE_EPOCH' "${REPO_ROOT}/shared-scripts/log_scope.py" ||
  { printf 'not ok - log_scope.py does not read CI_LOG_SCOPE_EPOCH\n' >&2; exit 1; }
printf 'ok - the scope marker variable is shared by the writer and the readers\n'

[[ -x "${REPO_ROOT}/shared-scripts/scope-build-logs.sh" ]] ||
  { printf 'not ok - scope-build-logs.sh is not executable\n' >&2; exit 1; }
printf 'ok - scope-build-logs.sh is executable\n'
