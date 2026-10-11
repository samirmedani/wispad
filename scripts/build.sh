#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData build
