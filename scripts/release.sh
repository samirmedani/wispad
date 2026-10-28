#!/bin/zsh
# Publie une release de Wispad sur GitHub : le Wispad.dmg que l'on télécharge, et que l'app installe elle-même en un
# clic (voir « Mises à jour » dans docs/COMPORTEMENT.md).
#
#   scripts/release.sh      version lue dans project.yml (MARKETING_VERSION), tag vX.Y.Z
#
# Étapes :
#   1. build Release universel (arm64 + x86_64) ;
#   2. clé Info.plist WispadRelease (vrai) : l'app se sait release, compare sa version aux releases et se met à jour
#      en un clic ; sans elle (build depuis les sources), elle affiche son retard sur main ;
#   3. signature Developer ID, runtime renforcé, horodatage, entitlements du dépôt (jamais get-task-allow) ;
#   4. Wispad.dmg (l'app et un lien vers Applications), signé à son tour ;
#   5. notarisation par notarytool (clé API App Store Connect), puis agrafage du ticket sur le dmg ;
#   6. gh release create vX.Y.Z avec le dmg et les notes.
#
# Aucun secret ni identifiant d'équipe dans ce fichier : tout vient de l'environnement.
#   WISPAD_SIGNING_IDENTITY  certificat « Developer ID Application » du trousseau (nom complet ou empreinte SHA-1)
#   WISPAD_TEAM_ID           identifiant de l'équipe Apple (10 caractères), vérifié dans la signature obtenue
#   WISPAD_NOTARY_KEY        chemin de la clé API App Store Connect (.p8), gardée hors du dépôt
#   WISPAD_NOTARY_KEY_ID     identifiant de cette clé
#   WISPAD_NOTARY_ISSUER     identifiant de l'émetteur de la clé (UUID)
#   WISPAD_RELEASE_NOTES     facultatif : notes de version en markdown ; sinon GitHub les rédige depuis les PR
#   WISPAD_RELEASE_DRAFT=1   facultatif : release en brouillon, que l'app ne voit qu'une fois publiée
#
# Préalables : Xcode 26, xcodegen, gh connecté (gh auth status) ; dépôt propre, HEAD poussé sur main ; version de
# project.yml relevée dans une pull request et plus récente que la dernière release. Tout est produit dans
# build/release/ (ignoré par Git).
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { print -u2 "release.sh : $1"; exit 1 }
step() { print -P "%B== $1%b" }

for name in WISPAD_SIGNING_IDENTITY WISPAD_TEAM_ID WISPAD_NOTARY_KEY WISPAD_NOTARY_KEY_ID WISPAD_NOTARY_ISSUER; do
  [[ -n "${(P)name:-}" ]] || fail "variable $name manquante (voir l'en-tête du script)."
