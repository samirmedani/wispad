#!/bin/zsh
# Compile Wispad en Release (optimisé) et l'installe dans /Applications : c'est l'app de tous les jours.
# Les autorisations (micro, accessibilité, surveillance des entrées) suivent l'app : même identifiant,
# même signature. scripts/build.sh reste le build Debug de développement.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="${WISPAD_DEST:-/Applications/Wispad.app}"
BUILT="build/DerivedData/Build/Products/Release/Wispad.app"
# Garde-fou : on ne remplace jamais autre chose qu'un paquet .app (pas /Applications tout entier).
[[ "$DEST" == *.app && "$(basename "$DEST")" != ".app" ]] || { echo "WISPAD_DEST doit désigner un paquet .app : $DEST" >&2; exit 1; }

xcodegen generate
xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Release \
    -destination 'platform=macOS' -derivedDataPath build/DerivedData build
codesign --verify --strict "$BUILT"

# Copie complète à côté d'abord : si elle échoue, l'app installée reste intacte.
STAGED="${DEST%.app}.nouveau.app"
rm -rf "$STAGED"
ditto "$BUILT" "$STAGED"

# Wispad se ferme proprement (son du Mac rétabli, dictée en cours annulée) avant d'être remplacé.
# L'ancien identifiant (com.yatofix.openflow, processus « wispad ») est aussi fermé : ses données
# sont reprises au premier lancement de la nouvelle version.
for bundle in com.yatofix.wispad com.yatofix.openflow; do
    osascript -e "tell application id \"$bundle\" to quit" 2>/dev/null || true
done
for _ in {1..20}; do pgrep -xq Wispad || pgrep -xq wispad || break; sleep 0.25; done
pkill -x Wispad 2>/dev/null || true
pkill -x wispad 2>/dev/null || true

# /Applications/wispad.app (ancien nom) et Wispad.app désignent le même dossier sur un volume
# insensible à la casse : la suppression couvre les deux.
rm -rf "$DEST"
mv "$STAGED" "$DEST"
# LaunchServices met parfois un instant à voir la nouvelle copie.
for _ in 1 2 3; do
    if open -g "$DEST" --args --background; then
        echo "Wispad installé : $DEST"
        exit 0
    fi
    sleep 2
done
echo "Wispad est installé dans $DEST mais ne s'est pas lancé : ouvre-le à la main." >&2
exit 1
