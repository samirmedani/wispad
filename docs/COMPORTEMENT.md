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
- Même insertion qu'une dictée, dans l'app au premier plan. Les touches modificatrices doivent être relâchées
  (0,8 s au plus) ; sinon le texte reste prêt à copier, aucun raccourci parasite n'est envoyé.
- Insertion confirmée, il se termine comme une dictée : la bulle affiche « Collé » (coche verte, sans
  bouton, disparaît seule), le champ est surveillé 30 s pour apprendre les mots corrigés (mêmes règles qu'après
  une dictée, voir « Dictionnaire et apprentissage »), et la dictée non insérée passe à « Inséré »
  avec l'app où elle a été collée. Un nouvel échec ne change jamais le statut d'une dictée déjà livrée.
  Toujours pas de champ : le texte est copié et la bulle affiche le même message qu'après une dictée. Même fin pour
  **Coller** dans la bulle.
- Avalé : la combinaison n'atteint pas l'app. Une fois par enfoncement (la répétition ne recolle pas). Ignoré
  pendant une écoute ; les dictées qui se terminent se collent d'abord.
- fn n'en fait jamais partie : fn enfoncé (dictée en maintien), ⌃⌥V n'est pas le raccourci, et un appui simple sur
  fn ne déclenche toujours rien.
- Réglages › Raccourci › « Coller la dernière dictée » : Modifier, puis la combinaison voulue (Échap ou Annuler
  arrête) ; ↺ remet ⌃⌥V, montré seulement quand la combinaison en est une autre ; l'interrupteur le désactive sans
  oublier la combinaison. Refusées, avec la raison :
  touche seule ou avec ⇧ seulement (elle écrirait), ⌘ avec une seule touche (menus des apps), fn, Échap, le
  raccourci de dictée, les combinaisons connues de macOS et des apps (⌘⇧V, ⌥⌘V, ⌘Espace, captures d'écran…) et
  celles déclarées dans Réglages Système › Clavier › Raccourcis. Le raccourci actuel est suspendu pendant
  l'enregistrement.
- Affiché dans la carte « Raccourcis » de la barre latérale quand il est activé.

## Réactivité

- L'écoute du clavier tourne sur son propre fil : le clavier n'attend jamais l'app. Elle est vérifiée toutes les
  3 s et rétablie si macOS l'a coupée.
- L'audio s'initialise sur une file dédiée, la bulle s'affiche tout de suite ; le moteur arrêté est réutilisé.
- Démarrage du micro surveillé, première dictée après un lancement comprise : si macOS reconfigure l'entrée
  (micro Bluetooth qui change de profil, autre fréquence, micro débranché), le moteur repart aussitôt, dans le même
  enregistrement ; au repos, il est remplacé par un neuf à la dictée suivante. Aucun audio 1,5 s après le
  démarrage : le micro redémarre une fois sur un moteur neuf. Toujours rien 1,5 s plus tard, ou démarrage (comme
  redémarrage) qui ne rend pas la main en 4 s : la dictée est abandonnée, rien n'est envoyé, Wispad revient prêt
  (le raccourci redémarre une dictée) et la bulle affiche « Le micro n'a pas démarré : réessaie ». Rien ne reste
  ouvert : micro, flux de transcription déjà branché et spectre se referment, même un démarrage qui rend la main
  juste après l'abandon. Une erreur du micro (aucun micro, moteur refusé) s'affiche de même dans la bulle.
- Micro qui disparaît en pleine dictée sans autre micro pour prendre le relais (ou moteur qui refuse de repartir) :
  la dictée s'arrête là, comme si on l'avait terminée. Ce qui a déjà été dit est transcrit et collé, le raccourci est
  aussitôt libre et la bulle affiche « Le micro ne répond plus : dictée arrêtée ». Jamais de bulle figée sur un
  spectre immobile.
- Le micro reste fermé au repos ; un appui simple ne le prépare pas.
- La lecture du champ actif (lente dans les apps Electron) ne retarde pas l'enregistrement : l'audio est gardé
  jusqu'à ce que la transcription en direct soit branchée (le champ est attendu 150 ms au plus pour ses mots-clés).
- Chaque dictée ajoute une ligne à `~/Library/Application Support/Wispad/latence.log` (date, mode ; appui →
  bulle, micro, premier audio, flux ; fin → collé ; statut), sans aucun texte, 500 lignes au plus.

## Historique

- Une dictée par ligne, groupées par jour (Aujourd'hui, Hier, puis la date), de la plus récente à la plus ancienne.
- Un texte coupé à quatre lignes montre « Afficher tout » ; le bouton n'apparaît que si la coupure est réelle à la
  largeur de la fenêtre.
- Au survol : détails, copier, retranscrire et écouter (si l'audio est gardé), supprimer.
- La recherche filtre dès que l'on cesse de taper (150 ms) ; l'effacer réaffiche tout aussitôt.
- Le défilement reste fluide avec des milliers de dictées : seules les lignes visibles sont construites, et une
  ligne déjà vue n'est ni reformatée ni remesurée.

## Bulle

- Verre noir (Liquid Glass sur macOS 26+) au-dessus du Dock, sur le bureau comme au-dessus d'une app en plein
  écran, avec le spectre de la voix (graves au centre) à la cadence de l'écran (120 Hz en ProMotion).
- Elle laisse passer les clics, sauf sur ses boutons : ✕ / ■ en mains libres, Copier et Coller d'un texte non
  écrit, Oui / Non d'un mot appris, ✕ d'un message.
- Messages (erreur, « Collé », mot appris, relais, texte prêt à copier) sur une ligne, avec une barre qui se vide
  de droite à gauche avant leur départ. Pointeur sur la bulle, sans clic préalable : une petite ✕ paraît en fondu à
  droite et le décompte (barre comprise) s'arrête ; il reprend où il en était à la sortie. Un message qui paraît
  sous le pointeur attend aussi. La ✕ ferme le message tout de suite, sans prendre le focus ni le premier plan à
  l'app active. La bulle d'enregistrement (spectre, finalisation) n'a ni ✕ ni décompte.
- **Place à l'écran** (Réglages › Bulle et messages) : trois places réglables à main levée sur un schéma quadrillé
  de l'écran, la grille aimantant légèrement les bulles. **Dictée** (spectre et finalisation), **Alertes de
  collage** (texte prêt à copier) et **Messages** (« Collé », mot appris, relais, nouvelle version). Par défaut :
  au-dessus du Dock, au centre. Double-clic sur une bulle du schéma ou « Par défaut » : place d'origine ; « Aperçu à
  l'écran » montre un message 3 s à la place choisie. Entre deux places, la bulle glisse (0,22 s, sans animation si
  le mouvement est réduit). Une place est gardée en fractions de l'écran, et la bulle reste entière à l'écran.
- **Ne jamais couvrir le champ de saisie** (activé par défaut, désactivable) : après chaque collage, Wispad lit où se
  trouve la saisie dans l'app au premier plan. C'est le champ actif s'il mesure au plus 240 points de haut, sinon la
  ligne du curseur ; pour un champ invisible à l'accessibilité (Codex, apps Electron), les 22 % du bas de la fenêtre
  active (90 à 200 points). Les messages qui couvriraient cette zone se placent 12 points au-dessus, sinon en
  dessous ; la bulle de dictée garde sa place. Cette lecture suit l'envoi du texte (au plus 0,3 s, hors du fil
  principal) : ni la bulle ni le collage ne l'attendent. Elle vaut pour cette app pendant 2 minutes.
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
  - section, origine et période du Dictionnaire (Mots, Tous et Toute période par défaut) ;
  - dernière section ouverte dans la barre latérale (Accueil par défaut) : la fenêtre rouvre dessus depuis le
    Dock ou « Ouvrir Wispad » ; un raccourci de section ou un menu de section ouvre toujours la sienne ;
  - « Clés facultatives » dépliées ou non dans Fournisseurs (repliées par défaut).

  Un choix illisible ou inconnu reprend sa valeur par défaut, sans toucher aux autres réglages. Restent
  éphémères : les recherches de l'Historique et du Dictionnaire, une saisie en cours (clé, terme du dictionnaire),
  une dictée dépliée dans l'Historique, le détail ouvert.

## Réglages

Sections, dans l'ordre : Raccourci, Transcription, Correction, Mise en forme, Ton selon l'app, Confidentialité, Apprentissage,
Général, Autorisations, Diagnostic, Aide et retours. Aucun bloc de texte sous une liste : chaque réglage porte, dans
sa rangée, une explication d'une ligne sous son libellé, en langage simple (ni montant, ni chiffre, ni nom de
modèle). Les détails (fournisseurs et modèles réellement utilisés, coût, délais, ce qui est envoyé ou gardé)
s'ouvrent dans un popover avec le bouton ⓘ de la rangée ; ceux de la correction suivent les clés enregistrées.

