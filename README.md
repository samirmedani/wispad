# Wispad

Dictée vocale open source pour macOS. Double appui sur fn, parle, et le texte s'écrit là où tu tapes, dans toutes
les apps. Correction automatique (ponctuation, termes techniques, autocorrections orales, listes à puces), en
français et en anglais.

*Open-source voice dictation for macOS: double-press fn, speak, and the text is typed wherever your cursor is, in
any app. Automatic cleanup (punctuation, technical terms, spoken self-corrections, bullet lists), in French and
English.*

- **Tes clés, tes fournisseurs** : transcription par xAI ou OpenAI, correction par DeepSeek, OpenAI ou xAI. Tu paies
  directement chaque fournisseur.
- **Rien ne passe par un serveur de Wispad** : il n'y en a pas. Ni compte, ni télémétrie.

## Prérequis

- macOS 14 ou plus récent.
- Xcode 26 ou plus récent (SDK macOS 26), et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

## Démarrer

```bash
scripts/test.sh       # tests locaux, sans micro, réseau, clé ni fenêtre
scripts/build.sh      # build Debug dans build/DerivedData, avec les outils d'aperçu
scripts/install.sh    # version Release dans /Applications/Wispad.app
scripts/check.sh      # tests, traductions et compilation Release
```

Le projet Xcode se génère avec `xcodegen generate` ; il n'est pas dans Git.

Au premier lancement, Wispad guide la configuration : fournisseur de transcription, clés API, autorisations macOS
(micro, accessibilité, surveillance des entrées).

### Signature

Sans réglage, l'app est signée localement (ad hoc) : elle fonctionne sur ton Mac, mais macOS peut redemander les
autorisations après une nouvelle compilation. Avec un compte Apple Developer, crée `Signing.local.xcconfig`
(ignoré par Git) à la racine :

```
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = Apple Development
```

### Clés API

Les clés se saisissent dans l'écran Fournisseurs ; elles sont vérifiées chez le fournisseur puis enregistrées dans
`~/Library/Application Support/Wispad/api-keys.json`, lisible par ton seul compte. Tu peux aussi les laisser dans
ton propre coffre de secrets : voir « Clés API » dans [docs/COMPORTEMENT.md](docs/COMPORTEMENT.md).

Les tests réseau (`scripts/live-test.sh`, bancs) n'utilisent que des clés de test dédiées, `WISPAD_TEST_XAI_API_KEY`,
`WISPAD_TEST_DEEPSEEK_API_KEY` et `WISPAD_TEST_OPENAI_API_KEY`, lues dans l'environnement (voir
`scripts/test-keys.sh`). Ils coûtent quelques centimes. Les audios du banc franglais se génèrent avec
`scripts/franglais-fixtures.sh` (voix de synthèse de macOS).

## Organisation

- `Sources/WispadCore` : logique pure (transcription, correction, garde-fou, historique, coûts).
- `Sources/Wispad` : l'app (dictée, bulle, écrans, clés, traductions).

## Documentation

- [Architecture](docs/ARCHITECTURE.md) : modules, parcours d'une dictée, ajouter un fournisseur, un réglage ou un texte.
- [Comportement](docs/COMPORTEMENT.md) : raccourci, bulle, transcription, correction, relais, apprentissage.

Les textes d'interface s'écrivent en français dans le code, puis se traduisent en anglais avec
`scripts/localize.sh` ; `scripts/localize.sh check` doit passer.

## Contribuer

Toute modification passe par une pull request relue par le mainteneur : voir [CONTRIBUTING.md](CONTRIBUTING.md).
Pour signaler une faille : [SECURITY.md](SECURITY.md).

## Contributeurs

- [@samirmedani](https://github.com/samirmedani) : mainteneur.
- Claude (Anthropic) : assistant de développement.

Pour contribuer à ton tour : voir [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

Code sous licence [MIT](LICENSE).
