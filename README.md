# Métriques de Wispad

Branche de données, mise à jour toutes les heures par le workflow « Métriques » (`.github/workflows/metrics.yml`
sur `main`). Ne pas la modifier à la main.

- `downloads.csv` : un relevé à chaque changement (téléchargements, étoiles, versions), et au moins un par jour.
- `downloads-light.svg`, `downloads-dark.svg` : le graphique affiché dans le README, en clair et en sombre.
- `releases-light.svg`, `releases-dark.svg` : dernière version (date et heure), rythme des mises à jour et
  historique des versions.
- `status-light.svg`, `status-dark.svg` : le bandeau du haut du README (maintenance et dernière version).
