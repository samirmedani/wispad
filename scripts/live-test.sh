#!/bin/zsh
# Lance un test réseau à la demande avec les seules clés de test (WISPAD_TEST_*, voir scripts/test-keys.sh), jamais celles de l'app.
#   scripts/live-test.sh <filtre swift test>      ex. scripts/live-test.sh SelfCorrectionLiveTests
# Les clés restent en mémoire, dans l'environnement du seul processus de test. Coût : quelques centimes.
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
filter=${1:?filtre swift test, par exemple SelfCorrectionLiveTests}
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
  swift test --filter "$filter"
