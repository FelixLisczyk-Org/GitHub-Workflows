#!/bin/bash

# PL-377: DerivedData cleanup is workspace-scoped. The Studio runs CI alongside agent
# and manual work as the same user, and DerivedData directory names embed a hash of the
# workspace path, so separate CI/agent/worktree checkouts of the same project receive
# distinct directories. Deleting every `<ProjectName>-*` directory would therefore also
# destroy build products owned by other checkouts and interactive Xcode sessions, so a
# directory is deleted only when its own `info.plist` records a workspace path inside
# the current checkout.

# This approach is more reliable than using 'xcodebuild -showBuildSettings' because the latter is slow and doesn't return a value if it cannot resolve project dependencies.
PROJECT_NAME=$(basename "$(find . -maxdepth 1 -name '*.xcodeproj' | head -n 1)" .xcodeproj)
if [ -z "$PROJECT_NAME" ]; then
    exit 0
fi
# Xcode replaces spaces in project names with underscores for DerivedData directories.
DERIVED_DATA_PROJECT_NAME=${PROJECT_NAME// /_}
CUSTOM_DERIVED_DATA=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null)
if [ -n "$CUSTOM_DERIVED_DATA" ]; then
    DERIVED_DATA_BASE="$CUSTOM_DERIVED_DATA"
else
    DERIVED_DATA_BASE="$HOME/Library/Developer/Xcode/DerivedData"
fi

# The ownership boundary: the CI checkout being recovered, or the current directory
# when the script runs outside GitHub Actions.
BOUNDARY=$(cd "${GITHUB_WORKSPACE:-$(pwd)}" && pwd -P)

resolve() {
    (cd "$1" 2>/dev/null && pwd -P)
}

find "$DERIVED_DATA_BASE" -maxdepth 1 -type d -name "${DERIVED_DATA_PROJECT_NAME}-*" | while IFS= read -r DERIVED_DATA_PATH; do
    WORKSPACE_PATH=$(plutil -extract WorkspacePath raw -o - "$DERIVED_DATA_PATH/info.plist" 2>/dev/null)
    if [ -z "$WORKSPACE_PATH" ]; then
        echo "Skipping $DERIVED_DATA_PATH: its info.plist does not record a WorkspacePath"
        continue
    fi
    RESOLVED=$(resolve "$WORKSPACE_PATH")
    if [ -z "$RESOLVED" ]; then
        echo "Skipping $DERIVED_DATA_PATH: recorded workspace path '$WORKSPACE_PATH' does not exist"
        continue
    fi
    case "$RESOLVED/" in
        "$BOUNDARY"/*)
            echo "Deleting derived data at: $DERIVED_DATA_PATH"
            rm -rf "$DERIVED_DATA_PATH"
            ;;
        *)
            echo "Skipping $DERIVED_DATA_PATH: its workspace $RESOLVED is outside $BOUNDARY"
            ;;
    esac
done
