#!/bin/zsh
# Boucle de développement rapide (incrémentale) : recompile uniquement ce qui a changé en Debug
# (architecture active seulement, sans relancer xcodegen inutilement) et relance Wispad en quelques secondes.
#   scripts/dev.sh                 compile et relance en arrière-plan
#   scripts/dev.sh --show          compile, relance et ouvre la fenêtre
#   scripts/dev.sh --watch         surveille Sources/ et relance automatiquement à chaque modification
set -euo pipefail
cd "$(dirname "$0")/.."

SHOW=0
WATCH=0
for arg in "$@"; do
  case "$arg" in
    --show) SHOW=1 ;;
    --watch) WATCH=1 ;;
    *) echo "Usage : scripts/dev.sh [--show] [--watch]" >&2; exit 2 ;;
  esac
done

APP="build/DerivedData/Build/Products/Debug/Wispad.app"

rebuild_and_launch() {
  local t0=$SECONDS
  if [[ ! -f Wispad.xcodeproj/project.pbxproj || project.yml -nt Wispad.xcodeproj/project.pbxproj ]]; then
    xcodegen generate --quiet
  fi
  local log=$(mktemp -t wispad-dev-build)
  if ! xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    ONLY_ACTIVE_ARCH=YES build > "$log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$log" | head -30 >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  [[ -d "$APP" ]] || { echo "Build Debug introuvable : $APP" >&2; return 1; }

  for bundle in com.yatofix.wispad; do
    osascript -e "tell application id \"$bundle\" to quit" 2>/dev/null || true
  done
  for _ in {1..16}; do pgrep -xq Wispad || break; sleep 0.15; done
  pkill -x Wispad 2>/dev/null || true

  if [[ $SHOW -eq 1 ]]; then
    open "$APP"
  else
    open -g "$APP" --args --background
  fi
  echo "Wispad dev prêt en $((SECONDS - t0)) s ($APP)"
}

rebuild_and_launch

if [[ $WATCH -eq 1 ]]; then
  echo "Surveillance de Sources/ (Ctrl+C pour arrêter)…"
  last_sig=$(find Sources -type f \( -name '*.swift' -o -name '*.xcstrings' \) -exec stat -f '%m %N' {} + | shasum)
  while true; do
    sleep 1
    sig=$(find Sources -type f \( -name '*.swift' -o -name '*.xcstrings' \) -exec stat -f '%m %N' {} + | shasum)
    if [[ "$sig" != "$last_sig" ]]; then
      last_sig="$sig"
      echo "Modification détectée, recompilation…"
      rebuild_and_launch || true
    fi
  done
fi
