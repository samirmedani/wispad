#!/bin/zsh
# Banc du texte, obligatoire avant une release qui touche au texte (docs/BANC-TEXTE.md) : la version en cours (HEAD)
# contre la dernière release, sur les mêmes dictées privées, avec les seules clés de test (WISPAD_TEST_*).
#   scripts/text-bench.sh                 HEAD contre la dernière release atteignable depuis HEAD
#   scripts/text-bench.sh --base v0.8.0   contre une autre release (scripts/release.sh n'accepte que la dernière)
#   scripts/text-bench.sh --record        enregistre d'abord l'étape flux dans xAI (0,04 $ au plus)
#   scripts/text-bench.sh --refresh       reconstruit d'abord le corpus de l'étape correction depuis l'historique
# Un banc coûte quelques centimes de DeepSeek (quatre passages) et dure une dizaine de minutes. Clés : variables
# WISPAD_TEST_* ou coffre (WISPAD_SECRET_COMMAND, voir scripts/test-keys.sh), gardées dans l'environnement du seul
# processus de test. Tout reste dans ~/Library/Application Support/Wispad/benchmarks/texte (dossier 0700, fichiers
# 0600) ; la sortie ne montre que des chiffres et le verdict, jamais un texte dicté.
set -euo pipefail
unsetopt xtrace verbose
cd "$(dirname "$0")/.."
root=$PWD
fail() { print -u2 "text-bench.sh : $1"; exit 1 }
step() { print -P "%B== $1%b" }

base="" record=0 refresh=0
while (( $# )); do
  case "$1" in
    --base) [[ -n "${2:-}" ]] || fail "--base attend une release (vX.Y.Z)."; base=$2; shift 2 ;;
    --record) record=1; shift ;;
    --refresh) refresh=1; shift ;;
    *) fail "option inconnue : $1 (voir l'en-tête du script)." ;;
  esac
done
for tool in git swift python3; do
  command -v "$tool" >/dev/null || fail "$tool introuvable."
done

head_sha=$(git rev-parse HEAD)
# Le verdict vaut pour ce commit exact : aucun chemin du texte ne doit différer de lui.
text_paths=(${(f)"$(grep -vE '^[[:space:]]*(#|$)' scripts/text-paths.txt)"})
[[ -z "$(git status --porcelain -- "${text_paths[@]}")" ]] \
  || fail "chemins du texte modifiés sans commit : le verdict ne vaudrait pas pour $head_sha."
git fetch --quiet --tags origin 2>/dev/null || print "Tags non relus (hors ligne) : releases connues de ce dépôt seulement."
if [[ -z "$base" ]]; then
  base=$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null) || fail "aucune release atteignable depuis HEAD."
  if [[ "$(git rev-list -n 1 "$base")" == "$head_sha" ]]; then
    base=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "HEAD^" 2>/dev/null) || fail "aucune release avant $base."
  fi
fi
base_sha=$(git rev-list -n 1 "$base" 2>/dev/null) || fail "release $base introuvable."
[[ "$base_sha" != "$head_sha" ]] || fail "HEAD est la release $base : rien à comparer."

umask 077
data="$HOME/Library/Application Support/Wispad"
bench="$data/benchmarks/texte"
run="$bench/$head_sha"
mkdir -p "$bench"
chmod 700 "$bench"
# Aucun résultat d'un banc précédent sur ce commit : un banc interrompu ne laisse aucun verdict.
python3 scripts/text-bench.py prepare --run "$run"

if (( refresh )) || [[ ! -f "$bench/correction.json" ]]; then
  step "Corpus de l'étape correction (historique ouvert en lecture seule)"
  python3 scripts/text-bench.py corpus --db "$data/wispad.sqlite" --dir "$bench" --correction
fi
# L'étape flux rejoue des réponses de xAI : elles doivent venir des paramètres du flux et du fichier de HEAD. Sans
# --record, vérifié avant toute compilation.
if (( ! record )); then
  python3 scripts/text-bench.py verifie-flux --dir "$bench" --tree "$root"
fi

