# Banc de l’apprentissage du dictionnaire

Passe locale du 13 octobre 2026. Corpus synthétique : aucune dictée, aucun mot ni aucune clé provenant des données de l’app.

## Ce qui a été mesuré

`LearningBenchmarkTests` comporte 24 corrections : 12 noms ou termes spécifiques à proposer au juge, et 12 accords, mots courants, fautes de frappe ou changements de sens à refuser au final.

- 480 mesures du préfiltre local (20 répétitions par cas, build Debug).
- Médiane : **0,058 ms** ; 95e percentile : **0,079 ms** sur cette passe. Mesure indicative, pas une garantie sur toutes les machines ou les textes longs.
- Après correction, **12/12 termes utiles** atteignent le juge. Avant correction, « terraforme → Terraform » était éliminé à tort comme une flexion.
- **6/12 cas négatifs** sont éliminés localement. Les six autres doivent encore être arbitrés par Jev ou le modèle de correction : ce chiffre n’est ni la précision ni le rappel du système complet.

## Vérifications fonctionnelles

Les tests couvrent notamment : un mot refusé pendant un jugement en cours, les doublons dans une réponse ou dans plusieurs jugements en file, l’apprentissage coupé pendant l’attente, la conservation du fournisseur ayant tranché, les réponses Jev invalides, le repli sur le modèle de correction, et les notifications groupées interrompues par une nouvelle dictée.

Une expression de plusieurs milliers de caractères conserve son contenu en base et reste classée dans Expressions et phrases. Les entrées antérieures ne sont pas réécrites.

## Mesure réelle de Jev : non effectuée

La clé dédiée `WISPAD_TEST_TYPESAFE_API_KEY` est absente. Le banc s’arrête avant tout appel réseau ; aucune clé de l’app n’est utilisée. Aucune précision, latence réseau ou économie de coût de Jev n’est déduite des tests simulés.

Le banc est reproductible :

```sh
scripts/learning-bench.sh
WISPAD_SECRET_COMMAND=yatofix-secret scripts/learning-bench.sh --live
```

La passe réseau fait deux passages du même corpus et rapporte vrais/faux positifs, vrais/faux négatifs, appels en erreur, appels au modèle de correction et latences médiane/95e percentile. Elle utilise Jev et, si elle est fournie, `WISPAD_TEST_DEEPSEEK_API_KEY`. Elle réserve au plus 0,96 $ dans le plafond partagé des tests réseau ; cette réserve conservatrice n’est pas une mesure du coût facturé. Les modèles effectivement appelés sont indiqués.

Un corpus aussi petit sert à détecter des régressions et à préparer une évaluation plus large. Il ne prouve pas une performance générale sur toutes les langues, marques ou corrections.
