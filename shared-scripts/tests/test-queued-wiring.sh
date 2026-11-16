#!/usr/bin/env bash
# Asserts that every build, test, generate and update command in the composite actions runs
# through `shared-scripts/queued.sh`, so on the self-hosted runner it goes through
# xcodebuildmcp-queue instead of building next to the agents' queued jobs (PL-480).
#
# A new Fastlane/xcodebuild/tuist-generate/generate.sh/swift-test invocation added without the
# wrapper fails here rather than silently bringing back concurrent builds.
set -u -o pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly REPO_ROOT
readonly ACTIONS=(xcode-test-app xcode-build-app xcode-update-app xcode-test-package xcode-update-package submit-app)

for action in "${ACTIONS[@]}"; do
  ruby -ryaml -e '
    action = ARGV[0]
    path = File.join(ARGV[1], action, "action.yml")
    steps = YAML.load_file(path)["runs"]["steps"]
    build_command = %r{bundle exec fastlane|\bxcodebuild\s|tuist generate|\./generate\.sh|\bswift test\b}
    wrapper = "${{ github.action_path }}/../shared-scripts/queued.sh "
    failures = []
    wrapped = 0

    steps.each do |step|
      step["run"].to_s.each_line do |line|
        # A match can sit after `&&`, so look at each command on the line, not the line start.
        line.split(/&&|\|\||;/).each do |command|
          next unless command.match?(build_command)
          if command.strip.start_with?(wrapper)
            wrapped += 1
          else
            failures << "#{step["name"].inspect} runs #{command.strip.inspect} outside queued.sh"
          end
        end
      end
    end

    failures << "no build command found - the matcher is probably wrong" if wrapped.zero?

    unless failures.empty?
      failures.each { |failure| warn "not ok - #{action}: #{failure}" }
      exit 1
    end

    puts "ok - #{action}: all #{wrapped} build commands run through queued.sh"
  ' "$action" "$REPO_ROOT" || exit 1
done

# The recovery in `check-build-errors.py` regenerates the project itself before a retry, so its
# generation must be queued too.
recovery="${REPO_ROOT}/shared-scripts/check-build-errors.py"
unqueued=$(grep -nE 'os\.system\(.*(generate\.sh|tuist generate)' "${recovery}" | grep -vF '{queued} ' || true)
[[ -z "${unqueued}" ]] ||
  { printf 'not ok - check-build-errors.py regenerates outside queued.sh:\n%s\n' "${unqueued}" >&2; exit 1; }
[[ $(grep -cE 'os\.system\(.*\{queued\} (\./generate\.sh|tuist generate)' "${recovery}") -eq 2 ]] ||
  { printf 'not ok - expected both regeneration paths in check-build-errors.py to use queued.sh\n' >&2; exit 1; }
printf 'ok - check-build-errors.py regenerates through queued.sh\n'

[[ -x "${REPO_ROOT}/shared-scripts/queued.sh" ]] ||
  { printf 'not ok - queued.sh is not executable\n' >&2; exit 1; }
printf 'ok - queued.sh is executable\n'
