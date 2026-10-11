#!/bin/zsh
# Vérification complète avant un commit important ou une livraison, sans réseau ni fenêtre :
# tests locaux, traductions anglaises complètes, puis compilation de la version Release.
#   scripts/check.sh            tout
#   scripts/check.sh --fast     tests et traductions, sans la compilation Release
set -euo pipefail
cd "$(dirname "$0")/.."
step() { print -P "%B== $1%b" }

step "Tests locaux"
scripts/test.sh 2>&1 | grep -E "Test run with|tests skipped|error:|✘" | sort -u

step "Traductions"
scripts/localize.sh check

if [[ "${1:-}" != "--fast" ]]; then
  step "Compilation Release (sans outils de développement)"
  xcodegen generate --quiet
  xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
  if nm build/DerivedData/Build/Products/Release/Wispad.app/Contents/MacOS/Wispad | grep -qE 'DesignPreview|DevTools'; then
    print -u2 "Outils de développement présents dans la version Release."
    exit 1
  fi
fi
step "Tout est vert."
