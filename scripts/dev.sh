#!/bin/zsh
# Boucle de développement rapide (incrémentale) : compile en Debug sur l'architecture active
# (sans relancer xcodegen si project.yml n'a pas changé) et, avec --install, met à jour
# /Applications/Wispad.app avec le même certificat Developer ID pour garder les autorisations macOS
# (micro, accessibilité, surveillance des entrées) sans couper la dictée.
#   scripts/dev.sh                 compile le build Debug incrémental (sans toucher à l'app installée)
#   scripts/dev.sh --install       compile en Debug, signe comme l'app installée et relance /Applications/Wispad.app
#   scripts/dev.sh --install --show   idem et ouvre la fenêtre
#   scripts/dev.sh --install --watch  surveille Sources/ et met à jour automatiquement à chaque sauvegarde
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
SHOW=0
WATCH=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --show) SHOW=1 ;;
    --watch) WATCH=1 ;;
    *) echo "Usage : scripts/dev.sh [--install] [--show] [--watch]" >&2; exit 2 ;;
  esac
done

DEST="${WISPAD_DEST:-/Applications/Wispad.app}"
BUILT="build/DerivedData/Build/Products/Debug/Wispad.app"

dev_sign_identity() {
  if [[ -n "${WISPAD_DEV_SIGN:-}" ]]; then
    print -r -- "$WISPAD_DEV_SIGN"
    return
  fi
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application:/ { print $2; exit }' || true
}

rebuild() {
  local t0=$SECONDS
  if [[ ! -f Wispad.xcodeproj/project.pbxproj || project.yml -nt Wispad.xcodeproj/project.pbxproj ]]; then
    xcodegen generate --quiet
  fi

  local -a extra_args=(ONLY_ACTIVE_ARCH=YES)
  if [[ $INSTALL -eq 1 ]]; then
    local identity=$(dev_sign_identity)
    if [[ -n "$identity" ]]; then
      extra_args+=(CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual)
    fi
  fi

  local log=$(mktemp -t wispad-dev-build)
  if ! xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData \
    "${extra_args[@]}" build > "$log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$log" | head -30 >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
  [[ -d "$BUILT" ]] || { echo "Build Debug introuvable : $BUILT" >&2; return 1; }

  if [[ $INSTALL -eq 0 ]]; then
    echo "Build Debug prêt en $((SECONDS - t0)) s ($BUILT)"
    return 0
  fi

  [[ "$DEST" == *.app && "$(basename "$DEST")" != ".app" ]] || { echo "WISPAD_DEST invalide : $DEST" >&2; return 1; }
  local staged="${DEST%.app}.dev.app"
  rm -rf "$staged"
  ditto "$BUILT" "$staged"

  osascript -e 'tell application id "com.yatofix.wispad" to quit' 2>/dev/null || true
  for _ in {1..16}; do pgrep -xq Wispad || break; sleep 0.15; done
  pkill -x Wispad 2>/dev/null || true

  rm -rf "$DEST"
  mv "$staged" "$DEST"

  if [[ $SHOW -eq 1 ]]; then
    open "$DEST"
  else
    open -g "$DEST" --args --background
  fi
  echo "Wispad dev installé et relancé en $((SECONDS - t0)) s ($DEST)"
}

rebuild

if [[ $WATCH -eq 1 ]]; then
  echo "Surveillance de Sources/ (Ctrl+C pour arrêter)…"
  last_sig=$(find Sources -type f \( -name '*.swift' -o -name '*.xcstrings' \) -exec stat -f '%m %N' {} + | shasum)
  while true; do
    sleep 1
    sig=$(find Sources -type f \( -name '*.swift' -o -name '*.xcstrings' \) -exec stat -f '%m %N' {} + | shasum)
    if [[ "$sig" != "$last_sig" ]]; then
      last_sig="$sig"
      echo "Modification détectée, recompilation…"
      rebuild || true
    fi
  done
fi
