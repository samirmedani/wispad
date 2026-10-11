# Wispad — consignes pour contribuer (humains et agents)

Dictée vocale open source pour macOS. Lire [README.md](README.md), puis [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
avant d'ajouter un fournisseur, un réglage ou un écran.

## Règles

- Ne jamais journaliser les transcriptions, le contexte autour du curseur ni les clés API.
- Clés API, seulement via `APIKeys` : fichier de l'app, ou coffre de secrets configuré par l'utilisateur. Jamais le
  Trousseau macOS, jamais une clé dans le code, les tests, les journaux ou Git.
- Tests réseau seulement avec des clés de test dédiées `WISPAD_TEST_*` (`scripts/test-keys.sh`), jamais celles de l'app.
- Un appui simple sur le raccourci ne doit ni ouvrir le micro, ni afficher la bulle, ni démarrer une dictée.
- Observer d'autres apps de dictée seulement comme comportement visible : ne pas extraire leur code.
- Builds et tests en arrière-plan : ne jamais activer ni mettre au premier plan une fenêtre de test. Aperçus hors
  écran (`--design-preview --offscreen`), relance technique avec `--background`.
- Aucune donnée personnelle dans le dépôt : ni nom, e-mail, chemin de machine, serveur, identifiant d'équipe Apple
  (il va dans `Signing.local.xcconfig`, ignoré par Git), ni enregistrement de voix.

## Développement

- Jamais de push sur `main` : une branche par sujet, puis une pull request relue et fusionnée par le mainteneur
  (squash). Commits signés `git commit -s`, première ligne de 72 caractères au plus. Détails : [CONTRIBUTING.md](CONTRIBUTING.md).
  Garde-fous Git : `scripts/install-hooks.sh` ; ne jamais les contourner (`--no-verify`).
- La vérification GitHub compile avec Xcode 26 : un code qui passe seulement avec un Xcode plus récent échoue.
  Ne fusionner qu'avec les trois vérifications vertes.
- Mettre à jour `docs/COMPORTEMENT.md` dans le même commit qu'un changement de comportement.
- Textes d'interface en français dans le code (littéral SwiftUI ou `String(localized:)`), traduits en anglais avec
  `scripts/localize.sh` ; `scripts/localize.sh check` doit passer. `WispadCore` ne porte aucun texte d'interface.
- Outils de développement (aperçus, démos, sondes, autotests) en `#if DEBUG` uniquement.
- `scripts/check.sh` (tests, traductions, compilation Release) avant une pull request.
