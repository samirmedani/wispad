# Comportement de Wispad

Référence du comportement attendu. Chaque règle est couverte par un test ou mesurée ; une modification de
comportement met ce document à jour dans le même commit.

## Raccourci

Raccourci par défaut : fn seule. Wispad intercepte la touche fn pour que macOS ne lance pas sa propre action
(dictée Apple, emojis).

- Maintien : dictée tant que la touche est tenue. Le micro démarre après 170 ms, pas avant, pour ignorer un appui simple.
- Double appui rapide : dictée mains libres dès le deuxième enfoncement, sans attendre son relâchement. Un appui suivant l'arrête.
- Appui simple au repos : aucune action, ni micro, ni bulle.
- Échap pendant l'écoute, ✕ ou Annuler : abandon sans rien insérer. Échap est alors avalé et n'atteint pas l'app.
  Pendant la transcription ou un message d'erreur, Échap annule aussi (rien n'est collé) mais reste à l'app ;
  au repos, il n'appartient qu'à l'app.
- Moins de 0,3 s d'audio : rien n'est envoyé.
- Une nouvelle dictée peut commencer pendant que la précédente se termine : les textes se collent dans l'ordre
  où ils ont été dits, séparés par une espace, sans changer de majuscule.

### Coller la dernière dictée

Raccourci global, ⌃⌥V par défaut : faisable d'une main (⌃⌥ sous le pouce et l'annulaire gauches, V sous l'index),
libre dans macOS et rare dans les apps courantes, contrairement à ⌘⇧V (coller sans mise en forme) et ⌥⌘V (déplacer
dans le Finder). Sur un clavier AZERTY ou QWERTZ, c'est la même touche V.

- Il colle au curseur actuel la dernière dictée non insérée de la dernière demi-heure (prête à copier, aucun champ,
  collage raté, champ sécurisé), sinon la dernière dictée. Jamais une dictée annulée, vide ou sans transcription.
  Rien à coller : la bulle le dit (« Aucune dictée à coller »).
- Même collage qu'une dictée (⌘V, presse-papiers restauré après), envoyé une fois ⌃ et ⌥ relâchés (0,6 s au plus).
  Collée, une dictée non insérée passe à « Inséré » ou « Collage envoyé » ; un nouvel échec ne change jamais le
  statut d'une dictée déjà livrée. Toujours pas de champ : le texte est copié et la bulle affiche le même message
  qu'après une dictée.
- Avalé : la combinaison n'atteint pas l'app. Une fois par enfoncement (la répétition ne recolle pas). Ignoré
  pendant une écoute ; les dictées qui se terminent se collent d'abord.
- fn n'en fait jamais partie : fn enfoncé (dictée en maintien), ⌃⌥V n'est pas le raccourci, et un appui simple sur
  fn ne déclenche toujours rien.