- **Raccourci** : chaque raccourci (dictée, « Coller la dernière dictée ») est dessiné en touches de clavier Mac
  compactes, toutes de la même hauteur, une par touche à enfoncer, symbole et nom sur une ligne, séparées par un
  petit « + » : « ⌃ control + ⌥ option + V », « 🌐 fn ». Les deux rangées ont la même disposition : libellé et
  explication à gauche ; à droite, sur la même ligne et centrés verticalement, ⓘ, les touches, puis Modifier ;
  pour « Coller la dernière dictée », ↺ et l'interrupteur, à droite comme les autres. Pendant un enregistrement,
  une consigne remplace les touches et Modifier devient Annuler, qui arrête sans rien changer (raccourci de dictée
  compris). Rien ne passe sous le libellé : faute de place, l'explication va à la ligne, puis Modifier devient une
  icône, enfin les touches ne gardent que leur symbole (« ⌃ + ⌥ + V »). Le popover ⓘ ajoute un schéma du clavier
  de MacBook où ces touches sont en couleur, à leur place ; il suit le raccourci choisi. Lettres et chiffres
  portent l'inscription de la disposition active (A en haut à gauche en AZERTY, Q en QWERTY), ici comme dans les
  messages.
- **Confidentialité** : « Ce qui est envoyé » (audio et, si disponibles, app active, sélection et court extrait
  autour du curseur ; historique et audio restent sur ce Mac), « Comprendre le sujet grâce à la fenêtre active »
  (inactif sans la correction), conservation, durée et plafond de l'audio.
- **Correction** : « Corriger le texte avant insertion », « Structurer les listes et paragraphes », « Réécrire la
  sélection sur consigne » (inactif sans la correction). Le ton se règle dans la section « Ton selon l'app », inactive
  sans la correction.
- **Mise en forme** (inactive sans la correction) : format des dates et des heures écrites par la correction (voir
  « Dates et heures » plus bas), conservé aux mises à jour, lu champ par champ.
  - « Dates » : JJ/MM/AAAA (par défaut), MM/JJ/AAAA ou AAAA-MM-JJ (ISO, qui impose tirets, quatre chiffres et zéros) ;
    puis, hors ISO et hors toutes lettres : séparateur (/ par défaut, ., -, espace), année sur 4 (par défaut) ou
    2 chiffres, « Zéro initial » (03/11, par défaut, ou 3/11).
  - « Garder les dates en toutes lettres » (désactivé par défaut) : mois en lettres, jour et année en chiffres
    (« 24 octobre 2026 », « 1er mai » ; en anglais « 24 October 2026 », ou « October 24, 2026 » avec MM/JJ/AAAA).
  - « Heures » : « Selon la langue » (par défaut : 24 h en français, 12 h en anglais), « 24 h » ou « 12 h (AM/PM) ».
    « Écriture sur 24 h », cachée en 12 h : « 14h30 » (par défaut, d'un seul bloc), « 14 h 30 » (typographie
    française stricte) ou « 14:30 » ; l'anglais écrit toujours « 14:30 » sur 24 h et « 2:30 PM » sur 12 h.
  - « Aperçu » : une date, une date sans année et une heure rendues par le format choisi, mises à jour à chaque
    changement ; en langue automatique, une ligne par langue si elles diffèrent.

## Premier lancement guidé

Au premier lancement (aucun réglage enregistré), la fenêtre affiche une configuration en sept étapes, avec une
barre de progression : Bienvenue, Autorisations, Micro, Fournisseur, Touche, Essai, Fin. Chaque étape est à faire,
en cours, réussie (✓) ou en problème (✗, avec la marche à suivre) ; « Continuer » n'est actif qu'une fois l'étape
réussie. « Plus tard » est proposé seulement pour le micro, la touche et l'essai.

- **Bienvenue** : la bulle d'écoute telle qu'elle apparaît pendant une dictée (pilule de verre noir, 11 barres
  rouges, graves au centre), agrandie, animée à la cadence de l'écran par une voix simulée en boucle : syllabes
  avec attaque et retombée, courtes pauses entre les mots, respiration en fin de phrase. Aucun micro ni réseau.
  Avec « Réduire les animations », image fixe.
