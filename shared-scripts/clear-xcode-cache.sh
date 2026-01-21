#!/bin/bash

# Clear derived data using the shared script
"$(dirname "$0")/clear-xcode-derived-data.sh"

# Clear Swift Package Manager caches
for f in ./*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
    [ -e "$f" ] && rm -rf "$f"
done
[ -e ~/Library/Caches/org.swift.swiftpm ] && rm -rf ~/Library/Caches/org.swift.swiftpm || true