- Réglages › Raccourci › « Coller la dernière dictée » : Modifier, puis la combinaison voulue (Échap annule) ;
  « Par défaut » remet ⌃⌥V ; l'interrupteur le désactive sans oublier la combinaison. Refusées, avec la raison :
  touche seule ou avec ⇧ seulement (elle écrirait), ⌘ avec une seule touche (menus des apps), fn, Échap, le
  raccourci de dictée, les combinaisons connues de macOS et des apps (⌘⇧V, ⌥⌘V, ⌘Espace, captures d'écran…) et
  celles déclarées dans Réglages Système › Clavier › Raccourcis. Le raccourci actuel est suspendu pendant
  l'enregistrement.
- Affiché dans la carte « Raccourcis » de la barre latérale quand il est activé.

## Réactivité

- L'écoute du clavier tourne sur son propre fil : le clavier n'attend jamais l'app. Elle est vérifiée toutes les
  3 s et rétablie si macOS l'a coupée.
- L'audio s'initialise sur une file dédiée, la bulle s'affiche tout de suite ; le moteur arrêté est réutilisé.
- Le micro reste fermé au repos ; un appui simple ne le prépare pas.
- La lecture du champ actif (lente dans les apps Electron) ne retarde pas l'enregistrement : l'audio est gardé
  jusqu'à ce que la transcription en direct soit branchée (le champ est attendu 150 ms au plus pour ses mots-clés).
- Chaque dictée ajoute une ligne à `~/Library/Application Support/Wispad/latence.log` (date, mode ; appui →
  bulle, micro, premier audio, flux ; fin → collé ; statut), sans aucun texte, 500 lignes au plus.

## Bulle

- Verre noir (Liquid Glass sur macOS 26+) au-dessus du Dock, sur le bureau comme au-dessus d'une app en plein
  écran, avec le spectre de la voix (graves au centre) à la cadence de l'écran (120 Hz en ProMotion).
- Elle laisse passer les clics, sauf sur ses boutons : ✕ / ■ en mains libres, Copier et Coller d'un texte non
  écrit, Oui / Non d'un mot appris.
- Messages (erreur, mot appris) sur une ligne, avec une barre qui se vide avant leur départ.
- Deux notes montantes signalent le premier audio réellement reçu, une seule fois ; d'autres sons marquent la fin
  et l'annulation. Tous se coupent dans Réglages.
- Une app passée en plein écran après la première bulle reçoit une bulle neuve : macOS ne rattache une fenêtre de
  tous les bureaux à un espace plein écran qu'à sa première apparition.

## Fenêtre

- Ouverte depuis le menu de la barre des menus, le Dock ou un raccourci de section, elle vient sur le bureau où
  l'on se trouve, même par-dessus une app en plein écran ; déjà visible sur ce bureau, elle ne bouge pas.
- Une fois affichée, c'est une fenêtre ordinaire : passer à une autre app, cliquer sur le bureau ou changer de
  bureau la laisse à sa place et sur son bureau, simplement derrière l'app active.
- Choix d'affichage mémorisés, retrouvés après avoir quitté et relancé Wispad, chacun enregistré dès qu'il change :
  - période de l'Accueil (7 jours par défaut) ;
  - période de Consommation (Aujourd'hui par défaut), indépendante de celle de l'Accueil ;
  - dernière section ouverte dans la barre latérale (Accueil par défaut) : la fenêtre rouvre dessus depuis le
    Dock ou « Ouvrir Wispad » ; un raccourci de section ou un menu de section ouvre toujours la sienne ;
  - « Clés facultatives » dépliées ou non dans Fournisseurs (repliées par défaut).

  Un choix illisible ou inconnu reprend sa valeur par défaut, sans toucher aux autres réglages. Restent
  éphémères : la recherche de l'Historique, une saisie en cours (clé, terme du dictionnaire), une dictée dépliée
  dans l'Historique, le détail ouvert.

## Réglages

Sections, dans l'ordre : Raccourci, Transcription, Correction, Ton selon l'app, Confidentialité, Apprentissage,
Général, Autorisations, Diagnostic. Aucun bloc de texte sous une liste : chaque réglage porte, dans sa rangée, une
explication d'une ligne sous son libellé, en langage simple (ni montant, ni chiffre, ni nom de modèle). Les détails
(fournisseurs et modèles réellement utilisés, coût, délais, ce qui est envoyé ou gardé) s'ouvrent dans un popover
avec le bouton ⓘ de la rangée ; ceux de la correction suivent les clés enregistrées.

- **Confidentialité** : « Ce qui est envoyé » (audio et, si disponibles, app active, sélection et court extrait
  autour du curseur ; historique et audio restent sur ce Mac), « Comprendre le sujet grâce à la fenêtre active »
  (inactif sans la correction), conservation, durée et plafond de l'audio.
- **Correction** : « Corriger le texte avant insertion », « Structurer les listes et paragraphes », « Réécrire la
  sélection sur consigne » (inactif sans la correction). Le ton se règle dans la section suivante, inactive sans la
  correction.

## Premier lancement guidé

Au premier lancement (aucun réglage enregistré), la fenêtre affiche une configuration en sept étapes, avec une
barre de progression : Bienvenue, Autorisations, Micro, Fournisseur, Touche, Essai, Fin. Chaque étape est à faire,
en cours, réussie (✓) ou en problème (✗, avec la marche à suivre) ; « Continuer » n'est actif qu'une fois l'étape
réussie. « Plus tard » est proposé seulement pour le micro, la touche et l'essai.

- **Autorisations**, toutes sur un écran : micro, accessibilité (coller le texte), surveillance des entrées (touche
  fn). « Autoriser » déclenche la demande de macOS ; ensuite, ou après un refus, le bouton ouvre le bon panneau de
  Réglages Système et le chemin exact est affiché. L'état est relu toutes les 0,5 s. Surveillance des entrées
  accordée mais écoute du clavier impossible après 3 s : macOS attend une relance, « Relancer Wispad » rouvre l'app
  à la même étape.
- **Micro** : choix du micro (celui du système par défaut ; le micro choisi sert ensuite aux dictées tant qu'il est
  branché, sinon celui du système ; Réglages › Général › Micro) et vumètre réel. ✓ quand une vraie voix est
  entendue : au moins 0,6 s au-dessus de −48 dBFS et 10 dB au-dessus du bruit de la pièce (un clic, un souffle ou
  un ventilateur ne suffisent pas). Sans voix après 12 s, l'écran dit quoi vérifier. Seul le niveau est lu :
  l'audio n'est ni enregistré, ni gardé, ni envoyé.
- **Fournisseur** : xAI ou OpenAI, clé collée puis vérifiée chez le fournisseur avant d'être enregistrée (même
  vérification que Fournisseurs) ; une clé déjà enregistrée est revérifiée sans être réécrite. ✓ seulement avec une
  clé acceptée. Lien vers la page de création de clé de chaque fournisseur. Correction facultative (DeepSeek, relais
  OpenAI) avec la même vérification, et les réglages « Comprendre le sujet grâce à la fenêtre active » et
  « Apprendre de mes corrections ».
- **Touche** : maintien et double appui expliqués ; pendant cette étape, chaque appui est seulement constaté
  (« Touche détectée », gestes reconnus allumés) et aucune dictée ne démarre. Rien reçu en 10 s : rappel de la
  surveillance des entrées, et du réglage macOS « Touche fn/🌐 : Ne rien faire » s'il lance autre chose.
- **Essai** : vraie dictée avec la touche dans un champ de l'écran, phrase suggérée. Le test de la touche est
  toujours rendu en arrivant ici (un test resté actif hors de l'étape « Touche » est abandonné) : le raccourci
  dicte pour de vrai. Dictée faite dans la fenêtre de Wispad : son texte final s'écrit directement dans le champ
  d'essai, sans collage système. ✓ quand une dictée se termine et que son texte arrive dans le champ (2 s au plus
  après un collage), avec le nombre de mots et la durée. Un texte tapé à la main ne compte pas. Aucune attente
  n'est infinie : geste reçu sans écoute ouverte en 4 s, ou micro qui s'ouvre / dictée qui se termine sans aboutir
  en 45 s, et l'essai passe en échec avec sa cause. En cas d'échec, la cause : micro, clé, réseau, fournisseur,
  rien entendu, collage, annulation, dictée non démarrée ou délai dépassé, avec « Réessayer » et l'étape à revoir.
- **Fin** : rappel des deux gestes, lien vers Réglages, « Terminer ».

Une installation existante (réglages sans ce champ) ne refait pas la configuration après une mise à jour.
Réglages › Général › « Revoir la configuration » la rejoue sans rien effacer ; on peut la quitter à tout moment.
Fenêtre fermée pendant la configuration : le test du micro s'arrête et la touche dicte de nouveau normalement.

## Transcription

Toujours chez un fournisseur, au choix dans Fournisseurs : xAI `grok-voice-transcribe-2.0` (recommandé) ou OpenAI
`gpt-live-transcribe`, en direct pendant l'écoute. Par défaut, l'enregistrement complet est aussi transcrit à la fin
(« Vérifier chaque dictée sur l'enregistrement complet », environ 0,0005 $ de plus) :

- même texte (casse, accents, ponctuation, hésitations, nombres en lettres ou en chiffres, unités, élisions,
  en français comme en anglais) : le flux est gardé, sa correction déjà lancée est collée ;
- texte différent : celui du fichier est corrigé et collé, le flux sert d'« autre écoute » à la correction et reste
  avec la dictée dans l'historique local (pour comprendre le désaccord et pour le banc des erreurs signalées) ;
- texte différent d'un ou deux remplacements courts (trois mots au plus, même nombre de mots à un près, voisin
  retrouvé, mot unique dans la correction, aucun terme du dictionnaire) : les mots du fichier sont reportés dans la
  correction du flux, sans second appel, si elle est prête dans les 0,3 s. Sinon, correction complète du fichier ;
- fichier en échec, sans aucun mot ou trop lent (1,2 s + 0,06 s par seconde d'audio, 4 s au plus) : le flux est
  gardé. Il l'est aussi quand le réglage est coupé et qu'une fin de flux peu fiable rappelle un fichier vide.

**Sans connexion** : rien n'est transcrit sur le Mac. Si la connexion manque ou se perd pendant la dictée (flux,
fichier, puis le relais de voix s'il a une clé, en échec), l'audio reste dans l'historique pour **Retranscrire** une
fois la connexion revenue. La correction par un fournisseur est sautée hors connexion (seules les commandes de mise
en page s'appliquent).

Une installation qui transcrivait « Sur ce Mac » (fonction retirée) repasse sur le cloud au lancement ; les modèles
téléchargés par Wispad et les réglages devenus inutiles sont effacés.

La trace de chaque dictée donne la source retenue, la raison, les durées, le nombre de mots en désaccord entre flux
et fichier, l'usage de la correction préparée pendant l'écoute et le report des mots du fichier, jamais le texte.

## Correction

- Automatique : deux services au plus, DeepSeek (`deepseek-flash`, sans raisonnement) d'abord s'il a une clé.
  Voix chez xAI : relais OpenAI `gpt-5.4-mini` s'il a une clé, sinon le modèle de correction de xAI. Voix chez
  OpenAI : DeepSeek seul s'il a une clé, sinon le modèle de correction d'OpenAI. 2,5 s chacun, 4 s pour un service
  seul, plus 1 s par 800 caractères dictés. Au-delà, le texte transcrit est inséré tel quel (avec les seules
  commandes explicites de mise en page).
- Pas d'autre service de correction : le serveur compatible OpenAI choisi par l'utilisateur (fonction retirée)
  repasse sur la correction automatique au lancement ; son adresse et son modèle sont effacés, ses anciens appels
  sortent de Consommation. Sa clé reste dans le fichier de clés, comme celle de tout fournisseur retiré.
- Consigne en français ou en anglais selon la langue de dictée (en automatique, devinée sur la transcription).
- Hésitations, bégaiements, faux départs et **autocorrections orales** retirés : « mardi, ah non, mercredi »
  devient « mercredi ». Un « non » qui fait partie du message reste.
- Nombres écrits en chiffres ; élisions orales écrites en entier (« j'sais » → « je sais ») ; tournures
  familières gardées (« t'as », « y a »).
- La correction ne répond jamais au contenu dicté et ne recopie jamais le contexte.
- **Correction préparée pendant l'écoute** : à chaque pause de la parole (segment final du flux, puis 0,25 s sans
  nouveau mot), le texte entendu part déjà à la correction. Si l'on arrête sans rien ajouter (même texte à la
  ponctuation, la casse ou l'écriture des nombres près), cette correction sert telle quelle et le texte se colle sans
  attendre un nouvel appel. Si la parole reprend, elle est comptée (coût réel)
  et la suivante la remplace ; quatre au plus par dictée. Jamais si la correction est coupée.
- Expressions mal entendues malgré les mots-clés, réécrites avant et après la correction : « services functions »
  → « serverless functions », « day inference » → « AI inference ».

## Contexte envoyé à la correction

Réglage « Comprendre le sujet grâce à la fenêtre active », proposé au premier lancement, désactivé par défaut
pour une nouvelle installation.

- Fin de la conversation visible dans la fenêtre où l'on dicte (2 000 caractères au plus, lue pendant l'écoute
  en 300 ms au plus) et dernières dictées livrées dans la même app (cinq, trente minutes, 1 500 caractères).
- Texte autour du curseur et sélection, pour l'orthographe.
- Rien de ce contexte n'est enregistré ni journalisé ; il n'ajoute jamais un mot qui n'a pas été dit.

## Garde-fou de fidélité

Après la correction, `FidelityGuard` rejette ou répare :

- une réponse nettement plus longue que la dictée, ou qui recopie huit mots de suite du contexte ;
- un mot traduit (« outils » → « tools ») : le mot entendu est remis ;
- une marque, un nom ou une référence absents de ce qui a été dit et qui ne lui ressemblent pas à l'oreille ;
- une référence lettres puis chiffres (DDR4, i9) dont les chiffres n'ont pas été prononcés ;
- sur une dictée de trois mots au plus, tout mot qui ne ressemble pas au mot entendu, ou qui s'ajoute (hors « ne »
  rétabli) : la transcription est collée (« Était sérieux » ne devient pas « Sois sérieux », « cloud code » devient
  bien « Claude Code »).

Les vraies corrections d'écoute restent (« versel » → Vercel, 9950X3D, « envoie le » → « Envoie-le »).

## Franglais technique

- Vocabulaire technique intégré (`TechVocabulary`) envoyé comme mots-clés à xAI après le dictionnaire et le
  contexte (100 au plus).
- Retouches déterministes prudentes (`FranglaisNormalizer`) : références matérielles recollées, « Auth 2.0 »
  → OAuth 2.0 (« Auth » seul seulement avec un contexte OAuth), « j'ai fixe le bug » → « j'ai fix le bug ». Chaque règle exige un indice
  impossible en français correct ; une liste de pièges est verrouillée par les tests.
- Consignes dictées (« OK, ajoute à la liste ») gardées comme texte ; une puce isolée redevient une phrase.

## Mise en forme

Réglage « Structurer les listes et paragraphes » : énumérations et changements d'idée mis en forme par la
correction. Avec ce réglage, commandes explicites locales, même sans correction : « première puce », « deuxième
puce »… jusqu'à la dixième (aussi « premier point », « premièrement »), « fin de liste », « nouveau paragraphe »,
« à la ligne », « nouvelle ligne » (et « first bullet », « firstly », « end of list », « new paragraph »,
« new line »).

Listes sans annonce : dès trois éléments courts et parallèles (courses, tâches, noms, options),
la correction fait une liste à puces, une majuscule par élément, sans ponctuation finale ni « et ». La phrase qui
annonce les éléments reste au-dessus et finit par « : » (« Pour les courses, il me faut : » puis « - Des tomates »…).
Restent des phrases : deux éléments, une énumération suivie d'autre chose dans la phrase (« J'ai vu Paul, Marc et
Julie hier au cinéma. »), un récit d'actions. Banc réseau : `scripts/live-test.sh ImplicitListLiveTests` (18/20 le
11 octobre sur Grok, 8/20 avec l'ancienne consigne ; les deux échecs restants sont des appels sans réponse, texte
gardé tel quel).