- **Autorisations**, toutes sur un écran : micro, accessibilité (coller le texte), surveillance des entrées (touche
  fn). « Autoriser » déclenche la demande de macOS ; ensuite, ou après un refus, le bouton ouvre le bon panneau de
  Réglages Système et le chemin exact est affiché. L'état est relu toutes les 0,5 s. Surveillance des entrées
  accordée mais écoute du clavier impossible après 3 s : macOS attend une relance, « Relancer Wispad » rouvre l'app
  à la même étape (si macOS refuse de la fermer, elle s'arrête d'elle-même après le rangement habituel).
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
- **Touche** : maintien et double appui expliqués, avec les touches du raccourci dessinées et le schéma du clavier
  de MacBook où elles sont en couleur (elles passent au vert dès qu'un appui est reçu) ; pendant cette étape, chaque appui est seulement constaté
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
Fenêtre fermée pendant la configuration : le test du micro s'arrête, la touche dicte de nouveau normalement et
l'état n'est plus relu jusqu'à la réouverture.

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
  correction du flux, sans second appel, si elle est déjà prête. Sinon, correction complète du fichier immédiate,
  sans attendre 0,3 s une correction obsolète ;
- fichier en échec, sans aucun mot ou trop lent (1,2 s + 0,06 s par seconde d'audio, 4 s au plus) : le flux est
  gardé. Il l'est aussi quand le réglage est coupé et qu'une fin de flux peu fiable rappelle un fichier vide.

Si le fichier a déjà répondu quand le flux se termine, le choix est fait immédiatement : seule la transcription
retenue part à la correction. Une correction déjà préparée sur ce même texte reste réutilisable. Sinon, la
correction du flux continue à se préparer en parallèle du fichier. La vérification audio n'est pas sautée,
même pour une dictée de quelques mots.

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
- Nombres écrits en chiffres quand ils comptent vraiment quelque chose ; élisions orales écrites en entier
  (« j'sais » → « je sais ») ; tournures familières gardées (« t'as », « y a »).
- **Dates et heures** : une date sans ambiguïté (jour et mois, date complète) ou l'heure d'un rendez-vous s'écrit au
  format de Réglages › Mise en forme ; la consigne en reçoit des exemples rendus dans ce format. « le vingt-quatre
  octobre deux mille vingt-six » → « 24/10/2026 », « le 3 du 11 » → « 03/11 », « à quatorze heures trente » →
  « à 14h30 », « à deux heures de l'après-midi » → « à 14h » (réglages par défaut). Jamais d'année inventée : « le 3 novembre » donne
  « 03/11 » (ou « 3 novembre » en toutes lettres). « mardi » seul reste « mardi » ; une durée reste une durée
  (« deux heures de route » → « 2 heures de route »).
- **Nombres mal entendus** : avant d'écrire un nombre en chiffres, la correction vérifie qu'il compte vraiment
  quelque chose dans la phrase et la conversation visible. Si un homophone courant donne un sens plus naturel
  (« deux » / « de », « deux mois » / « de moi », « cent » / « sans » / « s'en », « six » / « si », « sept » /
  « cette », « vingt » / « vin » / « vint », « mille » / « mil », « un » / « hein » ; en anglais « two » / « to »,
  « four » / « for »…), elle le corrige comme un mot mal entendu : « ils veulent quoi, deux mois ? » → « Ils veulent
  quoi de moi ? ». « Le chantier dure deux mois » → « Le chantier dure 2 mois. » Dans le doute, le mot reste en
  lettres, jamais en chiffres.
- **Mots mal entendus** : quand un mot ou un groupe de mots rend la phrase illogique et qu'un mot qui se prononce
  pareil ou presque lui donne un sens évident (vu la phrase, le contexte, les dictées précédentes et l'autre écoute),
  la correction écrit ce mot à sa place : « hier j'écris le train » → « Hier, j'ai pris le train. », « il c'est
  trompé » → « Il s'est trompé. », « un vers d'eau » → « un verre d'eau ». Une phrase qui a déjà un sens n'est pas réécrite, aucune idée
  n'est ajoutée et un mot plausible reste (« J'écris un mail » ne change pas). Un nombre devant une unité garde sa
  règle : il faut que le contexte le confirme.
- **Tics et répétitions** : répétitions inutiles et tics répétés retirés (« par exemple, par exemple », « genre »,
  « en fait » ou « tu vois » répétés, « nan nan nan », mot doublé). Une occurrence reste quand elle porte le sens :
  « par exemple » qui introduit un vrai exemple, « ce genre de film », un « nan » qui répond. Rien d'autre n'est
  retiré à ce titre.
- **Citations** : paroles rapportées, mot donné en exemple, texte affiché, « si tu dis… », « tu mets… »,
  « genre… » : la citation va entre guillemets français (anglais : “ ”), les mots qui l'introduisent restent dehors
  (« si tu dis bonjour il répond » → Si tu dis « bonjour », il répond.). Un mot incompréhensible n'est jamais mis
  entre guillemets pour être gardé tel quel : il est corrigé comme un mot mal entendu, ou laissé sans guillemets.
  Seuls des guillemets qui enveloppent toute la réponse sont retirés ; « ces » ou « ses » garde les siens.
- **Lettres épelées** : regroupées en un seul mot épelé, en capitales séparées par des tirets (« C-E-S »), ou, si
  la phrase parle de ce mot, le mot entre guillemets (« ces »). Un mot de la phrase qui sonne comme une lettre est
  rattaché selon le sens (« c'est » et C, « t'es » et T, « elle » et L), une lettre répétée par erreur disparaît.
  Jamais de lettre isolée sans sens ; une lettre qui en a un reste (« vitamine C », « plan B »).
- Banc réseau de ces règles, transcriptions brutes inventées passées directement à la correction (sans audio) :
  `BENCH_ONLY=h,r,g,l,e,d,n scripts/franglais-bench.sh <nom>` (mots mal entendus, tics, citations, lettres épelées,
  anglais, dates et heures, nombres mal entendus).
- La correction ne répond jamais au contenu dicté et ne recopie jamais le contexte.
- **Correction préparée pendant l'écoute** : à chaque pause de la parole (segment final du flux, puis 0,25 s sans
  nouveau mot), le texte entendu part déjà à la correction. Si l'on arrête sans rien ajouter (même texte à la
  ponctuation, la casse ou l'écriture des nombres près), cette correction sert telle quelle et le texte se colle sans
  attendre un nouvel appel. Si la parole reprend, elle est comptée (coût réel)
  et la suivante la remplace ; quatre au plus par dictée. Jamais si la correction est coupée.
- **Correction lancée à l'arrêt** : dès l'arrêt, ce que le flux a déjà affiché part à la correction, sans attendre
  son texte final (0,3 à 0,5 s sur les dictées courtes, mesuré le 13 octobre 2026). Si le texte final dit la même
  chose, cette correction sert ; sinon elle est comptée et une correction du texte final la remplace. Rien de plus
  n'est lancé si une correction préparée à une pause porte déjà sur ce texte.
- Expressions mal entendues malgré les mots-clés, réécrites avant et après la correction : « services functions »
  → « serverless functions », « day inference » → « AI inference ».

## Contexte envoyé à la correction

Réglage « Comprendre le sujet grâce à la fenêtre active », proposé au premier lancement, désactivé par défaut
pour une nouvelle installation.

- Fin de la conversation visible dans la fenêtre où l'on dicte (2 000 caractères au plus, lue pendant l'écoute
  en 300 ms au plus) et dernières dictées livrées dans la même app (cinq, trente minutes, 1 500 caractères).
