#!/usr/bin/env bash
# Give this job its own git configuration file so that nothing it writes reaches
# `~/.gitconfig`, which every process on the machine shares (PL-378).
#
# The job needs exactly one global setting: a redirect that sends Swift Package
# checkouts over SSH instead of HTTPS. It used to be written with
# `git config --global`, and `finish-xcode-build` undid it afterwards. On a
# machine that runs one CI job alongside agent work under the same user account,
# that is a race with no safe ordering: the job that finishes first removes the
# redirect the still-running job needs, so its remaining SPM checkouts fall back
# to HTTPS and fail, and `--remove-section safe` deletes every `safe.directory`
# entry including ones another job just added. Concurrent `git config --global`
# writes to the same file are not serialized by git either.
#
# `GIT_CONFIG_GLOBAL` moves that file into the job: git reads it instead of
# `~/.gitconfig`, so the redirect is visible to every subprocess the job starts
# (`xcodebuild`, `tuist`, fastlane) and disappears with `$RUNNER_TEMP`. Nothing
# has to be undone, which is why the cleanup steps are gone.
#
# The file is deliberately *not* seeded from `~/.gitconfig`: isolation is the
# point, and copying the user's file in would re-import whatever a concurrently
# running agent wrote moments earlier. `GIT_CONFIG_SYSTEM` is left alone, so
# `/etc/gitconfig` still applies.
#
# `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` would express the
# redirect more precisely, but those variables are inherited by every subprocess:
# a `git config --global <key> <value>` run inside the job — or by any tool that
# shells out to it — would then append to the in-memory list instead of writing
# the file, and the redirect would be silently lost for everything after it.
# `GIT_CONFIG_GLOBAL` keeps `git config --global` behaving normally, writing to
# the per-job file.
set -euo pipefail

runner_temp="${RUNNER_TEMP:?RUNNER_TEMP is not set}"
env_file="${GITHUB_ENV:?GITHUB_ENV is not set}"

# `$RUNNER_TEMP` is emptied by the runner between jobs, so a fixed name cannot
# collide with another job's file.
git_config_global="$runner_temp/gitconfig"

# A leftover file from an earlier attempt in this same job would still hold the
# redirect, so truncating rather than appending keeps the file's contents a
# function of this script alone.
: >"$git_config_global"

# `--file` rather than `--global`: the value of `GIT_CONFIG_GLOBAL` is not read
# by git until it is exported below, so writing through `--global` here would
# target `~/.gitconfig` — the exact file this script exists to keep the job away
# from.
git config --file "$git_config_global" url."git@github.com:".insteadOf "https://github.com/"

# `$GITHUB_ENV` only reaches later steps, so the current shell has to be given the
# value explicitly to prove here that the redirect resolves from the file.
GIT_CONFIG_GLOBAL="$git_config_global" git config --get url."git@github.com:".insteadOf >/dev/null

echo "GIT_CONFIG_GLOBAL=$git_config_global" >>"$env_file"
echo "Swift Package checkouts will use SSH via $git_config_global"