## Ton et consignes

- **Ton selon l'app** (Réglages › Ton selon l'app) : par catégorie (e-mails, messageries, documents, notes, code et
  terminal, navigateur, autres apps), « Comme dicté » (par défaut, comportement d'origine), « Soigné » (tournures familières écrites
  en forme standard, « ne » rétabli) ou « Détendu » (tournures gardées, pas de point final pour un message court).
  Le ton ne change que le registre, jamais les mots ni le sens ; le garde-fou de fidélité s'applique toujours.
- **Consigne sur la sélection** (Réglages › Correction › « Réécrire la sélection sur consigne », actif par défaut) : avec du texte
  sélectionné, une dictée qui commence par une consigne d'écriture (« reformule », « traduis », « résume », « corrige »,
  « raccourcis », « rends-le… », « mets ça en… », « rewrite », « translate », « make it… ») réécrit la sélection
  (6 000 caractères au plus) avec les fournisseurs de correction, sans garde-fou de fidélité. Une autre dictée remplace
  la sélection comme d'habitude. Sans réponse (ou hors connexion), rien n'est collé et la sélection reste intacte.
  Aucune correction n'est préparée pendant l'écoute pour une consigne ; rien n'est appris d'une sélection réécrite.

## Dictionnaire et apprentissage

- Les termes du dictionnaire partent à la transcription (mots attendus) et à la correction.
- Les raccourcis vocaux (« Quand je dis… » → « Écrire… ») ont été retirés : ceux déjà enregistrés n'ont plus
  aucun effet et sont effacés des réglages au lancement.