- Texte autour du curseur et sélection, pour l'orthographe.
- Rien de ce contexte n'est enregistré ni journalisé ; il n'ajoute jamais un mot qui n'a pas été dit.
- Jamais Wispad lui-même : quand sa fenêtre est au premier plan (dictionnaire, recherche…), même si elle y passe
  pendant la lecture d'une autre app, ni le contexte, ni le champ, ni la zone de saisie, ni le suivi des corrections
  ne sont lus par l'accessibilité. Ces lectures se feraient dans son propre processus, hors du fil principal, et
  arrêteraient l'app. Le texte s'y colle sans confirmation, comme dans un champ illisible.

## Garde-fou de fidélité

Après la correction, `FidelityGuard` rejette ou répare :

- une réponse nettement plus longue que la dictée, ou qui recopie huit mots de suite du contexte. Seuls les mots
  comptent : les guillemets d'une citation, un deux-points ou un tiret isolés ne rallongent rien et ne cachent pas
  une copie ;
- un mot traduit (« outils » → « tools ») : le mot entendu est remis ;
- une marque, un nom ou une référence absents de ce qui a été dit et qui ne lui ressemblent pas à l'oreille, même
  mis entre guillemets ;
- une référence lettres puis chiffres (DDR4, i9) dont les chiffres n'ont pas été prononcés ;
- sur une dictée de trois mots au plus, tout mot qui ne ressemble au mot entendu ni à l'écrit ni à l'oreille, ou qui
  s'ajoute (hors « ne » rétabli) : la transcription est collée (« Était sérieux » ne devient pas « Sois sérieux » ;
  « cloud code » → « Claude Code » et « un sot d'eau » → « Un seau d'eau. » restent).

À l'oreille : prononciation française approchée (`PhoneticKey`), à une différence près pour cinq sons ; une lettre
isolée se lit par son nom (« C » comme « c'est »). Des lettres épelées regroupées (« aime E elle » → « M-E-L ») ne
sont ni une traduction ni une invention quand une lettre isolée a été entendue et que les noms des lettres sonnent
comme ce qui a été dit ; un autre mot épelé (« B-O-B ») ou un sigle sans lettre entendue reste refusé.

Les vraies corrections d'écoute restent (« versel » → Vercel, 9950X3D, « envoie le » → « Envoie-le », « j'écris »
→ « j'ai pris », « c'est E S » → « C-E-S », « deux mois » → « de moi », « cent rien dire » → « sans rien dire »).
« sept » se dit comme « cette », « vingt » comme « vin », « mille » comme « mil ».

Dates et heures : la même date ou la même heure, autrement écrite, n'est ni une traduction ni une invention
(« quatorze heures trente » → « 14h30 », « at 2 in the afternoon » → « at 2 PM », « the third of the eleventh » →
« November 3 ») : ses nombres viennent de ce qui a été dit, mois et après-midi compris. Une année que personne n'a
dite (en chiffres, en lettres, « twenty twenty-six » ou sur deux chiffres) est retirée de la date : « le trois
novembre » → « 03/11/2026 » devient « 03/11 ».

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

### Dates et heures

Quand le service de correction répond, le texte retenu (la correction, ou la transcription que le garde-fou a
gardée) prend le format de Réglages › Mise en forme sans dépendre du modèle, avant la mise en forme des listes.
Repasser sur un texte déjà mis en forme ne change plus rien. Sans réponse ou sans correction, le texte reste tel quel.

- Dates : complètes en chiffres (« 3/11/2026 », « 3.11.2026 », « 2026-11-03 » ; « 24/10/26 » → 2026,
  « 12/05/85 » → 1985), lues dans l'ordre réglé, ou dans l'autre s'il est seul possible (« 24/10/2026 » en
  MM/JJ/AAAA → « 10/24/2026 ») ; au mois en lettres (« 3 novembre », « 1er novembre 2026 », « du 3 au 5 novembre »,
  « October 24, 2026 », « the 24th of October ») ; sans année après « le », « du », « au » ou un jour de la semaine
  (« le 3/11 », « le 3 du 11 »). En toutes lettres, l'inverse : « le 24/10/2026 » → « le 24 octobre 2026 »,
  « le 1/11 » → « le 1er novembre ». En anglais, deux lectures qui se chevauchent : la première du texte l'emporte
  (« on 3 May 8 people came » → « on 03/05 8 people came ») ; « the » n'appartient à la date que devant un ordinal ou
  « of » (« the 24th of October » → « 24/10 », mais « the 31 May deadline » → « the 31/05 deadline »).
- Heures : suivies de AM/PM, « du matin », « de l'après-midi » ou « du soir », qui disparaissent (« 2 h de
  l'après-midi » → « 14 h ») ; précédées de « à », « vers », « dès », « jusqu'à », « à partir de », « il est », d'un
  jour de la semaine ou de « demain » (anglais : at, around, by, until, before, after, from, between) ; ou reliées à
  une telle heure (« de 14 h à 16 h », « entre 9 h et 11 h », « à 8 h, 12 h et 20 h »). En 12 h, une heure de 1 à 11 sans matin ni soir reste telle quelle (« à 9 h »), sauf
  reliée à une heure sûre (« de 9 h à 17 h » → « de 9 AM à 5 PM »).
- Jamais touchés : un jour, un mois ou une année seuls ; une durée ou une distance (« 2 heures de route », « 1h30 de
  trajet », « à 2 h de Paris », « de 2 à 3 heures », « jusqu'à 3 heures » ; « jusqu'à 18 h » est une heure) ; une
  note ou une fraction (« 8/10 », « 3/4 ») ; une version (« 1.12.20 »), une adresse IP, un numéro de téléphone, un
  score, « 16:9 », « Jean 3:16 » ; une date impossible ; deux jours après un mois anglais (« May 14/15 »,
  « May 4-5 ») ; une adresse web, un e-mail, du code.

### Nombres, montants et unités

Réglages › Mise en forme : **Montants et unités** (symboles, par défaut, ou en toutes lettres) et **Milliers**
(selon la langue, par défaut ; espace ; aucun). La consigne reçoit des exemples rendus dans ce format, puis
`NumberWriter` l'impose sans le modèle, après le garde-fou de fidélité, au texte retenu :

