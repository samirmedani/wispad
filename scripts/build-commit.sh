#!/bin/sh
# Phase de compilation Xcode (project.yml) : grave le commit court du dépôt dans l'Info.plist de l'app,
# pour afficher la version et le retard sur main. Sans git ni dépôt, la clé est absente : seule la version
# s'affiche. Ne fait jamais échouer la compilation.
plist="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
commit=$(git -C "${SRCROOT}" rev-parse --short=7 HEAD 2>/dev/null || true)
/usr/libexec/PlistBuddy -c "Delete :WispadBuildCommit" "$plist" >/dev/null 2>&1 || true
case "$commit" in
  "" | *[!0-9a-f]*) echo "Commit de la version inconnu : seule la version s'affichera." ;;
  *) /usr/libexec/PlistBuddy -c "Add :WispadBuildCommit string ${commit}" "$plist" || true ;;
esac
exit 0