done
[[ "$WISPAD_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || fail "WISPAD_TEAM_ID doit compter 10 lettres majuscules ou chiffres."
[[ -f "$WISPAD_NOTARY_KEY" ]] || fail "clé de notarisation introuvable (WISPAD_NOTARY_KEY)."
notes_file="${WISPAD_RELEASE_NOTES:-}"
if [[ -n "$notes_file" && ! -f "$notes_file" ]]; then
  fail "notes de version introuvables (WISPAD_RELEASE_NOTES)."
fi
for tool in xcodegen xcodebuild xcrun codesign hdiutil gh plutil lipo ditto; do
  command -v "$tool" >/dev/null || fail "$tool introuvable."
done

version=$(sed -nE 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/p' project.yml | head -n 1)
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "MARKETING_VERSION de project.yml n'est pas au format X.Y.Z : « $version »."
tag="v$version"

step "Vérifications avant $tag"
[[ -z "$(git status --porcelain)" ]] || fail "dépôt modifié : la release doit partir d'un commit publié, sans changement local."
git fetch --quiet origin main
git merge-base --is-ancestor HEAD origin/main || fail "HEAD n'est pas sur origin/main : pousse et fusionne d'abord."
commit=$(git rev-parse HEAD)
if gh release view "$tag" >/dev/null 2>&1; then
  fail "la release $tag existe déjà."
fi
latest=$(gh release view --json tagName --jq .tagName 2>/dev/null || true)
autoload -Uz is-at-least
if [[ -n "$latest" ]] && is-at-least "$version" "${latest#v}"; then
  fail "$tag n'est pas plus récente que la dernière release ($latest) : relève MARKETING_VERSION dans project.yml."
fi

out=build/release
rm -rf "$out"
mkdir -p "$out"

step "Build Release universel"
xcodegen generate --quiet
# Signature locale pendant le build (Signing.local.xcconfig ignoré) : la vraie signature vient juste après.
xcodebuild -project Wispad.xcodeproj -scheme Wispad -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$out/DerivedData" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
app="$out/Wispad.app"
ditto "$out/DerivedData/Build/Products/Release/Wispad.app" "$app"
archs=$(lipo -archs "$app/Contents/MacOS/Wispad")
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "binaire non universel ($archs)."
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] \
  || fail "la version de l'app n'est pas $version."
nm "$app/Contents/MacOS/Wispad" > "$out/symboles.txt"
if grep -qE 'DesignPreview|DevTools' "$out/symboles.txt"; then
  fail "outils de développement présents dans la version Release."
fi

step "Clé de release et signature Developer ID"
# Seul ce script ajoute WispadRelease (BuildKind.infoKey) : l'app se sait release et se met à jour par les releases.
/usr/libexec/PlistBuddy -c "Delete :WispadRelease" "$plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :WispadRelease bool true" "$plist"
entitlements=Sources/Wispad/Wispad.entitlements
if grep -q "get-task-allow" "$entitlements"; then
  fail "$entitlements ne doit pas contenir get-task-allow."
fi
# Code imbriqué d'abord (bibliothèques ajoutées par Xcode, s'il y en a), puis l'app.
for nested in "$app"/Contents/Frameworks/*(N); do
  codesign --force --options runtime --timestamp --sign "$WISPAD_SIGNING_IDENTITY" "$nested"
done
codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$WISPAD_SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
details=$(codesign -dvv "$app" 2>&1)
[[ "$details" == *"TeamIdentifier=$WISPAD_TEAM_ID"* ]] || fail "l'app n'est pas signée par l'équipe WISPAD_TEAM_ID."
[[ "$details" == *"Authority=Developer ID Application"* ]] || fail "l'app n'est pas signée par un certificat Developer ID Application."
[[ "$details" == *"(runtime)"* ]] || fail "runtime renforcé absent de la signature."
signed_entitlements=$(codesign -d --entitlements - "$app" 2>/dev/null || true)
[[ "$signed_entitlements" != *get-task-allow* ]] || fail "l'app signée contient get-task-allow."
[[ "$(/usr/libexec/PlistBuddy -c 'Print :WispadRelease' "$plist")" == "true" ]] || fail "clé WispadRelease absente."

step "Wispad.dmg"
stage="$out/dmg"
mkdir -p "$stage"
ditto "$app" "$stage/Wispad.app"
ln -s /Applications "$stage/Applications"
dmg="$out/Wispad.dmg"
hdiutil create -volname Wispad -srcfolder "$stage" -format UDZO -ov "$dmg"
# hdiutil laisse parfois son assistant (diskimages-helper) ouvert sur l'image : notarytool restait alors bloqué à
# l'ouverture du fichier, sans délai maximal (28 octobre 2026, 18 minutes). Une copie neuve n'est tenue par personne.
cp "$dmg" "$dmg.neuf"
mv -f "$dmg.neuf" "$dmg"
codesign --force --timestamp --sign "$WISPAD_SIGNING_IDENTITY" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

step "Notarisation et agrafage"
notary=(--key "$WISPAD_NOTARY_KEY" --key-id "$WISPAD_NOTARY_KEY_ID" --issuer "$WISPAD_NOTARY_ISSUER")
# La file d'Apple reste parfois bloquée plus d'une heure sur une soumission alors qu'une nouvelle passe en quelques
# minutes (23 et 24 octobre 2026) : trois essais de 12 minutes. Avant chaque nouvel essai, les soumissions précédentes
# sont relues : l'une d'elles a pu aboutir entre-temps.
verdict=""
submissions=()
for attempt in 1 2 3; do
  xcrun notarytool submit "$dmg" "${notary[@]}" --wait --timeout 12m --output-format json > "$out/notarisation.json" || true
  verdict=$(plutil -extract status raw -o - "$out/notarisation.json" 2>/dev/null || true)
  submission=$(plutil -extract id raw -o - "$out/notarisation.json" 2>/dev/null || true)
  [[ -n "$submission" ]] && submissions+=("$submission")
  [[ "$verdict" == "Accepted" || "$verdict" == "Invalid" || "$verdict" == "Rejected" ]] && break
  for previous in "${submissions[@]}"; do
    earlier=$(xcrun notarytool info "$previous" "${notary[@]}" --output-format json 2>/dev/null \
      | plutil -extract status raw -o - - 2>/dev/null || true)
    if [[ "$earlier" == "Accepted" ]]; then
      verdict=Accepted
      break 2
    fi
  done
  print "Notarisation sans réponse (essai $attempt, ${verdict:-aucun statut}) : nouvelle soumission."
done
if [[ "$verdict" != "Accepted" ]]; then
  submission=$(plutil -extract id raw -o - "$out/notarisation.json" 2>/dev/null || true)
  if [[ -n "$submission" ]]; then
    xcrun notarytool log "$submission" "${notary[@]}" "$out/notarisation-journal.json" || true
  fi
  fail "notarisation refusée (${verdict:-sans réponse}) : voir $out/notarisation.json et $out/notarisation-journal.json."
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
digest=$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)

step "Release GitHub $tag"
release_args=(--title "Wispad $version" --target "$commit")
if [[ -n "$notes_file" ]]; then
  # Notes du mainteneur, telles quelles : l'empreinte du dmg est affichée par GitHub à côté du fichier, et l'app
  # vérifie celle que l'API annonce.
  release_args+=(--notes-file "$notes_file")
else
  release_args+=(--generate-notes)
fi
if [[ "${WISPAD_RELEASE_DRAFT:-}" == 1 ]]; then
  release_args+=(--draft)
fi
gh release create "$tag" "$dmg" "${release_args[@]}"
print "Release $tag : $(gh release view "$tag" --json url --jq .url)"
print "SHA-256 de Wispad.dmg : $digest"
