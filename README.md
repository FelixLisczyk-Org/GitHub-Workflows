# Shared-Workflows

This repository contains reusable workflows and composite actions for other repositories.

# Caveats

* Use `if: job.status == 'failure'` instead of `if: failure()` in composite actions to read the global job status.
* Run bash scripts with a login shell to load `.bash_profile`: `shell: bash -leo pipefail {0}`
* A login shell also loads the user profile, which redefines `rm` as a wrapper around `trash`. Unlike `rm -rf`, `trash` fails on a path that does not exist, and it fills the runner's Trash with regenerable build artifacts. Use `command rm` in composite actions to bypass the wrapper.

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