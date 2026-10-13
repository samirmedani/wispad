#!/bin/zsh
# Banc synthétique : aucun texte personnel, aucune clé de l'app. Sans option : préfiltre hors réseau.
# --live : 2 passes du corpus, Jev + DeepSeek si une clé de test est fournie, réserve maximale 0,96 $.
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
if [[ "${1:-}" == --live ]]; then
  source scripts/test-keys.sh
  typesafe_test_key="$(test_secret WISPAD_TEST_TYPESAFE_API_KEY required)" || exit 1
  deepseek_test_key="$(test_secret WISPAD_TEST_DEEPSEEK_API_KEY)" || exit 1
  export WISPAD_TEST_TYPESAFE_API_KEY="$typesafe_test_key"
  export WISPAD_TEST_DEEPSEEK_API_KEY="$deepseek_test_key"
  export WISPAD_LEARNING_BENCH_LIVE=1
else
  unset WISPAD_LEARNING_BENCH_LIVE
fi
swift test --filter LearningBenchmarkTests