- Montant, pourcentage ou mesure suivi de son unité, dite ou écrite : « 25 euros », « 25€ » → « 25 € » ; « 3,5 € »,
  « 3.50 € » → « 3,50 € » ; « 15% », « 15 pour cent » → « 15 % » ; « 5 kilomètres » → « 5 km » ; « 12 kilomètres par
  heure », « 1,5 kilomètre par heure » → « 12 km/h », « 1,5 km/h » ; « 120 mètres carrés » → « 120 m² » ;
  « 20 degrés Celsius » → « 20 °C » ; « 15 kilowatt-hours » (anglais) → « 15 kWh » ;
  « 16 gigaoctets » → « 16 Go », mais « 16 gigas », dit ainsi, reste tel quel. En français, espace insécable
  avant le symbole et espace fine insécable entre les milliers (« 1 500 € ») ; en anglais, « $25 », « €3.50 », « 15% », « $1,500 ». Un prix garde ses centimes sur deux chiffres.
- En toutes lettres : « 25 euros », « 1 euro », « 1,50 euro », « 5 kilomètres » (pluriel à partir de 2 en
  français) ; « % » reste un symbole, et un symbole d'une seule lettre (« 5 m », « 250 g ») n'est pas récrit.
- Les unités informatiques (Go, Mo, To, GB, MB, TB, GHz, MHz) ne regroupent pas les milliers : « 6000 MHz ».
- Téléphones français par paires : « 0612345678 », « 06.12.34.56.78 » → « 06 12 34 56 78 » ;
  « +33612345678 », « +33 (0)6 12 34 56 78 » → « +33 6 12 34 56 78 ». Pas plus long, ni collé à une adresse ou à
  des lettres.
- Jamais touchés : un nombre sans unité reconnue (années, codes postaux, références de matériel, numéros de version,
  « 12 500 personnes »), les durées (« 5 min », « 300 ms », « 2 heures de route »), une élision après un nombre
  (« les 3 l'ont vu »), « 3,50 € » écrit à la française dans une dictée anglaise, les codes EUR, USD et GBP. Un
  symbole qui suit déjà un montant ne passe pas au nombre suivant (« payé 20 € 3 fois », « 3 € 50 ») et un nombre
  précédé de sa devise n'est jamais une mesure (« $5m », cinq millions).
- « Et demi » reste en lettres après un nom, accordé : la transcription vocale écrit parfois « 2 mois et 1/2 », qui
  devient « 2 mois et demi » ; « 1 heure et 1/2 » → « 1 heure et demie ». Une fraction seule (« 1/2 litre ») ne change
  pas et n'est jamais lue comme une quantité.
- Mots du fichier reportés dans la correction du flux (`CorrectionPatch`) : ils reprennent aussi le format des dates,
  des heures et des nombres (« 80 m² » ne redevient pas « 80 mètres carrés »).
- Le garde-fou reconnaît les symboles d'unité (« °C », « kWh », « km/h ») : il ne les remplace pas par les mots
  entendus.

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
- Après une dictée insérée (ou collée par « Coller la dernière dictée »), le champ est relu toutes les 250 ms
  pendant 30 s, hors du fil principal. Jamais avec « Apprendre de mes corrections » coupé, après une sélection
  réécrite sur consigne, ni pour le champ d'essai du premier lancement. Un mot mal
  entendu corrigé à la main (« Sidance » → « Seedance ») est jugé : marque, nom, sigle ou jargon seulement. Avec
  une clé TypeSafe, Jev le note d'abord et tranche les cas nets ; le modèle de correction décide des autres (et
  de tous sans clé TypeSafe). Sans réponse du modèle de correction, la note de Jev suffit.
- Les termes retenus sont ajoutés, puis une bulle « Ajout au dictionnaire » les présente ensemble (jusqu'à trois,
  8 s, sans prendre le focus). « Voir » ouvre leur section dans le dictionnaire ; « Annuler l'ajout » retire le
  groupe affiché et mémorise le refus. Sans réponse ou avec ✕, les termes restent. Le décompte se suspend au
  survol et une nouvelle dictée passe toujours avant la bulle, qui revient ensuite.
- Les jugements sont sérialisés : un terme déjà ajouté par le jugement précédent n'est pas rejugé. Les refus
  sont relus après l'attente et avant l'ajout. Une réponse tardive n'ajoute rien si l'apprentissage a été coupé
  entre-temps. Un résultat ne peut ajouter que les candidats effectivement soumis, sans doublons.
- Un nom à graphie distinctive ressemblant à une simple flexion (« terraforme » → « Terraform ») est transmis
  au juge, pas ajouté aveuglément. Les accords ordinaires restent exclus par le filtre local.
- Seuls la phrase dictée et le mot corrigé sont envoyés (à Jev et au modèle de correction) ; le journal ne contient ni mot ni texte.

### Origine des mots

Chaque mot garde, sur ce Mac, qui l'a ajouté :

- **Toi** : mot ajouté à la main dans l'écran Dictionnaire.
- **Appris automatiquement** : mot corrigé après une dictée et retenu par un juge. Jev (TypeSafe) quand sa note
  suffit (cas net, ou modèle de correction sans réponse) ; sinon le modèle de correction qui a répondu (sans clé
  TypeSafe ou sans réponse de Jev, ou mot douteux pour Jev). Le fournisseur et le modèle notés sont ceux de l'appel
  qui a tranché : la route de correction qui a répondu (DeepSeek `deepseek-flash`, OpenAI `gpt-5.4-mini`, xAI
  `grok-4.7`…), ou pour Jev le modèle annoncé par sa réponse. Après un changement de clé ou de fournisseur, les mots
  suivants portent le nouveau modèle, les anciens gardent le leur.
- **« Voir » dans la bulle** ne fait pas du mot un mot « Toi » : le juge l'avait déjà ajouté.
  Le terme reste comme avec le silence ou ✕ ; « Annuler l'ajout » le retire. La confirmation est notée et
  l'info-bulle dit « Gardé par toi » ; le mot garde son juge. « Toi » désigne seulement un mot ajouté à la main.
- **Avant le suivi** : mot ajouté par une version précédente. L'historique ne relie aucun appel de jugement à un
  mot ni ne garde le verdict de chaque mot : l'origine n'est pas devinée.

