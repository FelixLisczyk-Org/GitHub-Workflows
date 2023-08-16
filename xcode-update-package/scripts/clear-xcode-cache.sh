#!/bin/bash

rm -rf "$(xcodebuild -showBuildSettings -disableAutomaticPackageResolution -skipPackageUpdates | grep -m 1 BUILD_DIR | grep -oE "\/.*" | sed 's|/Build/Products||')"
rm -rf ./*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
rm -rf ~/Library/Caches/org.swift.swiftpm