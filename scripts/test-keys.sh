# Clés des bancs réseau (WISPAD_TEST_*), jamais celles de l'app. À sourcer depuis la racine du projet.
# Chaque clé vient de l'environnement (export WISPAD_TEST_XAI_API_KEY=…) ou, si WISPAD_SECRET_COMMAND est défini,
# de ce coffre de secrets : « commande get NOM » rend la valeur, code 1 si elle est absente.
# Les clés restent en mémoire, dans l'environnement du seul processus de test.
test_secret() {
  local secret_name="$1" required="${2:-optional}" value secret_status
  if [[ -n "${(P)secret_name:-}" ]]; then
    printf '%s' "${(P)secret_name}"
    return 0
  fi
  if [[ -n "${WISPAD_SECRET_COMMAND:-}" ]]; then
    if value="$("${WISPAD_SECRET_COMMAND/#\~/$HOME}" get "$secret_name" 2>/dev/null)"; then
      if [[ -n "$value" ]]; then
        printf '%s' "$value"
        return 0
      fi
    else
      secret_status=$?
      if (( secret_status != 1 )); then
        print -u2 "Coffre de secrets injoignable : arrêt, aucun appel API lancé."
        return 1
      fi
    fi
  fi
  if [[ "$required" == required ]]; then
    print -u2 "$secret_name absente : exporte une clé dédiée aux tests. Les clés de l'app ne sont jamais utilisées."
    return 1
  fi
  return 0
}
