#!/bin/sh
set -e
cd "$(dirname "$0")"
xcodegen generate
xcodebuild -project StemSplitterMac.xcodeproj -scheme StemSplitter -configuration Release \
  -derivedDataPath .build/dd build
ditto .build/dd/Build/Products/Release/StemSplitter.app /Applications/StemSplitter.app
echo "Installed → /Applications/StemSplitter.app"