Le dictionnaire affiche par défaut les entrées les plus récentes en haut, dans tous les filtres et dans les deux
sections. Les en-têtes **Mot / Expression**, **Origine** et **Ajouté le** trient la liste ; un second clic inverse
le sens, indiqué par une flèche. Le choix reste mémorisé après relance. Le tri par origine groupe Par toi,
Automatique puis Avant le suivi (ou l'inverse), avec les plus récents en tête de chaque groupe. Il ne change ni
les données conservées ni l'ordre des termes transmis aux fournisseurs.

Écran Dictionnaire : deux sections mémorisées, Mots et Expressions et phrases. La classification suit le texte :
un seul élément sans espace reste un mot, plusieurs éléments (espaces ou retours à la ligne) forment une
expression. Les termes existants sont répartis sans être modifiés. Les noms composés peuvent donc être dans
Expressions et phrases ; ce n'est pas une décision du modèle. Aucune limite de longueur n'est ajoutée.

Les mots utilisent une table compacte Mot / Origine / Ajouté le. Les expressions ont toute la largeur, avec
retour à la ligne et métadonnées dessous. Leur saisie accepte plusieurs lignes. Ajouter un terme ouvre sa section
et remet les filtres à Tous / Toute période pour qu'il reste visible. La recherche est temporaire ; origine et
période sont mémorisées. Les filtres se croisent, avec un compteur de résultats et un bouton de réinitialisation.

Badges : bleu « Par toi », violet « Automatique », gris « Avant le suivi ». Pour un terme appris, le juge
(« Jev », « DeepSeek », « OpenAI », « xAI »…) reste visible ; l'info-bulle précise le fournisseur, le modèle et
les dates. La corbeille retire une entrée. L'apprentissage automatique reste ciblé sur les corrections de noms,
marques et jargon ; il ne mémorise pas des paragraphes entiers.

Le banc synthétique `scripts/learning-bench.sh` vérifie l'extraction et mesure sa latence. `--live` demande une
clé dédiée `WISPAD_TEST_TYPESAFE_API_KEY` (et éventuellement `WISPAD_TEST_DEEPSEEK_API_KEY`) et mesure les
vrais verdicts, faux positifs, faux négatifs, erreurs et latences. Sans ces clés, aucun benchmark réseau n'est
fait et les résultats locaux ne constituent pas une mesure de la qualité de Jev.

## Relais en cas de panne

- Voix : si xAI ne répond pas, le même enregistrement part chez OpenAI (et inversement) s'il a une clé ; après deux
  échecs, la dictée démarre directement chez l'autre fournisseur.
- Correction : après deux échecs, DeepSeek passe après le relais. Un service mis de côté est contrôlé chaque
  minute et repris dès qu'il répond, au plus tard après 30 minutes.
- Le spectre passe au vert quand un relais travaille ; la première bascule d'une panne est annoncée.

## Reprise après erreur

- Erreur réseau, de clé ou de quota : l'audio reste dans l'historique ; **Retranscrire** puis **Copier**.
- Texte qui n'a pas pu être écrit : jamais en silence. La bulle le dit dans une carte avec un titre de 14 points,
  une explication de 12 points et des boutons de 30 points sur une ligne séparée, avec **Copier** en évidence et
  **Coller** : « Pas de champ où écrire : le texte est prêt » (focus sur une liste, un bouton, un menu, ou le bureau
  et les fenêtres du Finder, avant l'envoi), « Le texte n'est pas arrivé dans le champ » (champ lisible resté
  identique 1 s après ⌘V), « Collage impossible : le texte est prêt » (accessibilité refusée, app cible fermée ou
  qui a perdu le premier plan, presse-papiers non modifiable, ⌘V non envoyé), « Champ sécurisé : le texte est
  prêt ». Le texte est déjà copié, sauf pour un champ sécurisé. 12 s, avec une barre qui se vide (en pause au
  survol) ; ✕ au survol ou Échap la ferment. Elle ne prend jamais le focus : **Copier** remet le texte au
  presse-papiers et confirme « Copié » (1,5 s), **Coller** le colle dans le champ de l'app active (même collage que
  « Coller la dernière dictée »). Le collage garde tous les formats du presse-papiers précédent et refuse les champs
  sécurisés.
- Champ illisible (Codex, apps Electron, éditeurs dessinés) ou remplacé par un autre pendant la relecture : rien ne
  prouve un échec. Le statut reste « Collage envoyé », sans carte ni copie : la bulle ne revient pas à chaque dictée.
  Si le texte manque, « Coller la dernière dictée » et l'historique le gardent. Aucun apprentissage sur une
  insertion non confirmée ; « Coller la dernière dictée » dit « Collé » dans les deux cas.
- Insertion par ⌘V comme au clavier, dans toutes les apps : ⌘ enfoncée (changement de modificateur), V, puis ⌘
  relâchée, envoyés au système une fois l'app cible vérifiée au premier plan et les modificateurs relâchés. Le
  13 octobre 2026, l'écriture par `AXSelectedText` dans Chrome et un ⌘V adressé au seul processus cible laissaient
  le champ vide : ces deux voies sont retirées. Tous les chemins d'insertion partagent une file.
- Une app qui a perdu le premier plan n'est pas réactivée de force : la bulle propose de récupérer le texte.
- Lectures d'accessibilité bornées au collage : champ actif 0,3 s avant ⌘V, confirmation 1 s après. Une app qui
  construit encore son arbre (Chrome à la première dictée) ne retarde ni le texte ni la dictée suivante.
  Le focus est relu pendant la confirmation, y compris si le composant web a recréé son champ. La valeur attendue
  après remplacement de la sélection est comparée au texte observé, en tolérant les transformations typographiques
  des éditeurs riches. Remplacer une sélection par le même texte demande aussi que le curseur se soit déplacé à sa
  fin. À défaut de sélection exploitable, le début du texte doit apparaître une fois de plus dans le même champ.
  Les lectures initiales réutilisent la valeur et la sélection déjà obtenues, sans les redemander plusieurs fois. Un collage non confirmé laisse sa cause dans le journal `insertion`, sans texte.
- Le spectre de traitement disparaît dès l'envoi de ⌘V. La confirmation continue sans bloquer l'affichage ; seul un
  échec avéré fait paraître la carte **Copier / Coller**. Collage confirmé : le presse-papiers précédent revient
  aussitôt. Sinon, la dictée y reste au moins 1,5 s après ⌘V, car une app occupée (page web lourde, Electron) peut
  le lire tard ; le statut, lui, n'attend pas. Le presse-papiers reste réservé jusqu'à sa restauration : les dictées
  rapprochées ne se remplacent pas. Une nouvelle écoute garde sa propre bulle. Échap après l'envoi ne transforme
  pas le texte déjà collé en dictée annulée.
- Les traces distinguent l'envoi de ⌘V après relâchement (`pasteSentAfterReleaseMs`) et la confirmation
  (`confirmationMs`). Les anciennes durées restent disponibles ; ces deux mesures sont absentes sur les anciennes traces.
- Les apps Electron ouvrent leur arbre d'accessibilité avec AXManualAccessibility ; les navigateurs Chromium
  (Chrome, Brave, Edge, Arc, Vivaldi, Opera) l'ignorent et reçoivent aussi AXEnhancedUserInterface, comme pour un
  lecteur d'écran : le champ d'une page devient lisible (confirmation du collage, contexte, apprentissage).
- Les audios expirés sont purgés chaque minute et au lancement.

## Données inattendues

Ce qui vient de l'extérieur (fournisseurs, base locale, app où l'on dicte, coffre de secrets) n'arrête jamais
Wispad ; les cas ordinaires gardent exactement leur résultat.

