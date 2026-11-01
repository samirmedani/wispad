#!/bin/zsh
# Banc des modèles de correction : les dictées privées du banc du texte (étapes correction et mots), corrigées par
# chaque modèle à tour de rôle, avec les seules clés de test (WISPAD_TEST_*, voir scripts/test-keys.sh).
#   scripts/model-bench.sh <nom> [compte:modèle:entrée:cache:sortie,...]
# Prix en dollars par million de jetons. Par défaut : DeepSeek Flash, DeepSeek V4 Pro (heures creuses) et Grok 4.20
# sans raisonnement. Résultats dans Application Support/Wispad/benchmarks/modeles/<nom> (0700, fichiers 0600) ;
# la sortie ne montre que des chiffres, jamais un texte dicté. Plafond : WISPAD_MODEL_BENCH_RESERVE (0,40 $).
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
label=${1:?nom du banc}
models=${2:-"deepseek:deepseek-flash:0.15:0.003:0.60,deepseek:deepseek-v4-pro:0.66:0.022:1.98,xai:grok-4.20-0309-non-reasoning:1.25:0.20:2.50"}
source scripts/test-keys.sh
xai="$(test_secret WISPAD_TEST_XAI_API_KEY)" || exit 1
deepseek="$(test_secret WISPAD_TEST_DEEPSEEK_API_KEY)" || exit 1
umask 077
data="$HOME/Library/Application Support/Wispad/benchmarks"
out="$data/modeles/$label"
mkdir -p "$out"
chmod 700 "$data/modeles" "$out"
flags=()
[[ -f Sources/WispadCore/ListeningVote.swift ]] && flags=(-Xswiftc -DWISPAD_VOTE_DES_ECOUTES)
env -u WISPAD_LIVE_TYPESAFE_KEY -u WISPAD_LIVE_OPENAI_KEY \
  WISPAD_LIVE_TESTS=1 WISPAD_MODEL_BENCH=1 \
  WISPAD_LIVE_XAI_KEY="$xai" WISPAD_LIVE_DEEPSEEK_KEY="$deepseek" \
  WISPAD_MODEL_BENCH_MODELS="$models" WISPAD_TEXT_BENCH_DIR="$data/texte" WISPAD_MODEL_BENCH_OUT="$out/appels.json" \
  swift test "${flags[@]}" --filter ModelBenchLiveTests 2>&1 | awk '/^BANC-MODELES|error:|failed/ { print }'
[[ -f "$out/appels.json" ]] || { print -u2 "Aucun résultat : banc interrompu."; exit 1 }
python3 scripts/model-bench.py "$out/appels.json" "$data/texte/mots.json"
