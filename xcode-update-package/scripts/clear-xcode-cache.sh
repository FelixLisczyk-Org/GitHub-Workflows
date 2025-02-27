#!/bin/bash

# This approach is more reliable than using 'xcodebuild -showBuildSettings' because the latter is slow and doesn't return a value if it cannot resolve project dependencies.
PROJECT_NAME=$(basename "$(find . -maxdepth 1 -name '*-HostApp.xcodeproj' | head -n 1)" .xcodeproj)
if [ -n "$PROJECT_NAME" ]; then
    CUSTOM_DERIVED_DATA=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation)
    if [ -n "$CUSTOM_DERIVED_DATA" ]; then
        DERIVED_DATA_PATH=$(find "$CUSTOM_DERIVED_DATA" -maxdepth 1 -type d -name "${PROJECT_NAME}-*" | head -n 1)
    else
        DERIVED_DATA_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name "${PROJECT_NAME}-*" | head -n 1)
    fi
    rm -rf "$DERIVED_DATA_PATH"
fi
rm -rf ./*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
rm -rf ~/Library/Caches/org.swift.swiftpm