- Après une dictée insérée, le champ est relu toutes les 250 ms pendant 30 s, hors du fil principal. Un mot mal
  entendu corrigé à la main (« Sidance » → « Seedance ») est jugé : marque, nom, sigle ou jargon seulement. Avec
  une clé TypeSafe, Jev le note d'abord et tranche les cas nets ; le modèle de correction décide des autres (et
  de tous sans clé TypeSafe). Sans réponse du modèle de correction, la note de Jev suffit.
- Le mot retenu est ajouté, puis la bulle demande « Le garder ? » (Oui / Non, 8 s, sans prendre le focus). Non
  le retire et ne le propose plus jamais.
- Seuls la phrase dictée et le mot corrigé sont envoyés (à Jev et au modèle de correction) ; le journal ne contient ni mot ni texte.

## Relais en cas de panne

- Voix : si xAI ne répond pas, le même enregistrement part chez OpenAI (et inversement) s'il a une clé ; après deux
  échecs, la dictée démarre directement chez l'autre fournisseur.
- Correction : après deux échecs, DeepSeek passe après le relais. Un service mis de côté est contrôlé chaque
  minute et repris dès qu'il répond, au plus tard après 30 minutes.
- Le spectre passe au vert quand un relais travaille ; la première bascule d'une panne est annoncée.