- Nombre dit démesuré (« cent » répété, dit ou mal transcrit) : lu par morceaux qui tiennent dans un entier, et la
  dictée se termine normalement.
- Compteurs de jetons démesurés annoncés par un fournisseur : comptés et affichés plafonnés dans Consommation.
- Durée ou nombre de mots abîmés dans la base locale : affichés bornés ; une durée illisible compte pour 0.
- Sélection annoncée par l'app où l'on dicte : illisible, l'extrait autour du curseur part du début du champ, comme
  sans sélection ; démesurée, il s'arrête à la fin du champ.
- Commande du coffre de secrets qui se termine sans lire la clé : « Impossible d'enregistrer la clé dans ton coffre
  de secrets. », et Wispad continue.
- Identifiant d'équipe xAI qui ne forme pas une adresse : « Facturation » ouvre la console xAI.

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
- Une dictée sans clé en mémoire relit les clés, ou rejoint la relecture déjà en cours (lancement, appui précédent),
  10 s au plus : un coffre qui ne répond plus est dit injoignable, sans ouvrir le micro, et le raccourci reste libre.
  La relecture continue seule ; l'appui suivant la rejoint au lieu d'en lancer une autre.
- Chaque clé de voix ou de correction (xAI, OpenAI, DeepSeek) est vérifiée chez le fournisseur avant d'être
  enregistrée ; les clés de gestion xAI et TypeSafe sont enregistrées sans vérification.

## Mises à jour et réinstallation

- Une version absente des métadonnées s'affiche « — » ; aucune mise à jour automatique n'est proposée tant que la
  version installée ne peut pas être comparée. Le signalement de bug garde le commit disponible sans inventer de version.

- Une mise à jour ou une réinstallation garde fournisseurs, réglages, clés API, historique et dictionnaire : même
  identifiant (`com.yatofix.wispad`), même dossier (`Application Support/Wispad`), mêmes préférences.
  `scripts/install.sh`, comme la mise à jour en un clic (voir « Version et mises à jour »), ne remplace que l'app.
