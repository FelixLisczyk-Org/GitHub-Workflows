#!/bin/bash

# Clear derived data using the shared script
"$(dirname "$0")/clear-xcode-derived-data.sh"

# Clear Swift Package Manager caches
rm -rf ./*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true
rm -rf ~/Library/Caches/org.swift.swiftpm 2>/dev/null || true
