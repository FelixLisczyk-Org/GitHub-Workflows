# Shared-Workflows

This repository contains reusable workflows and composite actions for other repositories.

# Caveats

* Use `if: job.status == 'failure'` instead of `if: failure()` in composite actions to read the global job status.
* Run bash scripts with a login shell to load `.bash_profile`: `shell: bash -leo pipefail {0}`
* A login shell also loads the user profile, which redefines `rm` as a wrapper around `trash`. Unlike `rm -rf`, `trash` fails on a path that does not exist, and it fills the runner's Trash with regenerable build artifacts. Use `command rm` in composite actions to bypass the wrapper.

# Xcode selection

`select-xcode` picks the newest stable Xcode (the newest beta on `beta`) and exports it as `DEVELOPER_DIR` into `$GITHUB_ENV`. It deliberately does **not** run `xcode-select -s`, which changes the developer directory **machine-wide**: with a stable Xcode and several betas installed, two jobs on the same Mac each select their own and silently swap the toolchain under each other mid-build, and a finishing job restores the directory captured at *its own* start, stomping a job that is still running.

`DEVELOPER_DIR` is inherited by the job's process tree — `xcodebuild`, `xcrun` and fastlane all honour it — and disappears with the job. That is why there is no restore step and no root password. Note that a `$GITHUB_ENV` write does not affect the shell that made it, so the selection step passes the value to `xcodebuild -version` explicitly to verify it.

# Queued build commands

The self-hosted runner shares its build machine with coding agents, whose builds go through `xcodebuildmcp-queue`. A CI build outside that queue runs alongside whatever the queue admitted, and both slow down ([PL-480](https://linear.app/fl-app-development/issue/PL-480)). Every build, test, generate and update command in the composite actions (`bundle exec fastlane …`, `xcodebuild …`, `swift test`, `tuist generate`, `./generate.sh`) therefore runs through `shared-scripts/queued.sh`:

```yaml
run: ${{ github.action_path }}/../shared-scripts/queued.sh bundle exec fastlane ${{ inputs.platform }} tests
```

- When `xcodebuildmcp-queue` is on `PATH` (the self-hosted runner), the wrapper runs the command as `xcodebuildmcp-queue queue run -- <command>`. Output, exit status and the step's environment pass through unchanged. GitHub-hosted runners have no queue, so there the command runs directly. A self-hosted runner (`RUNNER_ENVIRONMENT=self-hosted`) without `xcodebuildmcp-queue` on `PATH` fails the step with exit code 72 instead, because building outside the queue there would bring back the contention silently.
- The wrapper exports `XCODEBUILDMCP_QUEUE_TIMEOUT_SECONDS=5700` (the queue's 90-minute execution timeout plus five minutes) unless the step sets its own. `~/actions-runner/_work` is a priority folder in the queue, so a step should only wait for the job already running; a longer wait fails with exit code 71 (queue timeout) rather than running into the job's `timeout-minutes`. A job's `timeout-minutes` must cover that wait plus its own run time.
- Wrap the build command itself, not the step: shell logic such as `if [ -f Tuist.swift ]` and pipes such as `| xcbeautify` stay in the step. Pass environment variables through the step's `env:` instead of a `VAR=value command` prefix, since the queue runs a single executable. Dependency resolution (`tuist install`, `swift package update`) is not a build and stays unwrapped.
- Cancelling a run kills the queue proxy; the queue then cancels the job and terminates its whole process tree, including `xcodebuild`.

`shared-scripts/tests/test-queued-wiring.sh` fails when a build command in any of the six build actions runs outside the wrapper, and `shared-scripts/tests/test-queued.sh` covers the wrapper itself.

# Build log scoping

Every platform step in a job shares one `log` directory, and nothing clears it between steps — `prepare-xcode-build` only wipes it once per job. Fastlane's `scan` writes `log/<Product>-<Scheme>.log` and `log/<Scheme>.xcresult` per invocation, so by the time a later step fails, the directory also holds the logs of the earlier steps that passed.

`shared-scripts/scope-build-logs.sh` exports `CI_LOG_SCOPE_EPOCH` (a float Unix timestamp) so `check-build-errors.py` and `show-test-failures.py` only read the entries modified at or after it. **Run it immediately before every Fastlane/xcodebuild invocation, including every retry, guarded by the same `if:` condition as the invocation itself.** `shared-scripts/tests/test-log-scope-wiring.sh` enforces this across all four actions.

Without the marker both scripts fall back to scanning the whole directory, which is how a benign `[cloudthumbnails.client] getattrlist() failed ... No such file or directory` line in a *passing* macOS log once made the watchOS step clear its Tuist cache and rerun the lane twice ([PL-384](https://linear.app/fl-app-development/issue/PL-384/check-build-errorspy-retries-on-failures-a-retry-cannot-fix-costing-40)).

Two related rules for `check-build-errors.py`:

* Patterns match as case-insensitive substrings; use a compiled `re.Pattern` when a substring is too blunt to separate a real diagnostic from log noise. Build logs carry a lot of OS chatter that reads like an error.
* A test failure that no pattern explains suppresses the retry entirely. A failing assertion produces the same failure on every rerun, so recovering from one only multiplies the cost of a build that was always going to be red.

# Debug

Print GitHub context variables:

```
- name: Dump GitHub context
  run: echo '${{ toJSON(github) }}'
- name: Dump job context
  run: echo '${{ toJSON(job) }}'
- name: Dump steps context
  run: echo '${{ toJSON(steps) }}'
- name: Dump runner context
  run: echo '${{ toJSON(runner) }}'
```

# Resources

https://docs.github.com/en/actions/using-workflows/reusing-workflows

https://docs.github.com/en/actions/creating-actions/creating-a-composite-action

https://docs.github.com/en/actions/learn-github-actions/contexts

https://docs.github.com/en/actions/learn-github-actions/expressions