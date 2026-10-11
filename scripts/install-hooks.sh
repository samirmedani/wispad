#!/bin/zsh
# Active les garde-fous Git du projet (.githooks) : secrets et fichiers interdits refusés au commit, push direct
# sur main refusé. À lancer une fois après le clonage.
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/*
print "Garde-fous Git actifs (.githooks)."
command -v gitleaks >/dev/null || print "Conseillé : brew install gitleaks (recherche de secrets)."
