#!/bin/zsh
# Traductions de l'interface (français d'origine, anglais).
#   scripts/localize.sh export [dossier]   extrait tous les textes dans <dossier>/en.xcloc (XLIFF à traduire)
#   scripts/localize.sh import [dossier]   réintègre <dossier>/en.xcloc traduit dans les catalogues
#   scripts/localize.sh check              liste les textes sans traduction anglaise (code de sortie 1 s'il y en a)
# Les textes s'écrivent en français dans le code : littéral SwiftUI, ou String(localized:) pour un texte construit.
set -euo pipefail
cd "$(dirname "$0")/.."
command=${1:-check}
folder=${2:-build/localizations}
case "$command" in
  export)
    xcodegen generate --quiet
    rm -rf "$folder"
    xcodebuild -exportLocalizations -project Wispad.xcodeproj -scheme Wispad -localizationPath "$folder" \
      -exportLanguage en -derivedDataPath build/DerivedData >/dev/null
    echo "À traduire : $folder/en.xcloc/Localized Contents/en.xliff"
    ;;
  import)
    xcodebuild -importLocalizations -project Wispad.xcodeproj -localizationPath "$folder/en.xcloc" >/dev/null
    echo "Traductions intégrées."
    "$0" check
    ;;
  check)
    python3 - Sources/Wispad/Localizable.xcstrings Sources/Wispad/InfoPlist.xcstrings <<'PY'
import json, sys
missing = []
for path in sys.argv[1:]:
    strings = json.load(open(path))["strings"]
    for key, value in strings.items():
        if value.get("shouldTranslate") is False:
            continue
        english = value.get("localizations", {}).get("en", {}).get("stringUnit", {})
        if english.get("state") != "translated" or not english.get("value"):
            missing.append(f"{path}: {key}")
print("\n".join(missing) if missing else "Tous les textes ont leur traduction anglaise.")
sys.exit(1 if missing else 0)
PY
    ;;
  *)
    print -u2 "Usage : scripts/localize.sh export|import|check [dossier]"
    exit 2
    ;;
esac
