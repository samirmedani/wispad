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
- Un double appui ou un maintien reconnu démarre toujours sa dictée, même quand Wispad, occupé, traite d'abord un
  Échap pressé juste après : Échap annule alors seulement ce qui se terminait. Aucun appui suivant ne se perd à
  arrêter une dictée jamais démarrée.
- Une dictée arrêtée sans son geste (Échap, ✕, micro en échec ou perdu) pendant que d'autres gestes attendent leur
  tour ne remet pas le raccourci au repos : il en est déjà à ces gestes, et la dictée qu'ils démarrent s'arrête au
  raccourci comme d'habitude (un appui en mains libres, le relâchement en maintien).
- Jamais mort ni bloqué : une touche relâchée sans que l'écoute du clavier le voie (écoute coupée par macOS, champ
  de mot de passe, écran verrouillé, autre session, veille) arrête la dictée en maintien au plus tard à la
  vérification suivante de l'écoute (voir « Réactivité ») ; le raccourci répond ensuite normalement. Échap n'est
  jamais avalé à tort ensuite.
- Réglages › Raccourci › Modifier : la touche essayée, fn comprise, ne démarre ni n'arrête aucune dictée ; une
  dictée en maintien déjà en cours s'arrête quand on relâche sa touche. Un raccourci remplacé pendant qu'on le tient
  arrête sa dictée dès la frappe suivante, au plus tard à son relâchement ; le nouveau répond dès son premier appui.

### Coller la dernière dictée

Raccourci global, ⌃⌥V par défaut : faisable d'une main (⌃⌥ sous le pouce et l'annulaire gauches, V sous l'index),
libre dans macOS et rare dans les apps courantes, contrairement à ⌘⇧V (coller sans mise en forme) et ⌥⌘V (déplacer
dans le Finder). Sur un clavier AZERTY ou QWERTZ, c'est la même touche V.

- Il colle au curseur actuel la dernière dictée non insérée de la dernière demi-heure (prête à copier, aucun champ,
  collage raté, champ sécurisé), sinon la dernière dictée. Jamais une dictée annulée, vide ou sans transcription.
  Rien à coller : la bulle le dit (« Aucune dictée à coller »).
- Même insertion qu'une dictée, dans l'app au premier plan. Les touches modificatrices doivent être relâchées
  (attendues 5 s au plus, voir « Insertion ») ; sinon le texte reste prêt à copier, aucun raccourci parasite n'est
  envoyé.
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
  3 s et rétablie si macOS l'a coupée, jamais sans les autorisations qu'elle avait à son installation (voir
  « Autorisations retirées ou rendues ») ; restée active, elle est recalée sur la touche réelle du raccourci, au cas
  où elle n'aurait rien reçu sans être coupée.
- L'audio s'initialise sur une file dédiée, la bulle s'affiche tout de suite ; le moteur arrêté est réutilisé.
- Au lancement (après une mise à jour aussi), Wispad charge en arrière-plan la liste des composants audio de macOS,
  sans créer de moteur ni ouvrir le micro. Le service système qui la fournit s'arrête seul au repos et peut mettre
  2 à 3 s à répondre quand il redémarre : sans ce chargement, la première dictée l'attendait, bulle figée, micro
  ouvert jusqu'à 3,2 s après l'appui. Chargée une fois, la liste reste dans Wispad jusqu'à ce qu'il quitte.
- Démarrage du micro surveillé, première dictée après un lancement comprise : si macOS reconfigure l'entrée
  (micro Bluetooth qui change de profil, autre fréquence, micro débranché), le moteur repart aussitôt, dans le même
  enregistrement ; au repos, il est remplacé par un neuf à la dictée suivante. Aucun audio 1,5 s après le
  démarrage : le micro redémarre une fois sur un moteur neuf. Dictée arrêtée ou annulée pendant ce redémarrage
  (touche relâchée, Échap, ■) : elle s'arrête tout de suite, sans attendre le moteur ; rien n'avait été entendu, rien
  n'est envoyé, et le moteur se referme dès qu'il rend la main. Toujours rien 1,5 s plus tard, ou démarrage (comme
  redémarrage) qui ne rend pas la main en 4 s : la dictée est abandonnée, rien n'est envoyé, Wispad revient prêt (le
  raccourci redémarre une dictée) et la bulle affiche « Le micro n'a pas démarré : réessaie ». Rien ne reste ouvert :
  micro, flux de transcription déjà branché et spectre se referment, même un démarrage qui rend la main juste après
  l'abandon. Une erreur du micro (aucun micro, moteur refusé) s'affiche de même dans la bulle.
- Micro qui disparaît en pleine dictée sans autre micro pour prendre le relais (ou moteur qui refuse de repartir) :
  la dictée s'arrête là, comme si on l'avait terminée. Ce qui a déjà été dit est transcrit et collé, le raccourci est
  aussitôt libre et la bulle affiche « Le micro ne répond plus : dictée arrêtée ». Jamais de bulle figée sur un
  spectre immobile.
- Le micro reste fermé au repos ; un appui simple ne le prépare pas.
- La lecture du champ actif (lente dans les apps Electron) ne retarde pas l'enregistrement : l'audio est gardé
  jusqu'à ce que la transcription en direct soit branchée (le champ est attendu 150 ms au plus pour ses mots-clés).
- Une app lente ou figée (chaque question d'accessibilité l'attend 0,5 s), une base tenue par un autre programme, un
  disque lent ou un outil de mise à jour qui tarde n'occupent aucun des fils dont dépendent les délais de la dictée
  (démarrage du micro, champ actif attendu 150 ms, relecture du champ après ⌘V) : ces délais restent tenus. Chaque
  lecture d'une autre app a sa file : une app figée ne retarde pas la dictée suivante dans une autre app.
- Chaque dictée ajoute une ligne à `~/Library/Application Support/Wispad/latence.log` (date, mode ; appui →
  bulle, micro, premier audio, flux ; fin → collé ; statut), sans aucun texte, 500 lignes au plus.

## Historique

