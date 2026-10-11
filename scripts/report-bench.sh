#!/bin/zsh
# Banc des erreurs signalées dans l'historique : rejoue leurs audios avec les seules clés de test (WISPAD_TEST_*, voir scripts/test-keys.sh).
#   scripts/report-bench.sh <nom>      rapport dans Application Support/Wispad/benchmarks/signalements-rapports
# Les clés restent en mémoire, dans l'environnement du seul processus de test. Coût : quelques centimes.
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
label=${1:?nom du rapport}
source scripts/test-keys.sh
xai="$(test_secret WISPAD_TEST_XAI_API_KEY)" || exit 1
deepseek="$(test_secret WISPAD_TEST_DEEPSEEK_API_KEY)" || exit 1
openai="$(test_secret WISPAD_TEST_OPENAI_API_KEY)" || exit 1
if [[ -z "$xai$deepseek$openai" ]]; then
  print -u2 "Aucune clé de test (WISPAD_TEST_*) : test arrêté."
  exit 1
fi
env -u WISPAD_LIVE_TYPESAFE_KEY \
  WISPAD_LIVE_TESTS=1 \
  WISPAD_LIVE_XAI_KEY="$xai" \
  WISPAD_LIVE_DEEPSEEK_KEY="$deepseek" \
  WISPAD_LIVE_OPENAI_KEY="$openai" \
  WISPAD_REPORT_BENCH=1 BENCH_LABEL="$label" swift test --filter ErrorReportBenchTests 2>&1 | awk '/^BANC|error:|failed/ { print }'