## Reprise après erreur

- Erreur réseau, de clé ou de quota : l'audio reste dans l'historique ; **Retranscrire** puis **Copier**.
- Texte qui n'a pu être écrit nulle part : jamais en silence. La bulle le dit en une ligne, avec **Copier** en
  évidence et **Coller** : « Pas de champ où écrire : le texte est prêt » (focus sur une liste, un bouton, un menu,
  ou le bureau et les fenêtres du Finder, avant comme après ⌘V), « Collage impossible : le texte est prêt »
  (accessibilité refusée, app cible fermée ou qui n'a pas repris le premier plan, presse-papiers non modifiable,
  ⌘V non envoyé), « Champ sécurisé : le texte est prêt ». Le texte est déjà copié, sauf pour un champ sécurisé.
  12 s, avec une barre qui se vide ; ✕ au survol ou Échap la ferment. Elle ne prend jamais le focus : **Copier**
  remet le texte au presse-papiers et confirme « Copié » (1,5 s), **Coller** le colle dans le champ de l'app
  active (même collage que « Coller la dernière dictée »). Le collage garde tous les formats du presse-papiers
  précédent et refuse les champs sécurisés.
- Sans confirmation d'accessibilité, le statut reste « Collage envoyé », sans fausse alerte : un champ illisible
  ou un conteneur (groupe, zone web, fenêtre, tableau) ne prouve pas l'échec, beaucoup d'éditeurs (Electron,
  terminaux, éditeurs dessinés) collent sans exposer leur texte. « Coller la dernière dictée » rattrape un tel
  collage parti dans le vide.