- Une dictée par ligne, groupées par jour (Aujourd'hui, Hier, puis la date), de la plus récente à la plus ancienne.
- Un texte coupé à quatre lignes montre « Afficher tout » ; le bouton n'apparaît que si la coupure est réelle à la
  largeur de la fenêtre.
- Au survol : détails, copier, retranscrire et écouter (si l'audio est gardé), supprimer.
- La recherche filtre dès que l'on cesse de taper (150 ms) ; l'effacer réaffiche tout aussitôt. Elle porte sur le
  texte collé et sur ce qui a été entendu : une dictée dont la correction est partie à côté se retrouve par ses mots.
- Le défilement reste fluide avec des milliers de dictées : seules les lignes visibles sont construites, et une
  ligne déjà vue n'est ni reformatée ni remesurée.
- Supprimer une dictée, ou tout l'historique, l'efface aussi de la mémoire de Wispad, même ouvert depuis des jours ;
  l'historique relu après chaque dictée n'y est jamais gardé en double.
- Un texte enregistré (dictée, transcription, autre écoute, app, mot du dictionnaire, refus) se relit en entier, même
  avec un caractère de contrôle : un caractère nul ne le coupe plus.

## Bulle

- Verre fumé noir (Liquid Glass sur macOS 26+), ou verre transparent (voir « Style de la bulle »), au-dessus du
  Dock, sur le bureau comme au-dessus d'une app en plein écran, avec le spectre de la voix (graves au centre) à la
  cadence de l'écran (120 Hz en ProMotion).
- Elle laisse passer les clics, sauf sur ses boutons : ✕ / ■ en mains libres, Copier et Coller d'un texte non
  écrit, Voir / Retirer d'un mot appris, ✕ d'un message.
- Messages, sans contour : sur une ligne (erreur, « Collé », mot appris, relais, nouvelle version), 42 points de haut,
  texte de 13 points sur deux lignes au plus, 520 points de large au plus ; en carte de 392 points (texte prêt à
  copier), avec les boutons sur leur propre ligne. Brefs et sans point final (une erreur de macOS terminée par un
  point le perd). À gauche, une pastille de la couleur du message (rouge : erreur, vert : réussite, vert d'eau :
  relais, bleu : nouvelle version, orange : texte prêt, violet : mots appris, gris : information) ; son anneau se vide
  pendant le décompte. Pointeur sur la bulle, sans clic préalable : le décompte (anneau compris) s'arrête et reprend
  où il en était à la sortie ; sur une ligne, la pastille devient la ✕, sur une carte la ✕ paraît en haut à droite.
  Rien ne bouge. Un message qui paraît sous le pointeur attend aussi. La ✕ ferme le message tout de suite, sans
  prendre le focus ni le premier plan à l'app active. La bulle d'enregistrement (spectre, finalisation) n'a ni ✕ ni
  décompte.
- **Style de la bulle** (Réglages › Bulle) : **Noir profond** (par défaut) : messages noirs avec un reflet doux sur
  le haut et une ombre, bulle de dictée en verre fumé noir de 30 points de haut ; lisible sur tous les fonds. Ou
  **Verre** : la bulle de dictée (spectre, mains libres et ses boutons, finalisation) et tous les messages passent en
  Liquid Glass transparent de macOS 26 (matériau translucide avant), sans liseré, avec une ombre portée douce dessinée
  hors de la forme (le verre n'est pas assombri). La bulle de dictée y fait 40 points de haut, spectre et boutons
  agrandis d'autant : à 30 points, la lentille et les reflets du verre ne se voyaient presque pas. Le spectre garde
  ses couleurs, la vague de finalisation et la ✕ se foncent sur un verre clair. Le changement vaut tout de suite. En
  Verre, trois réglages de plus : **Apparence du verre**, Clair (par défaut : brillant, il laisse voir ce qu'il y a
  derrière, même une fenêtre sombre, comme sur iPhone), Sombre (verre fumé) ou Comme l'app (clair ou sombre comme
  l'apparence de l'app, le rendu d'avant la 0.2.11) ; puis les deux verres natifs d'Apple : **Verre** Transparent
  (par défaut, le plus transparent) ou Dépoli (plus flou, plus lisible sur un fond chargé), et **Intensité**, la
  teinte posée sur ce verre (25 % par défaut ; à zéro, le verre seul ; au maximum, 70 % d'opacité), sombre sur un
  verre sombre et claire sur un verre clair. Un aperçu sous ces réglages montre la bulle de dictée et un message avec
  le vrai verre, dans l'apparence choisie, au-dessus d'une page claire et d'un fond sombre ; il suit le curseur, comme
  la bulle affichée. L'intensité s'enregistre au relâchement du curseur.
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
  principal) : ni la bulle ni le collage ne l'attendent. Un collage retenu sans ⌘V (touche modificatrice restée
  tenue) lit aussi la zone, avant d'afficher sa carte. Elle vaut pour cette app pendant 2 minutes, tant que les
  écrans ne changent pas (branché, débranché, autre résolution). Une zone illisible (coordonnées infinies, NaN ou
  démesurées) est ignorée.
- **Écrans qui changent** (écran externe branché ou débranché, autre résolution ou échelle, autre écran principal) :
  la bulle affichée, dictée en cours comprise, reprend aussitôt sa place sur son écran, retrouvé même quand les
  coordonnées de tous les écrans changent, ou sur celui du pointeur si le sien a disparu. Pendant une dictée, elle ne
  change pas d'écran tant que le sien est branché. Toujours entière sur un écran existant, jamais sur un écran
  disparu ; sans aucun écran, elle attend son retour. La place choisie, gardée en fractions de l'écran, ne change
  pas : la bulle la retrouve quand son écran revient. Le Dock ou la barre des menus seuls ne la déplacent pas, elle
  reste entière. Le spectre continue, à la cadence d'un autre écran, quand le sien est débranché.
- Deux notes montantes signalent le premier audio réellement reçu, une seule fois ; d'autres sons marquent la fin
  et l'annulation. Tous se coupent dans Réglages.
- Une app passée en plein écran après la première bulle reçoit une bulle neuve : macOS ne rattache une fenêtre de
  tous les bureaux à un espace plein écran qu'à sa première apparition.

## Fenêtre

- Ouverte depuis le menu de la barre des menus, le Dock ou un raccourci de section, elle vient sur le bureau où
  l'on se trouve, même par-dessus une app en plein écran ; déjà visible sur ce bureau, elle ne bouge pas.
- Une fois affichée, c'est une fenêtre ordinaire : passer à une autre app, cliquer sur le bureau ou changer de
  bureau la laisse à sa place et sur son bureau, simplement derrière l'app active.
- **Apparence** : Système (par défaut, suit macOS, y compris son passage automatique du clair au sombre), Clair ou
  Sombre. Choix rapide par le bouton à droite de « Wispad » en haut de la barre latérale (son icône montre le choix
  en cours, un clic ouvre trois vignettes), ou dans Réglages › Apparence. Toute l'app change aussitôt, en fondu
  (sans fondu avec « Réduire les animations ») : fenêtre, premier lancement guidé, notes de version, bulles d'aide.
  La bulle en noir profond et le schéma de Réglages › Bulle restent sombres ; la bulle en verre suit son réglage
  Apparence du verre (clair par défaut, ou comme l'app). Le choix est gardé après une
  relance ou une mise à jour, et posé avant l'ouverture de toute fenêtre.
- Choix d'affichage mémorisés, retrouvés après avoir quitté et relancé Wispad, chacun enregistré dès qu'il change :
  - période de l'Accueil (7 jours par défaut) ;
  - période de Consommation (Aujourd'hui par défaut), indépendante de celle de l'Accueil ;
  - taux du curseur « Taxes » de Consommation (20 % par défaut) ;
  - section, origine et période du Dictionnaire (Mots, Tous et Toute période par défaut) ;
  - dernière section ouverte dans la barre latérale (Accueil par défaut) : la fenêtre rouvre dessus depuis le
    Dock ou « Ouvrir Wispad » ; un raccourci de section ou un menu de section ouvre toujours la sienne ;
  - « Clés facultatives » dépliées ou non dans Fournisseurs (repliées par défaut).

  Un choix illisible ou inconnu reprend sa valeur par défaut, sans toucher aux autres réglages. Restent
  éphémères : les recherches de l'Historique et du Dictionnaire, une saisie en cours (clé, terme du dictionnaire),
  une dictée dépliée dans l'Historique, le détail ouvert.

## Réglages

Sept onglets en haut de la page, un thème par page : plus besoin de tout faire défiler. **Général** (Raccourci,
Général, Apparence), **Dictée** (Audio, Transcription, Correction, Apprentissage), **Mise en forme** (Mise en forme,
Ton selon l'app), **Bulle** (Bulle et messages), **Confidentialité**, **Autorisations**, **Aide** (Mises à jour,
Diagnostic, Aide et retours). Chaque onglet s'ouvre en haut de sa page ; le dernier ouvert est retrouvé au lancement suivant. Un micro
refusé au moment de dicter ouvre Autorisations, et un point orange y signale une autorisation manquante. Fenêtre
étroite : les icônes seules, leur nom en bulle d'aide. Aucun bloc de texte sous une liste : chaque réglage porte, dans
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
  Réglages Système et le chemin exact est affiché. L'état est relu toutes les 0,5 s, hors du fil principal, et aussitôt
  après « Autoriser » (voir « Autorisations retirées ou rendues »). Surveillance des entrées accordée mais écoute du
  clavier impossible après 3 s : macOS attend une relance, « Relancer Wispad » rouvre l'app à la même étape (si macOS
  refuse de la fermer, elle s'arrête d'elle-même après le rangement habituel).
- **Micro** : choix du micro (celui du système par défaut ; le micro choisi sert ensuite aux dictées tant qu'il est
  branché, sinon celui du système ; Réglages › Dictée › Audio) et vumètre réel. ✓ quand une vraie voix est
  entendue : au moins 0,6 s au-dessus de −48 dBFS et 10 dB au-dessus du bruit de la pièce (un clic, un souffle ou
  un ventilateur ne suffisent pas). Sans voix après 12 s, l'écran dit quoi vérifier, avec « Réessayer » : aussi
  quand le micro ne livre aucun son, ou que son ouverture ne rend pas la main (« Le micro n'a pas pu s'ouvrir ») ;
  quitter l'étape ne l'attend pas. Seul le niveau est lu : l'audio n'est ni enregistré, ni gardé, ni envoyé.
  Accès au micro retiré dans Réglages Système pendant l'écran : le test rend le micro ; rendu, le test repart seul.
- **Fournisseur** : xAI ou OpenAI, clé collée puis vérifiée chez le fournisseur avant d'être enregistrée (même
  vérification que Fournisseurs) ; une clé déjà enregistrée est revérifiée sans être réécrite, et de nouveau avec
  « Réessayer » ou en revenant sur l'étape si sa vérification n'a pas abouti (réseau, réponse inattendue), sans la
  recoller. Clé refusée (HTTP 400 ou 401 ; xAI répond 400 à une clé fausse) : à recopier ; reconnue mais refusée
  (HTTP 403) : crédit épuisé, plafond de dépenses atteint, clé désactivée ou limitée, à voir dans la console du
  fournisseur. « Vérification… » ne s'affiche que pendant une vraie vérification. ✓ seulement avec une
  clé acceptée. Lien vers la page de création de clé de chaque fournisseur. Correction facultative (DeepSeek, relais
  OpenAI) avec la même vérification, et les réglages « Comprendre le sujet grâce à la fenêtre active » et
  « Apprendre de mes corrections ».
- **Touche** : maintien et double appui expliqués, avec les touches du raccourci dessinées et le schéma du clavier
  de MacBook où elles sont en couleur (elles passent au vert dès qu'un appui est reçu) ; pendant cette étape, chaque appui est seulement constaté
  (« Touche détectée », gestes reconnus allumés) et aucune dictée ne démarre. Rien reçu en 10 s : rappel de la
  surveillance des entrées, avec « Ouvrir Réglages Système » et « Relancer Wispad » (reprise à cette étape), et du
  réglage macOS « Touche fn/🌐 : Ne rien faire » s'il lance autre chose ; clavier sans touche fn, ou raccourci
  personnalisé que macOS ou une autre app garde : « Plus tard », puis Réglages › Raccourci.
- **Essai** : vraie dictée avec la touche dans un champ de l'écran, phrase suggérée. Le test de la touche est
  toujours rendu en arrivant ici (un test resté actif hors de l'étape « Touche » est abandonné) : le raccourci
  dicte pour de vrai. Dictée faite dans la fenêtre de Wispad : son texte final s'écrit directement dans le champ
  d'essai, sans collage système. ✓ quand une dictée se termine et que son texte arrive dans le champ (2 s au plus
  après un collage), avec le nombre de mots et la durée. Un texte tapé à la main ne compte pas. Aucune attente
  n'est infinie : geste reçu sans écoute ouverte en 4 s, ou micro qui s'ouvre / dictée qui se termine sans aboutir
  en 45 s, et l'essai passe en échec avec sa cause. En cas d'échec, la cause : micro, clé, réseau, fournisseur,
  rien entendu, collage, annulation, dictée non démarrée ou délai dépassé, avec « Réessayer » et l'étape à revoir.
- **Fin** : rappel des deux gestes, lien vers Réglages, « Terminer ». Une fois la fin atteinte, la configuration est
  faite : Wispad quitté (ou le Mac redémarré) avant « Terminer », elle ne revient pas au lancement suivant.

Une installation existante (réglages sans ce champ) ne refait pas la configuration après une mise à jour.
Réglages › Général › « Revoir la configuration » la rejoue sans rien effacer ; on peut la quitter à tout moment.
Fenêtre fermée pendant la configuration : le test du micro s'arrête, la touche dicte de nouveau normalement et
l'état n'est plus relu jusqu'à la réouverture. Rouverte, une étape déjà réussie le reste (voix entendue, tant que
l'accès au micro est accordé ; appuis de la touche ; essai) ; une dictée arrivée dans le champ d'essai pendant la
fermeture compte.

## Transcription

Toujours chez un fournisseur, au choix dans Fournisseurs : xAI `grok-voice-transcribe-2.0` (recommandé) ou OpenAI
`gpt-live-transcribe`, en direct pendant l'écoute. Par défaut, l'enregistrement complet est aussi transcrit à la fin
(« Vérifier chaque dictée sur l'enregistrement complet », environ 0,0005 $ de plus) :

- même texte (casse, accents, ponctuation, hésitations, nombres en lettres ou en chiffres, unités, élisions,
  en français comme en anglais) : le flux est gardé, sa correction déjà lancée est collée ;
- texte différent : celui du fichier est corrigé et collé, le flux sert d'« autre écoute » à la correction et reste
  avec la dictée dans l'historique local (pour comprendre le désaccord et pour le banc des erreurs signalées) ;
- texte différent en un ou deux endroits courts : un remplacement (trois mots au plus, même nombre de mots à un près)
  ou, au milieu d'une phrase, un mot ajouté ou retiré (un seul mot écrit, comme « ne » ou « peut-être », entre deux
  mots séparés par de simples espaces, jamais une répétition comme « le le ») ; l'endroit est retrouvé dans la
  correction grâce aux voisins de l'écoute (un voisin s'il ne désigne qu'un endroit, sinon les deux, et toujours les
  deux pour un mot retiré) et aucun terme du dictionnaire n'est touché. Les mots du fichier sont alors reportés dans
  la correction du flux, sans second appel, si elle est déjà prête ou si elle finit avant la correction complète du
  fichier, lancée aussitôt sans attendre 0,3 s une correction obsolète ;
- fichier en échec, sans aucun mot ou trop lent (1,2 s + 0,06 s par seconde d'audio, 4 s au plus) : le flux est
  gardé. Il l'est aussi quand le réglage est coupé et qu'une fin de flux peu fiable rappelle un fichier vide.

Si le fichier a déjà répondu quand le flux se termine, le choix est fait immédiatement : seule la transcription
retenue part à la correction. Une correction déjà préparée sur ce même texte reste réutilisable. Sinon, la
correction du flux continue à se préparer en parallèle du fichier. La vérification audio n'est pas sautée,
même pour une dictée de quelques mots.

Fin du flux xAI : à l'arrêt, Wispad envoie `finalize`. Le texte final est retenu dès que xAI renvoie le segment de fin
de parole qui couvre tout l'audio envoyé, à 0,1 s près. Wispad n'attend plus `transcript.done`, qui répète ce texte
environ 0,1 s plus tard (vérifié le 17 octobre 2026). Si le segment est plus court que l'audio ou s'il manque la fin de
parole, Wispad attend `transcript.done`, comme avant.

Ordinaux : avec la mise en forme française, le fichier xAI écrit « 1ᵉʳ », « 1ʳᵉ », « 2ᵈᵉ » ou « 3ᵉ ». Wispad remet le
mot dit dès la réception, avant de le comparer au flux : « 60 images par 2ᵈᵉ » → « 60 images par seconde », « dans un
1ᵉʳ temps » → « dans un premier temps », « la 2ᵉ semaine » → « la deuxième semaine ». Au-delà de dix, l'abréviation
reste (« 21ᵉ siècle ») ; une date reprend son format (« le premier mai » → « le 1er mai »). Le même filet passe avant
et après la correction.

**Sans connexion** : rien n'est transcrit sur le Mac. Si la connexion manque ou se perd pendant la dictée (flux et
fichier en échec, puis le relais de voix s'il a une clé et que la connexion est revenue), l'audio reste dans
l'historique pour **Retranscrire** une fois la connexion revenue. Hors connexion, le relais n'est pas tenté : il
échouerait de même et compterait une bascule ratée. Un échec hors connexion ne dit rien du fournisseur : il n'est pas
compté pour le mettre de côté, et la dictée suivante, connexion revenue, repart chez lui sans bascule. La correction
par un fournisseur est sautée hors connexion, celle préparée pendant l'écoute ou à l'arrêt comprise (seules les
commandes de mise en page s'appliquent).

Une installation qui transcrivait « Sur ce Mac » (fonction retirée) repasse sur le cloud au lancement ; les modèles
téléchargés par Wispad et les réglages devenus inutiles sont effacés.

La trace de chaque dictée donne la source retenue, la raison, les durées, le nombre de mots en désaccord entre flux
et fichier, l'usage de la correction préparée pendant l'écoute et le report des mots du fichier, jamais le texte.

### Micro

**Réduire le bruit et l'écho du micro** (Réglages › Dictée › Audio, désactivé par défaut) : les dictées passent par le
traitement de la voix de macOS, celui des appels FaceTime (bruit de fond et écho réduits, gain automatique), pour
parler loin du Mac ou dans une pièce qui résonne. Pendant une dictée, Centre de contrôle › Mode micro propose aussi
« Isolation de la voix ». Les autres sons du Mac ne baissent pas (« Couper le son du Mac » reste le seul à le faire).
Mesures du 17 octobre 2026 sur un MacBook Pro :

- activer le traitement prend environ 0,7 s et change une fois la configuration de l'entrée, 0,3 s plus tard. Wispad
  l'active au repos, au lancement et quand le réglage s'allume, sans ouvrir le micro (voyant éteint, aucune demande
  d'autorisation), et attend ce changement avant d'écouter. La première dictée démarre alors en 0,05 s (premier son
  à 0,16 s, contre 0,6 s au micro standard) ; sans préparation, en 1,1 s. Un changement de configuration au repos
  garde ce moteur prêt ; pendant l'écoute, il ne la relance que si le moteur s'est arrêté ;
- le traitement rend la même voix sur 9 voies : une seule est gardée, jamais leur somme. Il livre des paquets de
  0,1 s ;
- brancher la sortie du moteur l'empêche de démarrer (erreur -10875) : elle reste débranchée ;
- refusé (activation ou démarrage impossible, même après un moteur neuf) : la dictée continue au micro standard, et
  le traitement reste de côté jusqu'à ce que le réglage change ; la rangée le dit. Il ne vaut que pour le micro du
  système : un autre micro choisi dans Wispad reste en micro standard (le traitement règle aussi la sortie), et la
  rangée le dit aussi.

Le micro standard, réglage coupé, ne change pas.

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
  et la suivante la remplace ; quatre au plus par dictée. Jamais si la correction est coupée, ni hors connexion.
- **Correction lancée à l'arrêt** : dès l'arrêt, ce que le flux a déjà affiché part à la correction, sans attendre
  son texte final (0,3 à 0,5 s sur les dictées courtes, mesuré le 13 octobre 2026). Si le texte final dit la même
  chose, cette correction sert ; sinon elle est comptée et une correction du texte final la remplace. Rien de plus
  n'est lancé si une correction préparée à une pause porte déjà sur ce texte, ni hors connexion : la fin de dictée
  corrige alors si la connexion est revenue.
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
- une réponse qui perd la dictée : sur huit mots dits ou plus, elle n'en garde même pas un quart et se compose
  surtout de mots que personne n'a dits (texte de la fenêtre, réponse à la question dictée, traduction), ou d'aucun
  mot. La transcription est collée. Une correction courte faite de mots dits (« … non, oublie tout, écris juste
  merci » → « Merci. ») et des nombres mis en forme (« vingt-quatre octobre » → « 24/10 ») restent ;
- un mot traduit (« outils » → « tools ») : le mot entendu est remis ;
- une marque, un nom ou une référence absents de ce qui a été dit et qui ne lui ressemblent pas à l'oreille, même
  mis entre guillemets ;
- une référence lettres puis chiffres (DDR4, i9) dont les chiffres n'ont pas été prononcés ;
- sur une dictée de trois mots au plus, tout mot qui ne ressemble au mot entendu ni à l'écrit ni à l'oreille, ou qui
  s'ajoute (hors « ne » rétabli) : la transcription est collée (« Était sérieux » ne devient pas « Sois sérieux » ;
  « cloud code » → « Claude Code » et « un sot d'eau » → « Un seau d'eau. » restent).

Le texte rendu n'est jamais blanc quand la transcription ne l'est pas : une correction blanche, ou une transcription
sans mot (« … ») dont la correction n'était qu'une référence inventée, laisse la transcription.

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

**Petits nombres** (Réglages › Mise en forme) : **Selon le contexte**, par défaut, ou **En chiffres**. Selon le
contexte, la correction écrit en lettres un nombre de zéro à dix qui compte des choses dans une phrase courante, même
si la transcription l'a mis en chiffres : « les 2 premières barres » → « les deux premières barres », « 3 fois » →
« trois fois ». Restent en chiffres les nombres au-delà de dix, les mesures, montants et données techniques
(« 5 secondes de latence », « 16 Go »), les décimales, dates, heures, scores, versions et références, et des nombres
comparés dans la même phrase (« entre 8 et 12 personnes »). Deux petits nombres qui se suivent restent tous les deux
(« deux, trois jours »). Le modèle tranche : il garde parfois un chiffre reçu de la transcription, jamais l'inverse
sur une mesure. En chiffres : tout nombre qui compte s'écrit en chiffres (« les 2 premières barres », « 3 fois »).
Banc : `WISPAD_NUMBER_STYLE=1 scripts/live-test.sh NumberStyleLiveTests` (`WISPAD_NUMBER_STYLE_MODEL` pour un modèle
xAI précis) ; le 18 octobre 2026, 22 cas sur 25 conformes avec Grok 4.20 sans raisonnement, les trois écarts gardant
un chiffre.

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

- **Ton selon l'app** (Réglages › Mise en forme › Ton selon l'app) : par catégorie (e-mails, messageries, documents, notes, code et
  terminal, navigateur, autres apps), « Comme dicté » (par défaut, comportement d'origine), « Soigné » (tournures familières écrites
  en forme standard, « ne » rétabli) ou « Détendu » (tournures gardées, pas de point final pour un message court).
  Le ton ne change que le registre, jamais les mots ni le sens ; le garde-fou de fidélité s'applique toujours.
- **Consigne sur la sélection** (Réglages › Dictée › Correction › « Réécrire la sélection sur consigne », actif par défaut) : avec du texte
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
- Les termes retenus sont ajoutés, puis une ligne discrète les présente ensemble, comme « Collé » (« « Vinted » ajouté
  au dictionnaire », jusqu'à trois mots, 5 s, sans prendre le focus). « Voir » ouvre leur section dans le
  dictionnaire ; « Retirer » retire le groupe affiché et mémorise le refus. Sans réponse ou avec ✕, les termes restent.
  Le décompte se suspend au survol et une nouvelle dictée passe toujours avant la bulle, qui revient ensuite.
- Les jugements sont sérialisés : un terme déjà ajouté par le jugement précédent n'est pas rejugé. Les refus
  sont relus après l'attente et avant l'ajout. Une réponse tardive n'ajoute rien si l'apprentissage a été coupé
  entre-temps. Un résultat ne peut ajouter que les candidats effectivement soumis, sans doublons.
- Un nom à graphie distinctive ressemblant à une simple flexion (« terraforme » → « Terraform ») est transmis
  au juge, pas ajouté aveuglément. Les accords ordinaires restent exclus par le filtre local.
- Les noms que la correction répare sont appris aussi, même sans retouche à la main (la plupart des dictées partent
  sans être relues, et un champ de chat se vide à l'envoi). À la fin de chaque dictée, le texte transcrit et le texte
  final sont comparés sur ce Mac (`DictionaryInsights`). Un nom réparé dans au moins deux dictées des 90 derniers
  jours (« revenu quatre » → « RevenueCat ») passe par le même juge, puis la même bulle. Seuls comptent un ou deux mots
  à graphie de nom (majuscule hors début de phrase, majuscule intérieure, sigle, lettres et chiffres, au moins deux
  lettres) qui sonnent comme ce qui avait été entendu, avec les mêmes chiffres. Changement de casse seul : graphie
  marquée seulement (« cli » → « CLI », « openai » → « OpenAI »), jamais une espace retirée (« 12 h » → « 12h »).
  La grammaire, la ponctuation, l'élision (« que Opus » → « qu'Opus »), les accords, les hésitations, les
  mots-outils en bord et les mots courants sont ignorés, ainsi qu'une dictée trop réécrite (moins de la moitié des
  mots gardés). Le juge lit la phrase telle qu'elle a été entendue. Les noms déjà au dictionnaire, refusés, du
  vocabulaire intégré ou isolés d'une expression connue ne lui sont pas soumis ; un nom qu'il écarte ne lui est
  plus resoumis avant le prochain lancement (un juge muet n'écarte rien). Jamais avec « Apprendre de mes
  corrections » coupé, après une sélection réécrite sur consigne, ni pour l'essai du premier lancement. L'analyse
  de l'historique tourne hors du fil principal ; chaque dictée n'est analysée qu'une fois par lancement.
- Seuls la phrase dictée et le mot corrigé sont envoyés (à Jev et au modèle de correction) ; le journal ne contient ni mot ni texte.

### Origine des mots

Chaque mot garde, sur ce Mac, qui l'a ajouté :

- **Toi** : mot ajouté à la main dans l'écran Dictionnaire, ou depuis ses suggestions.
- **Appris automatiquement** : mot corrigé après une dictée et retenu par un juge. Jev (TypeSafe) quand sa note
  suffit (cas net, ou modèle de correction sans réponse) ; sinon le modèle de correction qui a répondu (sans clé
  TypeSafe ou sans réponse de Jev, ou mot douteux pour Jev). Le fournisseur et le modèle notés sont ceux de l'appel
  qui a tranché : la route de correction qui a répondu (DeepSeek `deepseek-flash`, OpenAI `gpt-5.4-mini`, xAI
  `grok-4.7`…), ou pour Jev le modèle annoncé par sa réponse. Après un changement de clé ou de fournisseur, les mots
  suivants portent le nouveau modèle, les anciens gardent le leur.
- **« Voir » dans la bulle** ne fait pas du mot un mot « Toi » : le juge l'avait déjà ajouté.
  Le terme reste comme avec le silence ou ✕ ; « Retirer » le retire. La confirmation est notée et
  l'info-bulle dit « Gardé par toi » ; le mot garde son juge. « Toi » désigne seulement un mot ajouté à la main.
- **Avant le suivi** : mot ajouté par une version précédente. L'historique ne relie aucun appel de jugement à un
  mot ni ne garde le verdict de chaque mot : l'origine n'est pas devinée.

Le dictionnaire affiche par défaut les entrées les plus récentes en haut, dans tous les filtres et dans les deux
sections. Les en-têtes **Mot / Expression**, **Origine**, **Ajouté le** et **Dictées** trient la liste ; un second
clic inverse le sens, indiqué par une flèche. **Dictées** trie d'abord les plus dictées. Le choix reste mémorisé après relance. Le tri par origine groupe Par toi,
Automatique puis Avant le suivi (ou l'inverse), avec les plus récents en tête de chaque groupe. Il ne change ni
les données conservées ni l'ordre des termes transmis aux fournisseurs.

Écran Dictionnaire : deux sections mémorisées, Mots et Expressions et phrases. La classification suit le texte :
un seul élément sans espace reste un mot, plusieurs éléments (espaces ou retours à la ligne) forment une
expression. Les termes existants sont répartis sans être modifiés. Les noms composés peuvent donc être dans
Expressions et phrases ; ce n'est pas une décision du modèle. Aucune limite de longueur n'est ajoutée.

Les mots utilisent une table compacte Mot / Origine / Ajouté le / Dictées. Les expressions ont toute la largeur,
avec retour à la ligne et métadonnées dessous. Leur saisie accepte plusieurs lignes. Ajouter un terme ouvre sa section
et remet les filtres à Tous / Toute période pour qu'il reste visible. La recherche est temporaire ; origine et
période sont mémorisées. Les filtres se croisent, avec un compteur de résultats et un bouton de réinitialisation.

Badges : bleu « Par toi », violet « Automatique », gris « Avant le suivi ». Pour un terme appris, le juge
(« Jev », « DeepSeek », « OpenAI », « xAI »…) reste visible ; l'info-bulle précise le fournisseur, le modèle et
les dates. La corbeille retire une entrée. L'apprentissage automatique reste ciblé sur les corrections de noms,
marques et jargon ; il ne mémorise pas des paragraphes entiers.

**Dictées** : nombre de dictées de l'historique dont le texte final contient le terme, en mots entiers, sans
tenir compte de la casse, des accents ni de la ponctuation ; « Jamais » (« Jamais dicté » pour une expression)
quand aucune ne le contient. Sous un terme venu d'une correction, « entendu « … » » rappelle ce que la
reconnaissance avait écrit ; l'info-bulle de l'origine dit aussi d'où il vient (corrigé par toi après une dictée,
réparé par la correction dans plusieurs dictées, ajouté depuis les suggestions). Le crayon change l'écriture d'une
entrée (« codex » → « Codex ») sans toucher à son origine ni à sa date ; un terme déjà présent, à la casse près,
est refusé avec un message.

### Suggestions

En tête de l'écran Dictionnaire, une carte **Suggestions** propose, d'après les dictées des 90 derniers jours,
calculé sur ce Mac sans rien envoyer et hors du fil principal :

- **Mal entendu dans N dictées** (ou **Mal écrit** pour un changement de casse) : un nom réparé par la correction
  dans au moins deux dictées et pas encore appris, avec ce qui avait été entendu. **Ajouter** l'ajoute comme
  « Par toi », avec ce mot entendu.
- **Écrit ainsi dans N dictées sur M** : une entrée d'un seul mot écrite autrement dans au moins trois dictées et
  les trois quarts de celles qui la contiennent (« codex » → « Codex »). **Corriger** change son écriture.
- **Écrit de plusieurs façons** : un nom absent du dictionnaire écrit de plusieurs façons, chacune dans au moins
  deux dictées, dont une graphie marquée (« TestFlight » / « Testflight »). **Ajouter** ajoute la graphie marquée
  la plus fréquente.

Une majuscule de début de phrase ne compte jamais. Les noms déjà au dictionnaire, refusés, du vocabulaire intégré
ou isolés d'une expression connue ne sont pas proposés. ✕ (**Ignorer**) mémorise un refus, comme « Annuler
l'ajout » dans la bulle : le nom n'est ni reproposé ni appris. Trois suggestions sont affichées, les autres derrière
« Afficher les N autres » ; jusqu'à quatre, tout est affiché. La carte disparaît quand il n'y a rien à proposer.

Le banc synthétique `scripts/learning-bench.sh` vérifie l'extraction et mesure sa latence. `--live` demande une
clé dédiée `WISPAD_TEST_TYPESAFE_API_KEY` (et éventuellement `WISPAD_TEST_DEEPSEEK_API_KEY`) et mesure les
vrais verdicts, faux positifs, faux négatifs, erreurs et latences. Sans ces clés, aucun benchmark réseau n'est
fait et les résultats locaux ne constituent pas une mesure de la qualité de Jev.

## Relais en cas de panne

- Voix : si xAI ne répond pas, le même enregistrement part chez OpenAI (et inversement) s'il a une clé ; après deux
  échecs, la dictée démarre directement chez l'autre fournisseur.
- Correction : après deux échecs, DeepSeek passe après le relais. Un service mis de côté est contrôlé chaque
  minute et repris dès qu'il répond, au plus tard après 30 minutes.
- Hors connexion, aucun échec n'est compté, aucun service mis de côté n'est contrôlé et aucune bascule n'est tentée :
  un service n'est mis de côté que pour ses propres échecs, et un relais ne travaille que s'il peut répondre.
- Le spectre passe au vert quand un relais travaille ; la première bascule d'une panne est annoncée.

## Reprise après erreur

- Erreur réseau, de clé ou de quota : l'audio reste dans l'historique ; **Retranscrire** puis **Copier**.
- Texte qui n'a pas pu être écrit : jamais en silence. La bulle le dit dans une carte « Texte prêt à copier »
  (titre de 14 points), avec sous le titre la seule raison (12 points) et des boutons de 30 points sur une ligne
  séparée, **Copier** en évidence et **Coller** : « Pas de champ où écrire » (focus sur une liste, un bouton, un
  menu, ou le bureau et les fenêtres du Finder, avant l'envoi), « Le texte n'est pas arrivé dans le champ » (champ
  lisible resté identique 1 s après ⌘V), « Accessibilité non autorisée » (accessibilité retirée dans Réglages
  Système, ou jamais donnée : ni ⌘V ni lecture du champ), « Collage impossible » (app cible fermée ou qui a perdu le
  premier plan, presse-papiers non modifiable, ⌘V non envoyé), « Champ sécurisé ». Le menu de Wispad et le bandeau
  de la fenêtre, sans ce titre, ajoutent « : le texte est prêt » (« Pas de champ où écrire : le texte est prêt »).
  Le texte est déjà copié, sauf pour un champ sécurisé. 12 s, avec un anneau qui se vide autour de la pastille
  orange (en pause au survol) ; ✕ au survol ou Échap la ferment. Elle ne prend jamais le focus : **Copier** remet le texte au
  presse-papiers et confirme « Copié » (1,5 s), **Coller** le colle dans le champ de l'app active (même collage que
  « Coller la dernière dictée »). Le collage garde tous les formats du presse-papiers précédent et refuse les champs
  sécurisés.
- Champ sécurisé : un champ de mot de passe lu comme tel par l'accessibilité, ou la saisie sécurisée de macOS tenue
  par l'app où l'on dicte (sauf dans un champ lu, non sécurisé, avec curseur de texte), ou tenue par une app que macOS
  ne nomme pas. Tenue par une autre app (un champ de mot de passe resté actif dans Chrome, un gestionnaire de mots de
  passe), elle ne bloque pas le collage ailleurs : le 17 octobre 2026, Chrome la tenait et Wispad refusait de coller
  dans Codex. L'app qui la tient vient de macOS (`kCGSSessionSecureInputPID`) ; demandée par un outil en ligne de
  commande, elle est attribuée à l'app au premier plan, donc toujours refusée. Le champ est lu avant ce test : sans
  champ où écrire, la carte le dit au lieu de parler de champ sécurisé.
- Champ illisible (Codex, apps Electron, éditeurs dessinés) ou remplacé par un autre pendant la relecture : rien ne
  prouve un échec. Le statut reste « Collage envoyé », sans carte ni copie : la bulle ne revient pas à chaque dictée.
  Si le texte manque, « Coller la dernière dictée » et l'historique le gardent. Aucun apprentissage sur une
  insertion non confirmée ; « Coller la dernière dictée » dit « Collé » dans les deux cas.

## Autorisations retirées ou rendues

Micro, accessibilité et surveillance des entrées peuvent être retirés dans Réglages Système puis rendus, Wispad
ouvert, au repos comme en pleine dictée : rien ne plante, rien ne reste bloqué, et Wispad n'a pas à être relancé.
Wispad relit ces autorisations sans jamais les redemander : une demande de macOS ne paraît qu'après un clic.

- **Surveillance des entrées ou accessibilité** : l'écoute du clavier (raccourci, Échap, « Coller la dernière
  dictée ») voit passer et peut avaler chaque frappe de toutes les apps. Elle n'est jamais réarmée sans les
  autorisations qu'elle avait à son installation : réarmée sans elles, elle pourrait retenir le clavier de tout le
  Mac. Accessibilité retirée : vu à la vérification suivante (3 s), même si macOS laisse l'écoute active.
  Surveillance des entrées retirée : vu dès que macOS coupe ou invalide l'écoute ; tant qu'elle reste active,
  l'accessibilité lui suffit, et cette question au démon des autorisations de macOS (une dizaine de millisecondes)
  n'est jamais posée pendant que chaque frappe du Mac attend l'écoute. L'écoute est alors retirée, et remplacée par
  une écoute neuve si macOS en accepte encore une ; sinon le raccourci se tait. Une dictée en cours s'arrête alors
  comme si on l'avait terminée (ce qui a été dit est transcrit et collé ; un micro encore en démarrage se referme
  sans rien enregistrer) et la bulle affiche « Surveillance des entrées retirée : dictée arrêtée » ou
  « Accessibilité retirée : dictée arrêtée ». Un geste compté juste avant le retrait, dont la dictée n'a pas encore
  démarré (départ en file, clé encore en lecture), est oublié avec l'écoute : sa dictée ne démarre pas, puisque ni le
  raccourci ni Échap ne pourraient l'arrêter. Autorisation rendue, l'écoute revient à la vérification suivante : le
  premier appui compte, et Échap n'est jamais avalé à tort. Une autorisation donnée après l'installation de l'écoute
  n'est pas exigée ensuite.
- **Micro** : macOS peut laisser tourner le micro d'une dictée en cours en ne lui livrant plus que du silence.
  Pendant l'écoute seulement, l'accès est relu chaque seconde hors du fil principal (s'il était accordé au départ) :
  retiré, la dictée s'arrête comme si on l'avait terminée et la bulle affiche « Accès au micro retiré : dictée
  arrêtée ». Au repos, comme avant, la dictée suivante ne s'ouvre pas et Réglages s'affiche (« Le microphone n'est
  pas autorisé. »).
- **Accessibilité au moment du collage** : ni ⌘V ni lecture du champ ; le texte est copié et la carte « Texte prêt
  à copier » affiche « Accessibilité non autorisée » (voir « Reprise après erreur »). Même chose pour **Coller** et
  « Coller la dernière dictée ».
- **Affichage** : Réglages › Autorisations et l'alerte de la barre latérale sont relus à l'ouverture de la fenêtre ou
  de Réglages et à chaque retour dans Wispad (par exemple depuis Réglages Système) ; le premier lancement guidé les
  relit toutes les 0,5 s. Ces lectures se font hors du fil principal : le micro et la surveillance des entrées sont
  deux questions au démon des autorisations de macOS, une vingtaine de millisecondes (mesuré le 14 octobre 2026),
  assez pour faire sauter des images aux animations (bulle de l'accueil, vumètre, écran qui s'ouvre). Jamais deux à
  la fois : demandées pendant une lecture, elles sont faites ensemble par une seule relecture juste après (le premier
  lancement, lui, relit au passage suivant du sondage), et une réponse arrivée après une lecture plus récente ne
  l'efface jamais, valeur par valeur (« Ouvrir à la connexion » compris). Juste après une action (Autoriser, étape
  suivante du premier lancement, fenêtre rouverte, clic sur une rangée de Réglages › Autorisations, export du
  diagnostic), la relecture reste immédiate : l'écran ou le rapport en montre l'effet aussitôt. Fenêtre du premier
  lancement fermée pendant une lecture, sa réponse ne change rien.
- Insertion par ⌘V comme au clavier, dans toutes les apps : ⌘ enfoncée (changement de modificateur), V, puis ⌘
  relâchée, envoyés au système une fois l'app cible vérifiée au premier plan et les modificateurs relâchés. Le
  13 octobre 2026, l'écriture par `AXSelectedText` dans Chrome et un ⌘V adressé au seul processus cible laissaient
  le champ vide : ces deux voies sont retirées. Tous les chemins d'insertion partagent une file.
- Touche modificatrice (⌃ ⌥ ⇧ ⌘ fn) tenue au moment de coller (raccourci de capture d'écran, touche gardée
  enfoncée) : le collage l'attend 5 s au plus et part dès qu'elle est relâchée, toujours dans la même app (sinon
  « Pas de champ où écrire »). Le 17 octobre 2026, une touche tenue 2,4 s juste après une dictée faisait échouer le
  collage, qui n'attendait que 0,8 s. Toujours tenue au bout des 5 s : aucun ⌘V, la carte « Texte prêt » nomme la
  touche (« Touche ⇧ maintenue ») et Coller la colle d'un clic. Échap pendant l'attente annule la
  dictée.
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
- Base locale tenue en écriture par un autre programme (autre Wispad ouvert, outil qui l'inspecte) : Wispad démarre
  quand même et affiche l'historique ; une base à jour s'ouvre sans rien y écrire (seul le premier lancement d'une
  version qui la fait évoluer doit y écrire). Une écriture (dictée, mot, appel, ménage des audios expirés, fait d'un
  seul bloc) attend jusqu'à 2 s que la base se libère ; deux Wispad ouverts écrivent ainsi chacun leur tour, sans
  rien perdre.
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
- « D'où venaient les échecs », dans la même carte, dès qu'un appel a échoué sur la période (avec ou sans bascule) :
  chaque appel raté garde la cause lue dans l'erreur reçue, jamais son texte. Causes : pas d'internet sur ce Mac
  (aucune connexion, connexion perdue, nom du service introuvable), pas de réponse à temps (délai du système ou de
  Wispad), panne du service (erreur 5xx, connexion refusée), limite ou crédit atteint (429), clé refusée (401, 402,
  403), demande refusée (autre 4xx, erreur annoncée dans le flux), réponse inutilisable (vide, tronquée, illisible).
  Trois cases : Ta connexion (pas d'internet), Fournisseurs (le reste), Clés refusées, plus Incertain pour un délai
  dépassé sans aucun autre appel réussi dans la minute autour (la connexion a pu être en cause ; sinon le délai compte
  pour le fournisseur). Puis chaque fournisseur qui a échoué, quel qu'il soit, avec ses causes du plus fréquent au
  plus rare et le nombre de fois où il a été mis de côté. Une dictée annulée ou trop courte, ou une correction
  abandonnée parce que la dictée est annulée, n'est pas un échec. Les appels d'avant ce suivi n'ont pas de cause : ils
  restent hors de ce détail, et la date de début est rappelée en petit. Les dernières bascules montrent la cause de
  l'échec du service principal quand elle est connue. Sans bascule mais avec des échecs (aucune clé de secours),
  l'état le dit au lieu de « tes fournisseurs principaux ont toujours répondu ».
- Période « Tout », sur l'Accueil comme dans Consommation : sous le sélecteur, depuis quand et combien de temps
  (« Depuis le 1 oct. 2026 · 16 jours »), du premier jour d'utilisation à aujourd'hui, les deux compris (le jour
  même compte pour 1 jour). Moins d'un mois : en jours ; au-delà, en mois et jours (« 1 mois et 4 jours »), puis
  en années (« 1 an, 2 mois et 3 jours »). Premier jour : la plus ancienne dictée (Accueil), le plus ancien appel
  enregistré (Consommation).
- Carte « Coût par mois, face aux abonnements », en période « Tout » seulement : la dépense de tous les appels
  ramenée à un mois moyen (total ÷ jours d'utilisation × 30,44), taxe comprise, en dollars ; « ≥ » si des coûts sont
  inconnus. Barres comparées aux abonnements de dictée publics, au mois et hors taxes, relevés le 16 octobre 2026 :
  Wispr Flow Pro (15 $), Willow Voice Pro (15 $), Superwhisper Pro (8,49 $), chacun lié à sa page de tarifs, avec
  l'écart (« 7,8 fois plus cher ») quand il dépasse 10 %. Une phrase chiffre l'économie face à Wispr Flow Pro, par
  mois et par an (« jusqu'à » si des coûts sont inconnus), ou dit que Wispad revient plus cher à ce rythme. Moins de
  7 jours d'utilisation : l'estimation est dite provisoire. Les prix à l'année sont rappelés en note.
- Curseur « Taxes » de 0 à 27 % (20 % par défaut, la TVA française) : les prix publiés étant hors taxes, le taux
  s'ajoute aux abonnements comme aux appels d'API. Sous le curseur, le pays de repère au taux le plus proche, avec
  son drapeau et son nom dans la langue du Mac (« Taxe de 🇫🇷 France », « Taxe proche de 🇷🇴 Roumanie (21 %) »),
  « Sans taxe » à 0 %. Repères, taux normaux officiels au 16 octobre 2026 : Émirats arabes unis 5 %, Thaïlande 7 %
  (jusqu'au 30 septembre 2027), Suisse 8,1 %, Singapour 9 %, Japon 10 %, Nouvelle-Zélande 15 %, Mexique 16 %,
  France 20 %, Roumanie 21 %, Slovaquie 23 %, Estonie 24 %, Finlande 25,5 %. À moins de 0,3 point d'un repère, le
  curseur s'y place exactement ; ailleurs, au dixième. Le taux est enregistré au relâchement du curseur.
- Tableau « Derniers appels » : en-têtes (heure, service, détail, durée, coût), lignes alternées ; par appel, son
  état (pastille verte ou rouge), l'heure (et le jour s'il n'est pas d'aujourd'hui), le fournisseur en couleur
  (Jev pour TypeSafe), la tâche (transcription en direct, du fichier, correction, dictionnaire) et le modèle, l'audio
  ou les jetons (« 370 + 4 480 en cache → 30 jetons »), la durée (en secondes au-delà d'une seconde) et le coût
  (« inconnu » sinon). En couleur sous le détail : « Secours après DeepSeek · échec ou délai dépassé », « Secours en
  échec après … » ou « Échec ». Au survol : tarif du modèle et compteurs détaillés. 15 appels, puis « Afficher
  plus » (30 de plus par clic) ; « 15 sur 1 234 » en haut à droite ; changer de période revient à 15.
- Rien de l'historique n'est effacé ; l'ancienne date de début du suivi financier est retirée au lancement.

## Clés API

- Fournisseurs recommande, sous les clés : xAI pour la voix, DeepSeek pour la correction (la moins chère), et Jev
  (TypeSafe), facultatif, pour les mots à apprendre. Chaque service se remplace par un autre dont on a la clé. La
  clé TypeSafe est proposée à tous, dans « Clés facultatives » ; sans elle, le modèle de correction juge seul.
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
  enregistrée, comme la clé TypeSafe (liste des modèles de Jev, gratuite) ; la clé de gestion xAI est enregistrée
  sans vérification. Une réponse 400, 401 ou 403 est un refus (« Clé refusée ») ; une autre réponse ou l'absence de
  réseau laisse la clé non vérifiée. Dans les deux cas, rien n'est enregistré.
- Fichier de clés : une entrée d'un autre type (ajoutée par une version plus récente, ou abîmée) ne cache aucune autre
  clé et reste telle quelle quand on en enregistre une. Un fichier abîmé (tronqué, invalide) n'est jamais réécrit :
  les clés de sa partie intacte servent, les autres sont dites illisibles.
- Clés enregistrées en même temps (deux vérifications qui finissent ensemble) : toutes sont gardées dans le fichier,
  l'une après l'autre ; aucune ne manque au lancement suivant.

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
- Retour en arrière : une valeur qu'une version ne sait pas lire (fournisseur, modèle, mode ou champ ajouté par une
  version plus récente) prend chez elle la valeur par défaut de ce seul réglage, mais reste enregistrée telle quelle
  tant qu'on ne change pas ce réglage ; la version plus récente la retrouve ensuite. Un réglage changé est écrit, et
  un réglage composé (format des dates, place de la bulle, ton selon l'app) garde ses champs inconnus.
- Bloc de réglages abîmé (tronqué, octet invalide, ou illisible en entier) : une copie est gardée de côté, jamais
  effacée ; chaque réglage encore entier garde sa valeur, seuls le réglage abîmé et ceux d'après une coupure prennent
  leur valeur par défaut, et l'app repart sans refaire le premier lancement guidé.
- Les clés API d'un fournisseur retiré restent dans le fichier de clés.
- Reprise depuis OpenFlow (une seule fois) : réglages, base, audios, journaux et fichier de clés, sans rien écraser
  de Wispad, pas même un bloc de réglages abîmé ; ce qui n'est pas repris reste en place.

## Version et mises à jour

- Bas de la barre latérale, au-dessus des raccourcis : un petit bandeau jaune « Une étoile sur GitHub »
  (« Star on GitHub » en anglais), sur une seule ligne et sans troncature à la largeur fixe de la barre, entièrement
  cliquable. Un clic ouvre la page du dépôt dans le navigateur, affiche « Merci ! » 1,6 s, puis le bandeau
  disparaît pour de bon (réglage `githubStarClicked`, enregistré dès le clic). Wispad ne peut pas savoir si
  l'étoile a été donnée : le clic suffit. Dessous, toujours visibles et sur une seule ligne : la version, l'état de
  la mise à jour juste à sa droite (« Wispad 0.2.3 ● À jour »), puis à droite les logos GitHub et X du développeur
  (profil GitHub `samirmedani`, compte X `@Mayuu_France`), qui ouvrent ces pages dans le navigateur ; leur nom et
  l'adresse s'affichent au survol. Trop long pour une ligne (build de développement en retard), l'état passe dessous.
- **Release ou build de développement** : une release est l'app du `Wispad.dmg` publié sur GitHub ; seul
  `scripts/release.sh` ajoute à son Info.plist la clé `WispadRelease` (vraie), avant de la signer. Sans cette clé,
  c'est un build de développement, compilé depuis les sources (Xcode, `scripts/build.sh`, `scripts/install.sh`). Une
  clé posée par le script de release plutôt que l'absence de signature Developer ID : explicite et testable, couverte
  par la signature de l'app, et un contributeur qui signe son build avec son propre certificat Developer ID reste un
  build de développement.
- **Release** : la version seule (« Wispad 0.1.1 »), puis « À jour », ou « 0.1.2 disponible » (un clic ouvre la
  fenêtre de mise à jour ; « Wispad 0.1.2 est disponible » au survol) et, dessous, le bouton « Mettre à jour », qui
  ouvre aussi cette fenêtre : l'installation
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
- **Rechercher une mise à jour** : la flèche ↻ à droite de l'état de la version (barre latérale) et Réglages › Aide ›
  Mises à jour lancent tout de suite la même requête ; la vérification automatique continue à son rythme. Une
  recherche à la fois, au plus une par minute (boutons grisés pendant la pause) ; limite de l'API atteinte : pas avant
  l'heure annoncée par GitHub (un quart d'heure sans indication, six heures au plus). Pendant la recherche, une roue ;
  puis, 4 s : « Wispad est à jour », « Nouvelle version trouvée » (la fenêtre de mise à jour s'ouvre sur les notes,
  sans rappel dans la bulle ensuite), « Recherche impossible : réessaie plus tard » ou « GitHub limite les
  recherches : réessaie plus tard ». Réglages › Aide › Mises à jour montre aussi la version installée, son état, et
  « Mettre à jour » quand une version plus récente est publiée.
- **Échecs silencieux** de la vérification automatique, sans message : hors ligne, délai dépassé ou GitHub en panne (5xx) → nouvel essai dans
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

Réglages › Aide › Aide et retours : une ligne d'explication (« Sur GitHub : seules les versions de
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

Réglages › Aide › Diagnostic exporte un JSON local : autorisations, raccourci, bulle, durées et API des 50 dernières
tentatives. Aucun texte dicté, audio, contexte, chemin ni clé. Rien n'est envoyé automatiquement.