unset WISPAD_LIVE_XAI_KEY WISPAD_LIVE_DEEPSEEK_KEY WISPAD_LIVE_OPENAI_KEY WISPAD_LIVE_TYPESAFE_KEY
source scripts/test-keys.sh
deepseek="$(test_secret WISPAD_TEST_DEEPSEEK_API_KEY required)" || exit 1
export WISPAD_LIVE_DEEPSEEK_KEY="$deepseek"
unset deepseek
export WISPAD_LIVE_TESTS=1 WISPAD_TEXT_BENCH=1 WISPAD_TEXT_BENCH_DIR="$bench"

# Compile un arbre ; le journal reste privé, seules les erreurs du compilateur s'affichent.
build() {
  local tree=$1 name=$2
  if ! (cd "$tree" && swift build --build-tests > "$run/compilation-$name.txt" 2>&1); then
    grep -E 'error:' "$run/compilation-$name.txt" | sort -u | head -20 >&2 || true
    fail "compilation de $name impossible (journal : $run/compilation-$name.txt)."
  fi
}

# Un passage du harnais (TextBenchLiveTests) : journal privé, seules ses lignes de chiffres s'affichent.
bench_test() {
  local tree=$1 mode=$2 name=$3 test=$4
  local journal="$run/journal-$name.txt"
  if ! (cd "$tree" && WISPAD_TEXT_BENCH_MODE=$mode WISPAD_TEXT_BENCH_RUN=$name WISPAD_TEXT_BENCH_OUT="$run/$name.json" \
      swift test --skip-build --filter "TextBenchLiveTests/$test" > "$journal" 2>&1); then
    grep -E '^BANC-TEXTE|error:|Plafond' "$journal" | head -10 >&2 || true
    fail "$name en échec (journal privé : $journal)."
  fi
  grep -E '^BANC-TEXTE' "$journal" || fail "$name n'a rien mesuré (journal privé : $journal)."
}

step "Compilation de HEAD (${head_sha[1,12]})"
build "$root" head

if (( record )); then
  step "Enregistrement de l'étape flux (xAI, 0,04 $ au plus)"
  python3 scripts/text-bench.py corpus --db "$data/wispad.sqlite" --dir "$bench" --flux
  xai="$(test_secret WISPAD_TEST_XAI_API_KEY required)" || exit 1
  export WISPAD_LIVE_XAI_KEY="$xai"
  unset xai
  export WISPAD_TEXT_BENCH_FINGERPRINT="$(python3 scripts/text-bench.py empreinte "$root")"
  bench_test "$root" record enregistrement testRecordStream
  unset WISPAD_LIVE_XAI_KEY
  python3 scripts/text-bench.py verifie-flux --dir "$bench" --tree "$root"
fi

scratch=$(mktemp -d /private/tmp/wispad-text-bench.XXXXXX)
base_tree="$scratch/base"
cleanup() {
  git -C "$root" worktree remove --force "$base_tree" >/dev/null 2>&1 || true
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$scratch"
  git -C "$root" worktree prune
}
trap cleanup EXIT
trap 'exit 130' INT TERM
step "Arbre temporaire de $base (${base_sha[1,12]})"
git worktree add --detach --quiet "$base_tree" "$base_sha"
# La même mesure des deux côtés : le harnais de HEAD et son plafond de dépense.
cp Tests/WispadCoreTests/TextBenchLiveTests.swift Tests/WispadCoreTests/SpendLedger.swift "$base_tree/Tests/WispadCoreTests/"
build "$base_tree" base

for name in base-0 head-0 base-1 head-1; do
  step "Passage $name"
  if [[ $name == base-* ]]; then
    bench_test "$base_tree" pass "$name" testBenchPass
  else
    bench_test "$root" pass "$name" testBenchPass
  fi
done

step "Analyse"
verdict=0
python3 scripts/text-bench.py analyse --dir "$bench" --run "$run" --sha "$head_sha" --base "$base" --base-sha "$base_sha" \
  --base-tree "$base_tree" || verdict=$?
spent=$(python3 -c 'import json, sys; print(("%.4f" % json.load(open(sys.argv[1]))["usd"]).replace(".", ","))' \
  "$data/api-test-spend.json" 2>/dev/null || print "?")
print "Plafond des tests réseau : $spent \$ dépensés sur 6 \$."
print "Rapport privé, textes compris : $run/rapport.md"
exit $verdict
