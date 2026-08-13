#!/usr/bin/env bash

set -euo pipefail

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT

cd "$workspace"
git init -q
git config user.email test@example.com
git config user.name test
mkdir -p Tuist build Derived
printf '%s\n' '{"pins":[]}' > Tuist/Package.resolved
git add Tuist/Package.resolved
git commit -qm initial

mkdir -p Tuist/.build/checkouts/Package
printf '%s\n' cache > Tuist/.build/checkouts/Package/state
printf '%s\n' ignored > build/output
printf '%s\n' ignored > Derived/output
printf '%s\n' untracked > workspace-file
printf '%s\n' changed > Tuist/Package.resolved

git reset --hard >/dev/null
git clean -ffdx -e Tuist/.build >/dev/null

[[ -f Tuist/Package.resolved ]]
[[ -f Tuist/.build/checkouts/Package/state ]]
[[ ! -e build ]]
[[ ! -e Derived ]]
[[ ! -e workspace-file ]]

marker='Tuist/.build/.package-resolved-hash'
package_hash=$(git hash-object Tuist/Package.resolved)
printf '%s\n' "$package_hash" > "$marker"
[[ "$(<"$marker")" == "$package_hash" ]]
printf '%s\n' stale > "$marker"
[[ "$(<"$marker")" != "$package_hash" ]]

printf '%s\n' 'Tuist cache cleanup and marker checks passed.'
