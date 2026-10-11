#!/bin/zsh
# Banc franglais : rejoue les audios de test (et les enregistrements réels locaux s'il y en a) dans la vraie chaîne
# xAI + correction, puis compare au rapport précédent.
#   scripts/franglais-bench.sh <nom> [rapport-de-référence]
# Variables utiles : BENCH_KEYTERMS=none, BENCH_LANGUAGE=auto, BENCH_CLEANUP=off, BENCH_ONLY=11-
# Coût : quelques centimes (xAI 0,20 $/h d'audio, correction).
# Clés (scripts/test-keys.sh) : WISPAD_TEST_XAI_API_KEY requis ; WISPAD_TEST_DEEPSEEK_API_KEY et
# WISPAD_TEST_OPENAI_API_KEY optionnels pour la correction. Aucun repli sur les clés de l'app.
# Les clés restent en mémoire et dans l'environnement du test.
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
label=${1:?nom du rapport}
reference=${2:-}
reports="$HOME/Library/Application Support/Wispad/benchmarks/franglais/rapports"
source scripts/test-keys.sh
xai_test_key="$(test_secret WISPAD_TEST_XAI_API_KEY required)" || exit 1
deepseek_test_key="" openai_test_key=""
if [[ "${BENCH_CLEANUP:-on}" != off ]]; then
  deepseek_test_key="$(test_secret WISPAD_TEST_DEEPSEEK_API_KEY)" || exit 1
  openai_test_key="$(test_secret WISPAD_TEST_OPENAI_API_KEY)" || exit 1
fi
WISPAD_LIVE_TESTS=1 WISPAD_FRANGLAIS=1 BENCH_LABEL="$label" \
WISPAD_LIVE_XAI_KEY="$xai_test_key" \
WISPAD_LIVE_DEEPSEEK_KEY="$deepseek_test_key" \
WISPAD_LIVE_OPENAI_KEY="$openai_test_key" WISPAD_LIVE_TYPESAFE_KEY="" \
swift test --filter FranglaisBenchmarkTests 2>&1 | awk '/^BANC|error:|failed|Failure|XCTAssert/ { print }'
python3 - "$reports/$label.json" "${reference:+$reports/$reference.json}" <<'PY'
import json, sys
def load(p):
    return {o["id"]: o for o in json.load(open(p))["outcomes"]} if p else {}
new = load(sys.argv[1]); old = load(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}
def score(o):
    return len(o["finalMissing"]) + len(o["finalForbidden"])
print(f"\n{'cas':<16}{'avant':>7}{'après':>7}  détail (après)")
for cid, o in new.items():
    before = score(old[cid]) if cid in old else None
    detail = ", ".join([f"manque {t}" for t in o["finalMissing"]] + [f"interdit {t}" for t in o["finalForbidden"]]) or "ok"
    print(f"{cid:<16}{'' if before is None else before:>7}{score(o):>7}  {detail}")
PY
