# Banc du texte

Le texte final d'une dictée passe par une chaîne : assemblage du flux, choix entre le flux et le fichier,
normalisations, correction (consigne, garde-fou, dates, nombres, listes). Un changement dans cette chaîne peut
améliorer un cas et en abîmer d'autres. Le banc du texte mesure la version en cours (HEAD) contre la dernière release,
sur les mêmes dictées réelles, gardées en privé sur le Mac du mainteneur. Il est **obligatoire avant chaque release
qui touche au texte** : `scripts/release.sh` refuse de publier sans un verdict vert pour le commit exact à publier.

## Quand le lancer

`scripts/release.sh` compare la dernière release au commit à publier. Si un chemin de
[scripts/text-paths.txt](../scripts/text-paths.txt) a changé (transcription, assemblage, correction, finitions, nombres,
dates, normalisations, choix flux/fichier, orchestration de la dictée), il exige
`~/Library/Application Support/Wispad/benchmarks/texte/<commit>/verdict.json` avec `pass: true`, pour ce commit et
contre cette release. Le verdict est lié au commit : on lance donc le banc sur `main`, juste avant la release, une fois
la dernière pull request fusionnée. Une pull request qui touche au texte peut le lancer avant, pour se faire une idée.

## Lancer

```sh
scripts/text-bench.sh                 # HEAD contre la dernière release atteignable depuis HEAD
scripts/text-bench.sh --record        # enregistre d'abord l'étape flux (la première fois, ou paramètres changés)
scripts/text-bench.sh --refresh       # reconstruit d'abord le corpus de l'étape correction
scripts/text-bench.sh --base v0.8.0   # contre une autre release ; release.sh n'accepte que la dernière
WISPAD_TEXT_BENCH_MOTS=/private/tmp/essai/mots.json scripts/text-bench.sh   # étape mots sur un corpus d'essai
```

Clés de test seulement (`scripts/test-keys.sh`) : `WISPAD_TEST_DEEPSEEK_API_KEY` toujours, `WISPAD_TEST_XAI_API_KEY`
avec `--record` seulement. Elles viennent de l'environnement ou du coffre (`WISPAD_SECRET_COMMAND`) et restent dans
l'environnement du seul processus de test, jamais en argument d'une commande. Les chemins du texte doivent être
identiques au commit (rien de modifié sans commit). Une dizaine de minutes, dont une compilation complète de la base.

## Ce qui est mesuré

**Étape correction.** Une cinquantaine de dictées de l'historique : celles dont le texte final garde un morceau de
phrase isolé par une pause (une phrase de 1 à 5 mots qui commence par Ou, Où, Quand, Dont, Avec, Sans, Sauf, Comme ou
Pour, hors « Ou alors », « Ou est-ce » et « Ou même » ; exemple inventé : « Je cherche un réglage. Ou pas. »), 5
témoins avec « . Parce que », 4 avec « Ou alors », et 25 tirées au hasard (graine fixe, 8 à 220 mots). Pour chacune :
le texte brut, l'app, le dictionnaire, et les dictées précédentes comme l'app les joint (même app, collées, moins de
30 minutes avant, 5 au plus, 1 500 caractères au plus). Chaque version les corrige avec sa propre correction
(`TextCleaner`, DeepSeek), un second essai en cas d'échec, puis sa dernière normalisation, comme l'app.

**Étape flux.** 24 à 30 enregistrements de 6 à 45 s, pour près de moitié pris parmi ceux que des pauses avaient coupés
en morceaux. Avec `--record`, chacun est rejoué une fois en temps réel dans le flux xAI, avec l'adresse que
construit l'app (`LiveSpeechSession` : paramètres, langue, mots-clés), et le banc garde chaque événement reçu, brut,
ainsi que la réponse brute de la transcription du fichier. Ensuite, chaque version relit ces réponses sans réseau,
avec son propre code : les événements passent dans sa `LiveSpeechSession` (assemblage par `TranscriptAssembler`, fin
du flux), la réponse dans son `BatchTranscriber`. Puis le choix de l'app : le flux s'il dit la même chose que le
fichier (`TranscriptEquivalence`), sinon le fichier, avec le flux en autre écoute ; puis `FranglaisNormalizer` et
la correction. L'étape ne coûte rien chez xAI et son texte du flux est identique d'un passage à l'autre.