- Lectures d'accessibilité bornées au collage : champ actif 0,3 s avant ⌘V, confirmation 0,7 s après. Une app qui
  construit encore son arbre (Chrome à la première dictée) ne retarde ni le texte ni la dictée suivante.
  Champ non lu avant ⌘V : il est relu pendant la confirmation. La confirmation ne compare que lettres et chiffres
  (les éditeurs riches réécrivent tirets de liste, apostrophes et retours) et demande que le début du texte collé
  apparaisse une fois de plus qu'avant. Un collage non confirmé laisse sa cause dans le journal `insertion`, sans texte.
- Les apps Electron ouvrent leur arbre d'accessibilité avec AXManualAccessibility ; les navigateurs Chromium
  (Chrome, Brave, Edge, Arc, Vivaldi, Opera) l'ignorent et reçoivent aussi AXEnhancedUserInterface, comme pour un
  lecteur d'écran : le champ d'une page devient lisible (confirmation du collage, contexte, apprentissage).
- Les audios expirés sont purgés chaque minute et au lancement.

## Signaler une erreur

- Détail d'une dictée › **Signaler une erreur** : on corrige le texte mot pour mot (ce qui a vraiment été dit).
- Le signalement garde ce texte, la transcription retenue, le texte collé et une copie de l'audio dans
  `Application Support/Wispad/benchmarks/signalements/<dictée>/` (dossier lisible par le seul utilisateur). La purge
  des audios de l'historique ne touche pas cette copie. Rien n'est envoyé ni journalisé.
