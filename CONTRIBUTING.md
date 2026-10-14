# Contribuer à Wispad

Merci de vouloir aider ! Wispad est maintenu par [@samirmedani](https://github.com/samirmedani) : **toute modification
passe par une pull request relue et acceptée par le mainteneur.** Personne ne pousse directement sur `main`.

*English: every change goes through a pull request reviewed and merged by the maintainer. Sign off your commits
(`git commit -s`), keep one topic per pull request, never commit personal data or secrets.*

## Avant de coder

- Pour un changement de comportement, une nouvelle dépendance ou un nouveau fournisseur, ouvre d'abord une issue pour
  en discuter. Une pull request non annoncée peut être refusée même si elle fonctionne.
- Lis [AGENTS.md](AGENTS.md) (règles du projet) et [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Parcours d'une contribution

1. Fork du dépôt, puis une branche par sujet : `fix/collage-chrome`, `feat/liste-numerotee`, `docs/readme`.
   Active une fois les garde-fous Git : `scripts/install-hooks.sh` (secrets et fichiers interdits refusés au commit,
   push direct sur `main` refusé).
2. Commits signés : `git commit -s` (ligne `Signed-off-by: Nom <e-mail>`, voir plus bas).
3. `scripts/check.sh` doit passer en local : tests, traductions, compilation Release.
   Pour un changement de concurrence ou de mémoire, aussi `swift test --sanitize=thread` puis
   `swift test --sanitize=address` (ils doivent rester muets). Les tests de propriétés, séquences du coordinateur
   de dictée comprises, tirent un quart de leurs cas par défaut ;
   `WISPAD_PROPERTY_RUNS=full swift test --filter PropertyTests` les tire tous.
4. Pull request vers `main`, en remplissant le modèle. Une pull request = un sujet, la plus petite possible.
5. La vérification automatique doit être verte, puis le mainteneur relit. Les remarques se règlent dans la même
   pull request ; une nouvelle poussée annule l'approbation précédente.
6. Le mainteneur fusionne par **squash** : le titre de la pull request devient le message du commit sur `main`.

## Règles des commits

- Première ligne de 72 caractères au plus, à l'impératif, en français ou en anglais : « Corrige le collage dans
  Chrome », « Add numbered lists ». Une ligne vide, puis le pourquoi si ce n'est pas évident.
- Un commit = une étape cohérente qui compile. Pas de « wip », « fix », « test » seuls.
- **Signature obligatoire (DCO)** : `-s` ajoute `Signed-off-by`. Tu certifies ainsi avoir le droit de proposer ce code
  sous la licence du projet ([Developer Certificate of Origin](https://developercertificate.org)). Pour signer après
  coup : `git rebase --signoff main` puis `git push --force-with-lease` sur **ta** branche.
- Pas de réécriture de `main`, pas de commit de fusion : l'historique de `main` reste linéaire.

## Ce qui ne doit jamais entrer dans le dépôt

- Clés API, jetons, certificats, identifiants d'équipe Apple, fichiers `.env`.
- Données personnelles : noms, e-mails, chemins de ta machine, enregistrements de voix, historiques de dictée,
  bases `.sqlite`, journaux, captures contenant du texte réel.
- Builds, archives, projets Xcode générés.

Le `.gitignore` bloque la plupart de ces fichiers et la vérification automatique refuse une pull request qui en
contient (gitleaks, types de fichiers interdits, chemins de machine). Un secret poussé par erreur doit être
**révoqué** chez son fournisseur, même après sa suppression.

## Qualité attendue

- Tests pour tout comportement nouveau ou corrigé ; `docs/COMPORTEMENT.md` mis à jour dans la même pull request.
- Textes d'interface en français dans le code, traduits en anglais (`scripts/localize.sh`).
- Confidentialité : ne jamais journaliser une transcription, le contexte autour du curseur ou une clé.

## Comportement

Sois respectueux et bienveillant dans les issues et les relectures. Les attaques personnelles, le harcèlement et les
propos discriminatoires mènent à l'exclusion du projet.

## Licence

En contribuant, tu acceptes que ta contribution soit publiée sous la [licence MIT](LICENSE) du projet.