- La base locale s'enrichit sans rien perdre : les mots du dictionnaire d'une version précédente restent tels quels
  (mot, date d'ajout) avec l'origine « Avant le suivi ». Revenir à une version précédente garde aussi les mots ;
  ceux qu'elle ajoute sont ensuite « Avant le suivi ».
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

## Version et mises à jour

- Bas de la barre latérale, au-dessus des raccourcis : un petit bandeau jaune « Une étoile sur GitHub »
  (« Star on GitHub » en anglais), sur une seule ligne et sans troncature à la largeur fixe de la barre, entièrement
  cliquable. Un clic ouvre la page du dépôt dans le navigateur, affiche « Merci ! » 1,6 s, puis le bandeau
  disparaît pour de bon (réglage `githubStarClicked`, enregistré dès le clic). Wispad ne peut pas savoir si
  l'étoile a été donnée : le clic suffit. Dessous, toujours visibles : la version, puis l'état de la mise à jour.
- **Release ou build de développement** : une release est l'app du `Wispad.dmg` publié sur GitHub ; seul
  `scripts/release.sh` ajoute à son Info.plist la clé `WispadRelease` (vraie), avant de la signer. Sans cette clé,
  c'est un build de développement, compilé depuis les sources (Xcode, `scripts/build.sh`, `scripts/install.sh`). Une
  clé posée par le script de release plutôt que l'absence de signature Developer ID : explicite et testable, couverte
  par la signature de l'app, et un contributeur qui signe son build avec son propre certificat Developer ID reste un
  build de développement.
- **Release** : la version seule (« Wispad 0.1.1 »), puis « À jour », ou « Wispad 0.1.2 est disponible » (un clic
  ouvre la fenêtre de mise à jour) et le bouton « Mettre à jour », qui ouvre aussi cette fenêtre : l'installation
  ne démarre qu'après lecture des notes, avec son bouton « Mettre à jour ». Le tag de la dernière release
  (« v0.1.2 ») et la version de l'app (`CFBundleShortVersionString`) se comparent en semver : X.Y.Z, une pré-version
  avant la version
  finale. Une app plus récente que la dernière release (release retirée) reste « À jour ».
- **Build de développement** : la version et le commit court gravé à la compilation (« Wispad 0.1.0 · abc1234 »),
  puis « À jour » ou « N commits de retard » (« 1 commit de retard ») sur la branche `main` du dépôt public, comme
  avant les releases. Un clic sur le retard ouvre la page des commits. Aucune release proposée ni demandée.
- **Vérification**, seul contact hors des fournisseurs : pour une release
  `GET https://api.github.com/repos/samirmedani/wispad/releases/latest`, pour un build de développement
  `GET https://api.github.com/repos/samirmedani/wispad/compare/<commit>...main` (le retard est le champ `ahead_by`).
  API publique, sans clé ni cookie, avec l'en-tête User-Agent demandé par GitHub ; 5 s après le lancement, puis
  toutes les 6 heures, 8 s au plus. Rien d'autre n'est envoyé (pour un build de développement, le commit de la
  version, dans l'adresse). Ni le démarrage ni la dictée n'attendent cette requête.
- **Échecs silencieux**, sans message : hors ligne, délai dépassé ou GitHub en panne (5xx) → nouvel essai dans
  30 minutes ; limite de l'API (403, 429) → nouvel essai à l'heure annoncée par GitHub (`Retry-After` ou
  `X-RateLimit-Reset`), entre 5 minutes et 6 heures, une heure sans indication ; aucune release (404), tag mal formé
  (autre chose que vX.Y.Z), brouillon, pré-version ou réponse illisible → rien de nouveau. Ce qui était affiché reste ;
  sans aucune réponse lisible, seule la version s'affiche. Build de développement : dépôt privé (404), commit inconnu
  (compilation locale non publiée) ou commit non gravé (git absent à la compilation) → seule la version.
- **Rappel discret** d'une nouvelle version, une seule fois par version, dans la bulle : « Wispad 0.1.2 est
  disponible », avec « Voir » (la fenêtre s'ouvre sur les notes de version) et « Ne plus me rappeler » ; ✕ au survol,
  départ seul après 10 s, décompte en pause au survol. Il attend que la bulle se libère après une dictée (ou après un
  autre message) : on est alors devant le Mac et on la regarde. Jamais pendant une dictée ni pendant la configuration
  guidée ; la bulle ne prend ni le focus ni le premier plan. Coupé par une dictée qui commence, il reparaît à la fin
  de celle-ci. Une version rappelée (réglage `updateRemindedVersion`) ne l'est plus jamais, même après une relance ;
  une version plus récente l'est à son tour. La barre latérale la propose toujours.
- **Fenêtre de mise à jour** : la version disponible et celle installée, les notes de version (le corps de la
  release en markdown simple : titres, puces, listes numérotées, paragraphes, blocs de code ; gras, italique, liens
  et `code` dans la ligne ; texte sélectionnable), « Voir sur GitHub », « Plus tard » et « Mettre à jour ». Pendant
  l'installation : l'étape et sa progression, et « Annuler » tant que rien n'est remplacé. En cas d'échec : la
  raison, « Ouvrir la page de la release » et « Réessayer ».
- **Installation en un clic** (« Mettre à jour » de la fenêtre de mise à jour, qui reste ouverte pour suivre
  l'avancement ; la barre latérale le résume) :
  1. téléchargement de `Wispad.dmg` (asset de la release, seulement depuis
     `https://github.com/samirmedani/wispad/releases/download/`), avec sa progression ; taille et empreinte SHA-256
     comparées à celles qu'annonce GitHub ;
  2. montage en lecture seule, invisible dans le Finder (`hdiutil attach -nobrowse`, sinon `diskutil image attach`,
     son remplaçant, s'il échoue ou disparaît) ;
  3. vérification de `Wispad.app` dans le disque : version plus récente que celle qui tourne (jamais de retour en
     arrière) ; signature intacte (toutes architectures, code imbriqué, validation stricte), Developer ID d'Apple,
     même identifiant (`com.yatofix.wispad`) et même équipe (Team ID) que l'app qui tourne ;
  4. copie cachée à côté de l'app (`.Wispad.nouveau.app`, même dossier), vérifiée à son tour ; démontage du disque ;
  5. si une dictée est en cours, attente de sa fin (« Après la dictée… ») ; puis remplacement atomique de l'app par
     la copie (échange des deux noms, APFS : un échange raté, disque plein ou droits retirés, laisse l'app à sa
     place sans la déplacer ; sur un volume qui ne sait pas échanger, HFS+, exFAT ou partage réseau, deux
     renommages, l'ancienne app remise en place si le second échoue) ; l'ancienne version est effacée ;
  6. relance : la fenêtre de mise à jour se ferme (affichée en feuille, elle fait refuser, sans rien dire, la
     fermeture de l'app par macOS), puis Wispad quitte ; une petite aide attend la fin de cette instance (60 s au
     plus), puis ouvre la nouvelle version, qui rouvre la fenêtre si elle était affichée ; la bulle confirme
     « Wispad 0.1.2 est installé ». Si macOS refuse quand même de fermer Wispad (trois demandes, par exemple une
     autre feuille ouverte), Wispad s'arrête de force après avoir rangé comme à une fermeture normale (son du Mac
     rétabli, réglages écrits) : une fois ses fichiers remplacés, l'ancienne instance n'a plus accès au micro ni à
     l'accessibilité et ne peut plus dicter. L'aide ouvre alors la nouvelle version.

  Réglages, clés API, historique, audios et dictionnaire vivent hors de l'app (préférences de `com.yatofix.wispad`,
  `Application Support/Wispad`, coffre de secrets) : la mise à jour n'y touche pas. Les copies cachées laissées par
  une installation interrompue (la nouvelle version, Wispad quitté avant le remplacement ; l'ancienne,
  `.Wispad.ancien.app`, entre les deux renommages) sont effacées au lancement suivant.

  Une seule installation à la fois, même avec deux Wispad ouverts (`open -n`, deux sessions) : un verrou dans le
  dossier temporaire de l'utilisateur, que macOS rend si Wispad est tué. Le second s'arrête avant de rien
  télécharger ni toucher (« Un autre Wispad ouvert installe déjà une mise à jour : réessaie quand il aura fini. »),
  et son nettoyage du lancement laisse en place la copie cachée que le premier installe.
- **Page de la release à la place** : app dans un dossier non modifiable (par exemple /Applications pour un compte
  sans droits d'administration), lancée depuis le disque d'installation ou déplacée par macOS, app sans signature
  Developer ID, ou release sans `Wispad.dmg` : « Mettre à jour » ouvre la page de la release dans le navigateur, et la
  fenêtre de mise à jour dit pourquoi.
- **Échec** (autre installation en cours, téléchargement, fichier incomplet ou modifié, disque illisible, signature
  refusée, version pas plus récente, copie, remplacement, relance) : message clair dans la fenêtre de mise à jour,
  « Échec de la mise à jour » dans la barre latérale (un clic rouvre la fenêtre), avec le lien vers la release. L'app
  en place n'est jamais laissée à moitié remplacée ; le journal (`mise-a-jour`) ne garde que le nom de l'étape, sans
  chemin.
- **Publier une release** (mainteneur) : `scripts/release.sh`, voir son en-tête (variables d'environnement, étapes).

## Aide et retours

Réglages › Aide et retours, en bas de l'écran : une ligne d'explication (« Sur GitHub : seules les versions de
Wispad et de macOS sont préremplies. ») et trois liens. « Signaler un problème » et « Proposer une idée » sont
aussi dans le menu de la barre des menus, juste avant Quitter, et dans le menu Aide. Chaque lien ouvre sa page dans
le navigateur ; depuis un menu, la fenêtre de Wispad ne s'ouvre pas.

- **Signaler un problème** : nouveau ticket sur le formulaire de bug du dépôt (`bug.yml`), prérempli par l'adresse.
  Champ `version` : la version et le commit de la barre latérale, sans le nom de l'app (« 0.1.0 · abc1234 ») ; le
  commit seul si la version manque, la version seule sans commit gravé, rien si les deux manquent. Champ `macos` :
  « macOS 15.3.1 », toujours trois nombres. Valeurs encodées pour l'adresse (espace, « · », « + », « & », « # »…).
- **Proposer une idée** : Discussions du dépôt, catégorie Ideas. **Poser une question** : catégorie Q&A.
- Rien d'autre dans l'adresse : ni dictée, ni réglage, ni donnée personnelle. Wispad n'envoie rien lui-même : un
  ticket n'existe que si on le publie sur GitHub.

## Diagnostic

Réglages › Diagnostic exporte un JSON local : autorisations, raccourci, bulle, durées et API des 50 dernières
tentatives. Aucun texte dicté, audio, contexte, chemin ni clé. Rien n'est envoyé automatiquement.
