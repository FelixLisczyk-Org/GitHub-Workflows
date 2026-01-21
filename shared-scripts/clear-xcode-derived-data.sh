#!/bin/bash

# This approach is more reliable than using 'xcodebuild -showBuildSettings' because the latter is slow and doesn't return a value if it cannot resolve project dependencies.
PROJECT_NAME=$(basename "$(find . -maxdepth 1 -name '*.xcodeproj' | head -n 1)" .xcodeproj)
if [ -n "$PROJECT_NAME" ]; then
    CUSTOM_DERIVED_DATA=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation)
    if [ -n "$CUSTOM_DERIVED_DATA" ]; then
        DERIVED_DATA_PATH=$(find "$CUSTOM_DERIVED_DATA" -maxdepth 1 -type d -name "${PROJECT_NAME}-*" | head -n 1)
    else
        DERIVED_DATA_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name "${PROJECT_NAME}-*" | head -n 1)
    fi
    if [ -n "$DERIVED_DATA_PATH" ] && [ -e "$DERIVED_DATA_PATH" ]; then
        echo "Deleting derived data at: $DERIVED_DATA_PATH"
        rm -rf "$DERIVED_DATA_PATH"
    fi
fi