- Un nouveau signalement de la même dictée remplace le texte et garde l'audio.
- `scripts/report-bench.sh <nom>` rejoue ces audios (fichier xAI puis correction, clés de test seulement) et compte
  les mots qui diffèrent de ce qui a été dit : avant, à l'écoute, maintenant.

## Consommation

- Chaque appel facturable est compté quand il a lieu : flux (durée d'audio), fichier, correction (jetons
  d'entrée, de cache et de sortie lus dans la réponse). Une dictée annulée compte l'audio déjà envoyé.
- Coûts estimés d'après les tarifs publiés (`Pricing` dans `Usage.swift`) ; la facture du fournisseur fait foi.
- Soldes réels DeepSeek et xAI (clé de gestion facultative), relus au plus toutes les 5 minutes.
- Une seule vue : tous les appels enregistrés comptent, filtrés seulement par la période (Aujourd'hui, 7 jours,
  30 jours, Tout). Les cartes, la liste des derniers appels et le menu de la barre partagent ces mêmes appels.
- Carte « Bascules vers un fournisseur de secours », sur la période choisie : une phrase dit ce qu'est une bascule
  (fournisseur principal en échec, trop lent ou mis de côté, la même demande part chez un autre fournisseur), puis un
  état : aucune bascule (« tes fournisseurs principaux ont toujours répondu »), secours toujours réussi (normal),
  ou à surveiller quand le secours a lui aussi échoué ou qu'un fournisseur principal a été mis de côté. Ensuite, par
  étape (transcription, correction, dictionnaire) : nombre de fois, sens (« xAI → OpenAI ») et ce que cela veut dire ;
  enfin les cinq dernières bascules (date, étape, fournisseurs, raison, secours réussi ou non). Seules deux raisons
  sont enregistrées : « échec ou délai dépassé » et « principal mis de côté ». Chaque passage au secours compte, même
  en échec. Quand la période commence avant le début de l'enregistrement des bascules, sa date est rappelée en petit.
- Rien de l'historique n'est effacé ; l'ancienne date de début du suivi financier est retirée au lancement.

## Clés API

- Par défaut : fichier de l'app (`Application Support/Wispad/api-keys.json`, lisible par le seul utilisateur du Mac).
- Coffre de secrets, au choix : une commande qui répond à `get NOM` (valeur sur la sortie, code 1 si absente) et
  `put NOM` (valeur sur l'entrée), indiquée par `WISPAD_SECRET_COMMAND` ou
  `defaults write com.yatofix.wispad wispad.secretCommand /chemin/vers/commande`. Clés lues au lancement, gardées
  en mémoire, rien d'écrit sur le Mac. Une clé que le coffre ne rend pas (connexion ratée) est redemandée deux fois
  (0,5 s puis 1,5 s) ; une clé absente ne l'est pas. Noms : `WISPAD_XAI_API_KEY`, `WISPAD_OPENAI_API_KEY`,
  `WISPAD_DEEPSEEK_API_KEY`, `WISPAD_XAI_MANAGEMENT_KEY`, `TYPESAFE_API_KEY`.
- Chaque clé de voix ou de correction (xAI, OpenAI, DeepSeek) est vérifiée chez le fournisseur avant d'être
  enregistrée ; les clés de gestion xAI et TypeSafe sont enregistrées sans vérification.

## Mises à jour et réinstallation

- Une mise à jour ou une réinstallation garde fournisseurs, réglages, clés API, historique et dictionnaire : même
  identifiant (`com.yatofix.wispad`), même dossier (`Application Support/Wispad`), mêmes préférences.
  `scripts/install.sh` ne remplace que l'app.
- Réglages lus un par un : un réglage absent prend sa valeur par défaut ; une valeur illisible ou retirée (mode,
  fournisseur, modèle) prend la valeur par défaut de ce seul réglage, ou la plus proche valide (fournisseur retiré →
  fournisseur par défaut, modèle retiré → modèle par défaut du même fournisseur). Les autres choix restent.
- Un réglage inconnu (retiré, ou venu d'une version plus récente) est ignoré mais gardé à l'enregistrement : revenir à
  une version précédente retrouve ses choix. Seuls les réglages retirés des raccourcis vocaux, de la transcription
  sur le Mac et du serveur de correction compatible OpenAI sont effacés au lancement. Lire les réglages ne les réécrit jamais.
- Bloc de réglages illisible en entier : une copie est gardée de côté, jamais effacée, et l'app repart sans refaire
  le premier lancement guidé.
- Les clés API d'un fournisseur retiré restent dans le fichier de clés.
- Reprise depuis OpenFlow (une seule fois) : réglages, base, audios, journaux et fichier de clés, sans rien écraser
  de Wispad ; ce qui n'est pas repris reste en place.

## Version et dépôt

- Bas de la barre latérale, au-dessus des raccourcis : un petit bandeau jaune « Une étoile sur GitHub »
  (« Star on GitHub » en anglais), sur une seule ligne et sans troncature à la largeur fixe de la barre, entièrement
  cliquable. Un clic ouvre la page du dépôt dans le navigateur, affiche « Merci ! » 1,6 s, puis le bandeau
  disparaît pour de bon (réglage `githubStarClicked`, enregistré dès le clic). Wispad ne peut pas savoir si
  l'étoile a été donnée : le clic suffit. Dessous, toujours visibles : la version (« Wispad 0.1.0 · abc1234 » :
  version et commit court gravé à la compilation), puis « À jour » ou « N commits de retard » (« 1 commit de
  retard ») sur la branche `main` du dépôt public. Un clic sur le retard ouvre la page des commits.
- Seul contact : `GET https://api.github.com/repos/samirmedani/wispad/compare/<commit>...main` (API publique, sans
  clé ni cookie), 5 s après le lancement puis toutes les 6 heures, 8 s au plus. Rien d'autre n'est envoyé que
  le commit de la version dans l'adresse. Le retard est le champ `ahead_by` (commits de `main` absents de la version).
- GitHub injoignable, dépôt privé (404), commit inconnu (compilation locale non publiée), réponse illisible ou
  commit non gravé (git absent à la compilation) : seule la version s'affiche, sans erreur. Ni le démarrage ni la
  dictée n'attendent cette requête.

## Diagnostic

Réglages › Diagnostic exporte un JSON local : autorisations, raccourci, bulle, durées et API des 50 dernières
tentatives. Aucun texte dicté, audio, contexte, chemin ni clé. Rien n'est envoyé automatiquement.