**Étape mots.** Les mots mal entendus qui restent dans le texte collé, contre une référence privée de ce qui a
vraiment été dit : voir [Étape mots](#étape-mots). Sans cette référence, l'étape est sautée.

**Passages.** base-0, head-0, base-1, head-1, en alternance, chacun avec toutes les étapes : une dérive de DeepSeek
pendant le banc touche les deux versions. La base tourne dans un arbre Git temporaire et détaché sous `/private/tmp`,
retiré à la fin, où le script copie le harnais de HEAD (`TextBenchLiveTests.swift` et `SpendLedger.swift`) : la même
mesure s'applique aux deux.

| Mesure | Définition |
| --- | --- |
| Dictées corrigées | Correction réussie, moyenne des deux passages. |
| Phrases de 4 mots ou moins | Dans les textes de plus d'une phrase, puces de liste exclues. |
| Mots par phrase | Moyenne sur tous les textes. |
| Fidélité | Distance d'édition moyenne, en mots (casse, accents et ponctuation ignorés), entre l'entrée de la correction et le texte final. Plus bas : plus fidèle. |
| Bruit | Écart entre les passages 0 et 1 d'une même version (fidélité, textes différents). |
| Écart base/head | Dictées dont le texte final diffère entre la base et HEAD, au même passage. |
| Délai | Médiane et 90e centile du délai de la correction. |
| Jetons | Entrée (cache compris) et sortie, par correction. |
| Coût pour 1 000 dictées | Au tarif de `Pricing`. |
| Accord aux jonctions (flux) | À chaque jonction entre deux segments finaux du flux : fin de phrase ou suite. Part des jonctions où le texte du flux décide comme la transcription du fichier, prise comme référence. Donné aussi pour le texte final, à titre indicatif. |
| Pièges réparés, témoins gardés (mots) | Contrôles de la référence qui passent sur le texte final, moyenne des deux passages. |
| Artefacts | « v. » isolés devant un mot dans les textes finaux de toutes les étapes, moyenne des deux passages. |

## Étape mots

**Référence privée.** L'étape part de dictées dont on sait ce qui a vraiment été dit. Leur référence est faite à la
main, dans `~/Library/Application Support/Wispad/benchmarks/texte/mots.json` : le script ne la crée ni ne la modifie
jamais. Sans ce fichier, l'étape est sautée avec une note, et le banc reste valable sur les deux autres. Avec
`WISPAD_TEXT_BENCH_MOTS=<fichier>`, il en prend un autre pour un essai, et le verdict le note (`corpusMots`). Chaque
cas donne ce que les écoutes ont entendu (flux et fichier de xAI, seconde écoute d'Apple sur le Mac), son contexte et
ses contrôles :

```json
{"version": 1, "cases": [{
  "id": "UUID", "group": "piege|temoin|neutre|v",
  "stream": "texte du flux xAI ou null", "file": "texte du fichier xAI ou null",
  "local": "seconde écoute Apple ou null", "app": "nom d'app ou null",
  "previous": ["dictées précédentes"], "dictionary": ["termes"],
  "checks": [{"kind": "piege|temoin", "ok": "regex", "ko": "regex ou null", "note": "court"}]
}]}
```

Le script vérifie ce format avant toute compilation ; une erreur donne le rang du cas, jamais son texte.

**Ce que refait chaque version**, cas par cas, comme l'app (`DictationCoordinator`) :

1. Texte retenu : le fichier si le flux est vide ; le flux si le fichier est vide ou dit la même chose
   (`TranscriptEquivalence`) ; sinon le fichier, avec le flux en autre écoute. Une version qui a le vote des écoutes
   confie ce dernier cas à `ListeningVote` : le flux si le texte voté dit la même chose que lui, sinon le texte voté,
   avec le flux en autre écoute.
2. `FranglaisNormalizer` sur le texte retenu et sur l'autre écoute.
3. Passages de la seconde écoute (`LocalHearing.divergences`), protégés par le dictionnaire du cas et
   `TechVocabulary`, avec l'orthographe de macOS comme `makeCorrectionRequest` : mot connu en français, terme anglais.
   Elle répond dans `swift test` (vérifié le 31 octobre 2026). Si une langue y manque, ou ne distingue pas un mot
   courant d'un mot inventé, son filtre vaut nil, comme dans l'app sans cette langue, et le verdict le note.
4. La correction de l'étape correction : même langue, second essai, dernière normalisation.

Le banc garde, par cas : la source retenue (flux, fichier ou vote), le texte final, la réussite, le délai, le coût et
les jetons. Chaque passage de l'étape réserve d'abord le pire coût de ses cas, comme les autres.

**Contrôles.** Un piège est un mot mal entendu que le texte final doit avoir réparé ; un témoin, un mot juste qu'il
doit avoir gardé. Un contrôle passe si `ok` trouve une correspondance dans le texte final (expression régulière de
Python, casse ignorée) et si `ko`, quand il existe, n'en trouve aucune. Exemple inventé : la dictée dit « les mots du
jour », le fichier entend « les mottes du jour » ; ce piège passe quand le texte collé dit de nouveau « mots » :
`{"kind": "piege", "ok": "\\bmots\\b", "ko": "\\bmottes\\b", "note": "mottes pour mots"}`.

**Artefacts.** Un « v. » isolé devant un mot, `(?<![\w'’.])v\.\s+(?=\w)`, compté dans les textes finaux de toutes les
étapes : une dictée ne l'écrit presque jamais.

**Seuils.** Rouge si HEAD garde plus d'un témoin de moins que la base, répare plus d'un piège de moins, ou laisse plus
d'artefacts qu'elle, en moyenne sur les deux passages ; ou si l'étape franchit les seuils habituels de dictées
corrigées, de délai et de jetons. Sa fidélité est donnée à titre indicatif : réparer un mot en change un.

**Rapport.** `rapport.md` liste chaque contrôle qui change entre la base et HEAD : son cas, sa note, sa réussite sur
les deux passages de chaque version et le texte final des deux. La sortie standard n'en donne que le nombre.

### Une fonction de version : le vote des écoutes

Le harnais tourne dans les deux versions, et la base n'a pas toujours le code qu'il mesure. Une fonction de version
s'appelle donc sous un drapeau de compilation, que `text-bench.sh` ne pose que sur un arbre qui a son fichier :
`-Xswiftc -DWISPAD_VOTE_DES_ECOUTES` quand `Sources/WispadCore/ListeningVote.swift` existe. Une version qui a le vote
le compile et l'applique ; une base plus ancienne, comme v0.8.2, compile le même harnais sans lui. Le script le dit à
la compilation, et l'étape mots l'affiche (« vote des écoutes base absent, head compilé »). Une autre fonction de
version suit le même chemin : un `#if` dans le harnais, un test de fichier dans `build()`. Si ce fichier change de
nom, le drapeau tombe sans erreur : la ligne du vote le montre.

## Verdict

Rouge si, pour l'une des étapes, HEAD fait moins bien que la base au-delà du bruit :

- moins de dictées corrigées que la base, moins une ;
- étapes correction et flux : fidélité moins bonne de plus de max(0,5 mot, bruit) ;
- étapes correction et flux : plus de 2 phrases de 4 mots ou moins de plus ;
- délai médian au-delà de la base × 1,15 + 50 ms ;
- jetons d'entrée au-delà de la base × 1,25 ;
- étape flux : accord aux jonctions du texte du flux inférieur de plus de 5 points (ce texte ne dépend pas de
  DeepSeek : aucun bruit) ;
- étape mots : plus d'un témoin gardé, ou plus d'un piège réparé, de moins que la base ;
- plus de « v. » isolés que la base dans les textes finaux de toutes les étapes.

Sinon vert. Le script écrit `verdict.json` (`sha`, `base`, `date`, `pass`, métriques, raisons, `corpusMots`) et
`rapport.md`, un rapport privé qui montre les contrôles de l'étape mots qui changent et les dix dictées qui changent
le plus, textes compris, pour une relecture humaine : un vert dit seulement qu'aucun seuil n'est franchi. Sur la
sortie standard : des chiffres et le verdict, jamais un texte dicté.

## Coût

L'enregistrement de l'étape flux coûte 0,04 $ au plus (8 minutes d'audio, flux et fichier, 0,30 $ de l'heure). Un
banc coûte environ 0,04 $ de DeepSeek hors de ses heures pleines, le double pendant : quatre passages d'environ 75
corrections. Chaque passage réserve d'abord son pire coût dans le plafond des tests réseau (`SpendLedger`, 6 $ au
total), environ 0,22 $ (toute l'entrée hors cache, sortie maximale, tarif plein), puis n'y garde que le coût mesuré ;
un passage qui dépasserait sa réservation s'arrête. Le banc refuse donc de partir quand il reste moins de 0,22 $ sous
le plafond. L'étape mots ajoute une correction par cas et par passage, environ 0,0001 $ chacune, et réserve à part
environ 0,003 $ par cas, dans le même plafond. Le script affiche le cumul à la fin.

## Repères

Validation du 31 octobre 2026, 0.8.2 contre 0.8.1 : verdict vert. Étape correction, consigne identique : seulement du
bruit (13 textes sur 48 différents entre base et head, pour 10 à 15 d'un passage à l'autre d'une même version ;
fidélité 7,88 et 7,97 mots, bruit jusqu'à 0,29 ; délai médian à ±7 % d'un passage à l'autre). Étape flux, recollage
des morceaux coupés par une pause (`PauseJoin`) : phrases de 4 mots ou moins 7,5 → 4,0, mots par phrase
15,5 → 17,4, accord aux jonctions du texte du flux 34,9 % → 72,3 % sur 83 jonctions, délai dans le bruit (médianes
de 1 041 à 1 162 ms selon le passage).

## Confidentialité

Tout reste dans `~/Library/Application Support/Wispad/benchmarks/texte/` (dossier 0700, fichiers 0600), jamais dans
le dépôt : le corpus (`correction.json`, `flux-entree.json`), l'enregistrement (`flux.json`), la référence de l'étape
mots (`mots.json`) et, par commit, les passages (`mots-*.json` pour l'étape mots), les journaux, `rapport.md` et
`verdict.json`. L'historique (`wispad.sqlite`) est ouvert en lecture seule. Supprimer ce dossier efface tout ; le
prochain banc reconstruit le corpus et demande `--record`, mais `mots.json`, fait à la main, ne se reconstruit pas.

## Réenregistrer l'étape flux

Les réponses enregistrées ne valent que pour les paramètres envoyés à xAI. Une version qui change les paramètres du
flux (`LiveSpeechSession.endpoint()` : modèle, échantillonnage, fin de parole, seuil de voix, langue, mots-clés), ceux
de la transcription du fichier (`BatchTranscriber`) ou le modèle de voix par défaut doit être réenregistrée :
`scripts/text-bench.sh --record`. Le script relève une empreinte de ces passages du code à l'enregistrement et
s'arrête si HEAD en a une autre. Un changement de l'ordre de fin du flux (`finalize`, `audio.done`) demande aussi
`--record`, sans détection automatique. Les audios de l'historique expirent : on réenregistre tant qu'ils existent.

## Limites

Le harnais (`Tests/WispadCoreTests/TextBenchLiveTests.swift`) reproduit l'orchestration de l'app
(`DictationCoordinator` : fichier arrivé à temps, choix du texte, normalisations, correction) avec les réglages par
défaut (français, listes, heures compactes, ton naturel), sans texte voisin, fenêtre ni correction préparée pendant
la dictée. Seule l'étape mots a une seconde écoute, celle de sa référence, et donc le vote des écoutes. Un changement
de cette orchestration se reporte dans le harnais pour être mesuré. Le harnais tourne aussi dans la base : il
n'appelle que du code présent dans les deux versions, sauf sous un drapeau de version (voir [Étape mots](#étape-mots)).
