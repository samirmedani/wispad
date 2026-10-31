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
  enregistrement ; au repos, il est remplacé par un neuf à la dictée suivante. Une autre app qui active le traitement
  de la voix sur le micro intégré (page web, appel, vidéo) le fait passer en plusieurs voies discrètes, que le mélange
  en mono rendait en zéros parfaits jusqu'à la fin de l'écoute : spectre figé, fin de dictée perdue. Quand ce mélange
  reste muet alors qu'une voie capte, Wispad garde la voie la plus forte ; la voix continue, plus faible, jusqu'à ce
  que l'autre app libère le micro et que le moteur reparte en voie unique. Aucun audio 1,5 s après le
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

- Verre fumé noir (Liquid Glass sur macOS 26+), ou verre transparent ou dépoli (voir « Style de la bulle »), au-dessus du
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
- **Style de la bulle** (Réglages › Bulle) : trois cartes montrent la vraie bulle sur une page claire et un fond
  coloré ; un clic la choisit, la bulle affichée change tout de suite. **Noir profond** (par défaut) : messages noirs
  avec un reflet doux sur le haut et une ombre, bulle de dictée en verre fumé noir de 30 points de haut ; lisible sur
  tous les fonds. **Verre transparent** : verre dessiné par Wispad, sans aucun flou ; ce qu'il y a derrière reste
  net, sous un voile léger, un reflet sur le haut, des bords intérieurs plus denses et un liseré lumineux. Le
  Glass.clear d'Apple n'est plus utilisé : sur macOS il floute autant que le dépoli (rayures fondues, fond sombre
  devenu gris laiteux, mesuré le 23 octobre 2026). Un fin halo (blanc en apparence claire, noir en sombre) garde le
  spectre, la vague de finalisation et les symboles ✕ / ■ lisibles sur un fond de leur couleur ; les messages gardent
  un voile plus dense (74 % à densité nulle) pour que leur texte se lise. **Verre dépoli** : Liquid Glass d'Apple
  (Glass.regular, macOS 26 ; matériau translucide avant), flouté. En verre, la bulle de dictée fait 40 points de
  haut, spectre et boutons agrandis d'autant. Ombre portée douce (26 %, flou de 12 points, 4 points plus bas),
  dessinée hors de la forme et jamais coupée : le panneau garde 32 points sous la bulle (10 avant la 0.3.0, d'où un
  rectangle sombre). Deux réglages de plus pour le verre : **Apparence du verre**, Clair (par défaut : voile blanc,
  reflets brillants, symboles foncés), Sombre (verre fumé, symboles clairs) ou Comme l'app ; et **Densité du verre**
  (25 % par défaut ; à zéro, le verre seul), qui épaissit le voile du verre transparent (de 5 à 50 % sur la bulle de
  dictée) ou teinte le dépoli (jusqu'à 70 %). Un grand aperçu sous ces réglages montre la bulle des mains libres et un
  message dans le style choisi ; il suit le curseur, comme la bulle affichée. La densité s'enregistre au relâchement
  du curseur. Un verre « Transparent » choisi avant la 0.3.0 devient ce verre sans flou.
- **Taille de la bulle** (Réglages › Bulle, sous les cartes) : de 80 % à 160 %, par pas de 10 % (100 % par défaut).
  La bulle de dictée, son spectre (en dessin net) et les boutons ✕ / ■ des mains libres grandissent ensemble ; les
  messages et les cartes gardent leur taille. La place réservée à la bulle (position, écart du champ de saisie, zone
  cliquable) suit la taille. À 160 %, la bulle des mains libres et son ombre tiennent encore dans le panneau. La
  bulle affichée et l'aperçu suivent le curseur ; la taille s'enregistre au relâchement. Une nouvelle installation
  commence en **Noir profond**, à 100 %.
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

## Profil

- Section Profil de la barre latérale, sous Historique : ce que les dictées conservées disent de la façon de parler.
  Tout est calculé sur ce Mac, à partir de l'historique, sans appel à un fournisseur. Période en haut à droite
  (Aujourd'hui, 7 jours, 30 jours, Tout ; Tout par défaut), retrouvée au lancement suivant.
- Chiffres clés : mots dictés, équivalent (« 15 pages » à 250 mots la page, « 2,3 romans » à 80 000 mots dès un
  demi-roman), temps économisé, mots par minute, série en cours (jours d'affilée jusqu'à aujourd'hui ou hier),
  meilleure série, jours actifs, plus longue dictée.
- Ton rythme : dictées par heure (24 barres) et par jour de la semaine, le pic en couleur vive (« Surtout vers 11 h,
  et le mercredi »). Tes jours : mots dictés par jour sur les 18 dernières semaines, en cases. Au survol d'une case, sans délai, sa date et
  ses mots s'affichent au-dessus de la grille (« vendredi 24 octobre · 1 240 mots », « Aucune dictée ») et la case est
  entourée.
- Ton cerveau : les 48 mots les plus fréquents (vus dans au moins deux dictées), en nuage 3D. Deux mots sont reliés
  quand ils reviennent dans les mêmes dictées (les 4 liens les plus forts de chaque mot, deux dictées communes au
  moins), et colorés par famille (propagation d'étiquettes sur les liens). Le placement est calculé (forces), le même
  à chaque calcul. Le nuage tourne lentement seul, sauf avec « Réduire les animations » ; glisser le tourne et arrête
  la rotation, pincer ou « + / − » zoome, la flèche recentre. Une étiquette qui en chevaucherait une autre n'est pas
  écrite. Cliquer un mot montre ses dictées et ses voisins (« Souvent avec »), cliquables, et éclaire ses liens.
- Cerveau par sujets (« Mots | Sujets · IA » en haut de la carte) : coupé par défaut. « Analyser mes sujets avec
  l'IA » l'allume ; la ligne dit avant tout appel combien de dictées seront relues, les jetons et le coût estimés
  avec le premier service de correction (« environ 9 k jetons, ≈ 0,002 $ avec DeepSeek deepseek-flash », « prix
  inconnu » sans tarif ; estimation prudente, 3,6 caractères par jeton). Rien n'est envoyé tant que « Lancer
  l'analyse · coût » n'est pas cliqué. L'IA relit tout l'historique (700 caractères au plus par dictée), par lots de
  36 000 caractères, trois lots à la fois, et rend des sujets concrets (projet, activité, thème), leur catégorie
  (Code, Travail, Voyages…), 3 à 5 mots-clés et les dictées qui en parlent ; mots vides, verbes, tics et données
  personnelles sont exclus par la consigne. Les sujets de même nom sont réunis. Le cerveau montre les 8 plus grandes
  catégories (gros nœuds cerclés, nom toujours écrit) et leurs 6 sujets principaux, reliés à leur catégorie et entre
  eux quand ils partagent deux dictées ; cliquer un sujet montre ses mots-clés. Progression « Lot 3 sur 12 » et
  « Arrêter » pendant l'analyse. Le résultat est gardé sur ce Mac (sujets et numéros de dictées, pas de texte) avec
  sa date, le nombre de dictées relues, le service, le coût réel et les dictées nouvelles depuis ; « Mettre à jour · N
  nouvelles dictées · coût » ne relit que les dictées arrivées depuis (sujets fusionnés, coût cumulé) ; « Tout relire ·
  coût » refait tout. « Mettre à jour chaque semaine » (coupé par défaut, coût d'une semaine type affiché : les
  dictées des 4 dernières semaines divisées par 4) lance seul cette mise à jour quand l'analyse a 7 jours et que des
  dictées sont arrivées, vérifié chaque minute ; jamais une première analyse. Les dictées supprimées sont oubliées
  des sujets. Après une tentative ratée ou interrompue, la prochaine relance automatique attend au moins 6 heures,
  puis 24 heures, puis 7 jours si les échecs se répètent. Cette échéance est enregistrée avant l'envoi et survit à
  une relance de l'app ; une mise à jour manuelle reste possible. Une annulation garde le créneau occupé jusqu'à la
  fin effective des requêtes : aucun chevauchement, aucun ancien résultat ne réapparaît après l'arrêt. Les lots
  réussis sont retenus par identifiant ; les lots ratés restent à relire, même s'ils précèdent un lot réussi.
  Avec un modèle local, le coût affiché est « gratuit ». Chaque appel compte dans Consommation dès son retour,
  même si l'analyse globale échoue ou est annulée. Couper l'interrupteur efface le résultat.
  « Écrire mon portrait » (sous le premier, coupé par défaut, avec son coût en plus) ajoute trois phrases sur ce qui
  occupe la personne, d'après ses sujets et ses chiffres. Sans clé de correction active, le lancement est remplacé par
  « Aucune clé de correction active ». Le cerveau s'ouvre sur les sujets quand l'analyse est allumée et faite.
- Historique d'un nœud : un mot, un sujet ou une catégorie choisi dans le cerveau propose « Voir ses N dictées ».
  L'Historique s'ouvre filtré sur elles, avec « Dictées de « … » · N dictées » et « Toutes les dictées » pour enlever
  le filtre ; la recherche s'applique dans le filtre. Quitter l'Historique enlève le filtre.
- Tes mots : les 40 mots les plus dits, taille selon la fréquence. Tes tics de langage : « euh », « genre »,
  « du coup », « tu vois »… comptés dans la transcription brute. Ce que Wispad corrige le plus : un mot entendu
  remplacé par un autre à la correction, vu au moins deux fois (« cloud → claude »). Langues : part des dictées
  surtout en français ou en anglais. Applications : les plus dictées.
- Ne sont jamais montrés : mots vides (articles, pronoms, liaisons, en français et en anglais), mots de moins de
  3 lettres ou de plus de 24, mots avec un chiffre, une adresse, un lien ou un signe (« @ », « / », « : »…).
  Clic droit sur un mot, ou « Masquer ce mot » dans le cerveau, le retire de tout le Profil ; les mots masqués sont
  listés en bas et se réaffichent d'un clic.

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
    Dock ou « Ouvrir Wispad » ; un raccourci de section ou un menu de section ouvre toujours la sienne.

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

- Configuration (Réglages › Général) : « Exporter… » écrit un fichier JSON lisible, le même pour toutes les plateformes
  (Wispad-configuration-AAAA-MM-JJ.json) : format et version, date et heure d'export, app, version et système
  d'origine, notes lisibles (contenu, ce qui n'est jamais inclus, comment l'importer), réglages et dictionnaire (chaque
  terme avec sa date d'ajout, son origine, son juge, ce qui avait été entendu). Jamais inclus : les clés API,
  l'historique et l'audio. Propres à l'appareil, ni exportés ni remplacés : le micro, l'ouverture à la connexion, les
  clés coupées, le modèle local, l'état du premier lancement et la navigation. « Importer… », un fichier ouvert avec
  Wispad (Finder › Ouvrir avec, ou « open -a Wispad fichier.json ») ou glissé sur son icône ouvre d'abord une fenêtre :
  provenance, nombre de réglages qui changeront, termes nouveaux (ceux déjà présents, à la casse près, ne sont pas
  doublés), chaque partie à cocher. Rien ne change avant « Importer ». Pendant le premier lancement guidé, cette
  fenêtre s'ouvre par-dessus le guide, qui reprend ensuite avec les réglages importés. Un réglage du fichier
  illisible ici (version plus récente, autre plateforme) garde sa valeur actuelle ; un champ inconnu est ignoré ; un
  fichier d'une version plus récente le dit. Un fichier qui n'est pas une configuration de Wispad le dit, rien ne
  change. Wispad est proposé pour ouvrir les JSON sans devenir leur app par défaut. « Copier le prompt » copie un
  texte pour un agent (Codex, Claude Code…) : installer Wispad, enregistrer la configuration qu'il contient, l'ouvrir
  avec Wispad, puis demander les clés API une par une sans les écrire dans un fichier, et vérifier les autorisations.
- Sons de dictée (Réglages › Général) : « Sons de début et de fin » les allume ou les coupe. Allumés, trois curseurs
  de 0 à 100 % par pas de 5 % : « Volume des sons » pour les deux à la fois, « Son de début » et « Son de fin » chacun
  (la fin vaut aussi pour l'annulation). Le son joué prend le général multiplié par le sien ; 100 % partout est le
  niveau d'origine. Au relâchement d'un curseur, le son concerné se joue au nouveau niveau. À 0 %, le son n'est pas
  joué et le son du Mac se coupe sans l'attendre.
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

Toujours chez un fournisseur, au choix dans Fournisseurs › Modèles (étape 1) : xAI `grok-voice-transcribe-2.0` (recommandé) ou OpenAI
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
  fichier, lancée aussitôt sans attendre 0,3 s une correction obsolète. Pas de report, et la correction complète
  choisit entre les deux écoutes vu la phrase, quand le fichier écrit en chiffres ce que le flux disait en lettres
  (« un deuxième billet » → « 1/2 billet »), met un mot que l'orthographe de macOS ne connaît pas dans la
  langue de la dictée à la place de mots qu'elle connaît (« des mots » → « des mope » ; dictionnaire et vocabulaire
  technique comptent comme connus), ou quand un mot à reporter est coupé par une apostrophe (« tu as » / « t'as »,
  qui donnait « t as ») ;
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

### Seconde écoute sur le Mac

Le fournisseur se trompe parfois sur des mots courants dits vite (« Faut voter développeur » pour « Si t'es
développeur »), et sa réécoute du fichier, faite par le même modèle, répète l'erreur. Pendant l'écoute, le même son
passe aussi par le moteur de dictée d'Apple, entièrement sur le Mac : rien ne part ailleurs, rien n'est demandé ni
téléchargé. Il ne sert qu'avec macOS 26 ou plus récent, une langue réglée sur français ou anglais, la correction
active et le modèle d'Apple déjà installé pour cette langue ; sinon Wispad dicte exactement comme avant.

- Le moteur d'Apple clôt ses phrases à chaque pause de 0,3 s ; au relâchement, la correction attend sa dernière
  phrase au plus 0,25 s (0,003 à 0,21 s mesuré), pendant la lecture du contexte. Il se ferme 10 s après l'arrêt, ou
  aussitôt si la dictée est annulée.
- Seule la transcription du fournisseur est corrigée et collée. La correction reçoit en plus les passages où la
  seconde écoute a entendu d'autres mots courants, une ligne par passage avec un mot de contexte de chaque côté, et
  la consigne de ne prendre la version de la seconde écoute que si celle de la transcription n'a pas de sens.
- Ne deviennent jamais un passage : un nom propre, une marque ou un terme technique de la transcription (capitale
  hors début de phrase, capitale intérieure, chiffre, mot du dictionnaire ou du vocabulaire technique, mot anglais
  inconnu en français comme « repo »), un nombre ou une unité, un simple accord (« fonctionne » / « fonctionnent »),
  des petits mots seuls, ni une version écrite avec un mot que l'orthographe de macOS ne connaît pas quand la
  transcription n'en a pas (« juriqueidique »). Au-delà de 8 passages, la seconde écoute a décroché : rien n'est
  donné. Un mot repris de la seconde écoute n'est pas une invention pour le garde-fou.
- La trace compte les passages donnés (« localPassages »), jamais leur texte.

Mesuré le 31 octobre 2026 sur de vraies dictées : sur 12 erreurs de sens du fournisseur, la correction en répare 7
avec ces passages (« Frérot, t'es développeur, si t'as un problème, tu codes », « des bails de bijoux », « Elle est
où la vidéo », « On regarde le rendu »), sans erreur ajoutée sur 32 dictées témoins ; même latence de correction,
coût de correction à peine plus élevé sur les seules dictées concernées.

## Correction

- Automatique : deux services au plus, DeepSeek (`deepseek-flash`, sans raisonnement) d'abord s'il a une clé.
  Voix chez xAI : relais OpenAI `gpt-5.4-mini` s'il a une clé, sinon le modèle de correction de xAI. Voix chez
  OpenAI : DeepSeek seul s'il a une clé, sinon le modèle de correction d'OpenAI. 2,5 s chacun, 4 s pour un service
  seul, plus 1 s par 800 caractères dictés. Au-delà, le texte transcrit est inséré tel quel (avec les seules
  commandes explicites de mise en page).
- Modèle au choix (Fournisseurs › Modèles, étape 3) : « Automatique · selon tes clés » par défaut, ou n'importe quel
  modèle de texte d'une clé active DeepSeek, OpenAI ou xAI. Le menu a une section par fournisseur : ses modèles
  recommandés (`deepseek-flash`, `gpt-5.4-mini`, `gpt-5.6-luna`, `grok-4.7`), puis « Tous les modèles … (N) », un sous-menu
  rangé en Rapides, Équilibrés et Lents. La liste vient du fournisseur (« /models »), lue quand la clé est active et
  relue au plus une fois par jour ; sans réponse, les modèles recommandés restent proposés, et le modèle choisi reste
  dans la liste même s'il en disparaît. En sont écartés les modèles qui ne rendent pas de texte de chat (voix,
  images, vidéo, embeddings, modération, recherche, code) et les versions datées d'un modèle qui existe sans date.
  Chaque ligne dit sa rapidité (« ≈ 0,92 s chez toi », médiane des corrections réussies de ce modèle, sinon « rapide »,
  « moyen » ou « lent » devinés sur son nom) et son coût estimé pour 100 corrections typiques (1 800 jetons en entrée,
  150 en sortie), ou « prix inconnu ». Ordre : recommandés, puis du plus rapide au plus lent, du moins cher au plus
  cher. Un modèle hors des quatre recommandés s'enregistre « compte/modèle » (« openai/gpt-4.1-mini »). Le réglage de
  raisonnement n'est envoyé qu'aux modèles qui l'acceptent (« none » pour GPT-5.1 et suivants, « minimal » pour
  GPT-5, « low » pour la série o et Grok hors « non-reasoning ») : un autre modèle n'a pas de requête refusée puis
  refaite. Le modèle choisi passe en premier avec la clé de son fournisseur. Choisir comme modèle le relais en cours
  remet le relais sur « Aucun relais ». Le
  modèle choisi passe en premier avec la clé de son fournisseur. Sa clé absente ou coupée, le premier de l'ordre
  automatique le remplace, et l'étape le dit en orange. Un choix illisible (version plus récente) se lit
  « Automatique », sans toucher aux autres réglages.
- Relais au choix (même étape) : un modèle dont la clé est active, autre que le service principal, ou « Aucun
  relais ». Deux services au plus, mêmes délais. Tant qu'aucun relais n'est choisi, le premier possible d'après
  l'ordre automatique (OpenAI `gpt-5.4-mini` derrière DeepSeek, par exemple) est enregistré comme choix dès que les
  clés le permettent, à la lecture des clés ou quand une clé est ajoutée ou rallumée. Ensuite, seul un choix à la
  main le change : relais dont la clé est coupée, pas de relais, et l'étape le dit en orange. Le juge des mots appris
  suit le même ordre.
- Pas d'autre service de correction : le serveur compatible OpenAI choisi par l'utilisateur (fonction retirée)
  repasse sur la correction automatique au lancement ; son adresse et son modèle sont effacés, ses anciens appels
  sortent de Consommation. Sa clé reste dans le fichier de clés, comme celle de tout fournisseur retiré.
- Consigne en français ou en anglais selon la langue de dictée (en automatique, devinée sur la transcription).
- Hésitations, bégaiements, faux départs et **autocorrections orales** retirés : « mardi, ah non, mercredi »
  devient « mercredi ». Un « non » qui fait partie du message reste.
- Nombres écrits en chiffres quand ils comptent vraiment quelque chose ; élisions purement orales écrites en entier
  (« j'sais » → « je sais »).
- **Français écrit naturel** : par défaut, la correction rétablit les négations certaines, y compris dans les
  subordonnées et avec les pronoms compléments, et complète les sujets impersonnels omis. Le vocabulaire, le sens,
  les nuances et les incertitudes restent ceux de la dictée. Un mot ambigu comme « plus » ne justifie jamais à lui
  seul l'ajout d'une négation. Les mots cités, le code et les adresses restent tels quels. Le ton « Soigné » développe
  aussi les contractions familières ; « Détendu » conserve les tournures orales et la négation sans « ne ».
  Ces règles partagent l'appel de correction existant : aucun appel ni délai d'attente supplémentaire.
  Le garde-fou admet les petits mots grammaticaux nécessaires dans les constructions reconnues ; il ne donne pas
  au modèle l'autorisation d'inventer un sujet, un nom ou une information.
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
  Un terme technique anglais dit avec l'accent français ressort souvent en mots français qui ne veulent rien dire
  ensemble : quand le sujet (la phrase, la conversation visible, les dictées précédentes) appelle un terme anglais qui
  se prononce presque pareil, la correction l'écrit, même hors du vocabulaire intégré : « habilitée RAID » → « abliterated »
  dans une phrase sur les modèles d'IA, « entraîner un l'aura » → « entraîner un LoRA ». Le terme
  doit sonner comme les mots transcrits, jamais un mot du contexte qui ne leur ressemble pas. Une phrase française
  qui a un sens garde ses mots (« les personnes habilitées », « un RAID 5 », « une aura incroyable »).
- **Tics et répétitions** : répétitions inutiles et tics répétés retirés (« par exemple, par exemple », « genre »,
  « en fait » ou « tu vois » répétés, « nan nan nan », mot doublé). Une occurrence reste quand elle porte le sens :
  « par exemple » qui introduit un vrai exemple, « ce genre de film », un « nan » qui répond, un « tu vois » qui pose
  une vraie question (« Tu vois le bouton rouge ? »). Rien d'autre n'est retiré à ce titre.
- **Citations** : paroles rapportées, mot donné en exemple, texte affiché, « si tu dis… », « tu mets… »,
  « genre… » : la citation va entre guillemets français (anglais : “ ”), les mots qui l'introduisent restent dehors
  (« si tu dis bonjour il répond » → Si tu dis « bonjour », il répond.). Un mot incompréhensible n'est jamais mis
  entre guillemets pour être gardé tel quel : il est corrigé comme un mot mal entendu, ou laissé sans guillemets.
  Seuls des guillemets qui enveloppent toute la réponse sont retirés ; « ces » ou « ses » garde les siens.
- **Lettres épelées** : regroupées en un seul mot épelé, en capitales séparées par des tirets (« C-E-S »), ou, si
  la phrase parle de ce mot, le mot entre guillemets (« ces »). Un mot de la phrase qui sonne comme une lettre est
  rattaché selon le sens (« c'est » et C, « t'es » et T, « elle » et L), une lettre répétée par erreur disparaît.
  Jamais de lettre isolée sans sens ; une lettre qui en a un reste (« vitamine C », « plan B »).
  Hors épellation, une lettre seule au milieu d'une phrase est lue comme un mot coupé par un débit rapide : la
  correction remet le mot que la phrase demande (« v le bas » → « vers le bas »). Un mot épelé entre guillemets
  s'écrit normalement (« vert », pas « VERT »).
- Banc réseau de ces règles, transcriptions brutes inventées passées directement à la correction (sans audio) :
  `BENCH_ONLY=h,r,g,l,e,d,n,k,j scripts/franglais-bench.sh <nom>` (mots mal entendus, tics, citations, lettres
  épelées, anglais, dates et heures, nombres mal entendus, mots coupés, termes anglais entendus comme des mots
  français, avec des phrases témoins qui doivent rester en français).
- La correction ne répond jamais au contenu dicté et ne recopie jamais le contexte.
- **Une seule préparation anticipée** : après un segment final du flux suivi de 0,25 seconde sans nouveau
  texte, Wispad peut préparer la correction. Les notifications identiques ne repoussent pas cette attente. Un
  nouveau mot avant la fin de l'attente annule seulement le timer : aucun texte périmé n'est envoyé.
- **Préparation à l'arrêt si nécessaire** : une préparation du même texte est réutilisée. Avec la vérification
  audio, un segment déjà annoncé final ou un texte terminé par « . », « ! » ou « ? » garde sa préparation immédiate.
  Sinon, Wispad attend le texte final du flux avant de préparer la correction, en parallèle du fichier encore
  attendu : le dernier partiel peut être tronqué. Si le fichier est déjà revenu, seul le texte retenu est corrigé.
  Une préparation réservée au relâchement empêche une autre préparation spéculative sur le flux final.
  Sans vérification audio, la préparation du dernier texte entendu au relâchement reste inchangée.
  Chaque préparation garde son texte source ; le fichier peut retrouver celle de la première pause même si une
  autre préparation tourne déjà sur le texte de fin. Ces indices ne contournent jamais le fichier ni les garde-fous.
- **Trois corrections au plus** : une anticipation à une pause, une préparation du flux final seulement si le texte
  a changé, puis une correction définitive uniquement si le fichier apporte encore un texte différent qui ne peut
  pas réutiliser une préparation. Une dictée inchangée après la pause ne paie qu'une seule correction. Chaque
  correction garde ses relais habituels en cas de panne. Le fichier, l'autre écoute, le contexte et les garde-fous
  de fidélité restent utilisés comme avant ; une correction obsolète ne retarde jamais la correction définitive.
  Une retouche locale sûre d'un ou deux mots peut encore réutiliser une correction prête. Tous les appels envoyés
  restent comptés, même devenus inutiles ou annulés après l'envoi. Échap annule le timer et les préparations ; couper
  la correction ou perdre la connexion empêche tout nouvel envoi. Si plusieurs longues pauses sont suivies d'une
  reprise, aucune nouvelle anticipation ne part : le budget reste borné, avec parfois moins d'avance que l'ancienne
  version qui payait une correction à chaque pause.
- **Refus de paramètre** : une réponse HTTP 400 n'est réessayée que si le paramètre facultatif de raisonnement
  effectivement envoyé peut être retiré. Les deux tentatives gardent leurs coûts propres et leur attribution au
  relais ; elles forment une seule bascule, avec l'issue de la dernière tentative.
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
- un groupe de un à trois mots porteurs de sens supprimé à l'intérieur de la phrase (négation, nuance,
  complément : « vraiment », « assez franchement », « dans ce cas », « pas ») : ces mots reprennent leur place dans
  la correction, juste après le mot qui les précédait, et le reste de la correction est gardé. Une réécriture
  normale reste telle quelle : hésitations (« euh », « mmh »), répétitions et faux départs (« les les mmh les », « des
  z, des zéros », « une petite, un un manteau »), marqueurs oraux (« en gros », « du coup », « genre »), mots
  grammaticaux, contractions développées (« t'as » → « tu as »), négation déplacée (« je pense pas qu'on a » → « je
  pense qu'on n'a pas »), conjonction remplacée par un point ou une virgule, proposition abandonnée (« Et je,
  est-ce que… »), mot corrigé à l'oreille juste à côté (« button » → « bouton ») et nombres mis en forme (« 12 pour
  100 » → « 12 % »). Une rectification perdue (« quatre vis, non, six vis » → « 4 vis ») ou un nombre retiré
  gardent la transcription. Une commande de ponctuation ou une liaison de liste ne s'efface que si sa mise en
  forme est réellement présente à cet endroit. Jusqu'en 0.7.1, tout mot de ce genre faisait coller la transcription
  brute, hésitations comprises : 27 corrections fidèles sur 31 dictées réelles du 30 et 31 octobre 2026 ;
- là où les deux écoutes diffèrent d'un seul petit mot (pronom, article, déterminant : « envoie-le » dans le fichier,
  « envoie-lui » en direct), un troisième que personne n'a entendu (« envoie-la », pour accorder la phrase) : le mot
  de l'autre écoute le remplace ; la fusion des deux (« envoie-la-lui ») garde le seul mot entendu. Seulement à une
  place que les mêmes voisins désignent sans ambiguïté ;
- un mot repris du contexte (page visible, texte voisin, dictées précédentes) à la place de mots dits qui ne lui
  ressemblent pas à l'oreille, d'au moins cinq lettres et absent de ce qui a été dit : les mots entendus sont remis
  (« habilitée RAID » ne devient pas « quantifiées », mot de la page). Une correction
  d'écoute confirmée par le contexte reste (« le mer » → « le maire », « v le bas » → « vers le bas ») ;
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

- Pourcentage perdu : un pourcentage dit (« cent pour cent », « 15 % », « fifteen percent ») dont la correction a
  gardé le nombre sans le « % » le retrouve (« fiable à 100 » → « fiable à 100 % »), au format choisi. Seulement quand
  chaque nombre en cause revient autant de fois dans la correction que dans ce qui a été dit : seule l'occurrence qui
  suivait « pour cent » reçoit le signe (« 100 € et fiable à 100 » → « 100 € et fiable à 100 % »). Un nombre changé,
  reformulé ou écrit en lettres laisse le texte tel quel ; « pour cent euros » n'est pas un pourcentage.
## Franglais technique

- Vocabulaire technique intégré (`TechVocabulary`) envoyé comme mots-clés à xAI après le dictionnaire et le
  contexte (100 au plus). La correction et le garde-fou reçoivent en plus le jargon de l'IA (abliterated, uncensored,
  LoRA, Ollama, Hugging Face, embeddings…), qui ne passe pas dans ces mots-clés.
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

- **Ton selon l'app** (Réglages › Mise en forme › Ton selon l'app) : par catégorie (e-mails, messageries, documents,
  notes, code et terminal, navigateur, autres apps), « Naturel » (par défaut : français écrit fluide, négations certaines
  rétablies et sujets impersonnels complétés), « Soigné » (développe aussi les contractions familières) ou « Détendu »
  (tournures orales et négation sans « ne » gardées, pas de point final pour un message court).
  L'ancien choix « Comme dicté » porte désormais le libellé « Naturel », sans changer les catégories réglées.
  Le ton ne change que le registre, jamais le vocabulaire ni le sens ; le garde-fou de fidélité s'applique toujours.
  Il utilise le même appel de correction, sans nouvelle passe ni attente supplémentaire.
  Après une correction réussie, une finition locale complète les sujets impersonnels certains restés omis, dans
  les tons Naturel et Soigné : formes de « falloir » et « y avoir » au début d'une proposition avec complément.
  Elle ne touche ni les citations, ni le code, ni les adresses, ni les fragments incomplets, ni une interrogation
  telle que « Que faut préparer ? ». Même finition après le report du fichier dans une correction anticipée.
  Un retour à la ligne, LF ou CRLF, clôt la recherche du complément : un fragment isolé avant la ligne suivante
  ne devient pas une phrase complétée. La recherche s'arrête au premier mot utile, même dans une longue dictée.
  Le repli sans réponse du correcteur reste brut. Une reprise de quantité autour d'un nom répété n'est acceptée
  que si la valeur finale figure réellement dans le texte rendu ; valeurs, signes et pourcentages sont comparés.
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
- Les termes retenus sont ajoutés, puis une ligne discrète les présente ensemble, comme « Collé » (« « Figma » ajouté
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
- Les noms écrits de plusieurs façons sont appris aussi : à la fin de chaque dictée, un nom écrit avec une
  majuscule (graphie marquée ou nom propre hors début de phrase) que les dictées des 90 derniers jours écrivent de
  plusieurs façons, chacune dans au moins deux dictées, dont une graphie marquée (« TestFlight » / « Testflight »),
  passe par le même juge avec sa graphie marquée la plus fréquente et l'autre écriture comme « entendu », puis la
  même bulle. Absent du dictionnaire, jamais refusé, trois au plus par dictée ; seules les dictées qui contiennent
  ces noms sont relues, hors du fil principal. Origine : « Écrit de plusieurs façons dans tes dictées ».
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

Le dictionnaire affiche par défaut les entrées les plus récentes en haut, dans tous les filtres. Les en-têtes
**Terme**, **Origine**, **Ajouté le** et **Dictées** trient la liste ; un second
clic inverse le sens, indiqué par une flèche. **Dictées** trie d'abord les plus dictées. Le choix reste mémorisé après relance. Le tri par origine groupe Par toi,
Automatique puis Avant le suivi (ou l'inverse), avec les plus récents en tête de chaque groupe. Il ne change ni
les données conservées ni l'ordre des termes transmis aux fournisseurs.

Écran Dictionnaire : une seule liste pour les mots, les noms et les expressions, dans une table Terme / Origine /
Ajouté le / Dictées ; une expression longue passe à la ligne dans sa colonne. Un seul champ d'ajout, qui grandit
avec le texte jusqu'à cinq lignes (Option-Retour pour une nouvelle ligne, Retour pour ajouter). Aucune limite de
longueur n'est ajoutée. Ajouter un terme remet les filtres à Tous / Toute période pour qu'il reste visible. La
recherche est temporaire ; origine et période sont mémorisées. Les filtres se croisent, avec un compteur de
résultats et un bouton de réinitialisation. (Les anciennes sections Mots et Expressions et phrases sont réunies ;
leur réglage `dictionaryKind` reste enregistré pour une version précédente.)

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

Avec au moins deux suggestions, **Tout ajouter** (en tête de la carte) les accepte toutes d'un coup, comme un clic sur
chacune.

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

- Voix : si le fournisseur de voix ne répond pas, le même enregistrement part chez le relais choisi dans Fournisseurs
  › Modèles (étape 1) : un modèle de l'autre fournisseur, ou « Aucun relais ». Après deux échecs, la dictée démarre
  directement chez le relais. Tant qu'aucun relais n'est choisi, le modèle recommandé de l'autre fournisseur est
  enregistré comme choix dès que sa clé est active. Un relais dont la clé est coupée ne sert pas, et l'étape le dit
  en orange. Prendre pour la voix le fournisseur du relais fait de l'ancien modèle de voix le relais.
- Correction : après deux échecs, DeepSeek passe après son relais, y compris quand il est choisi lui-même ; sans
  relais, il reste seul. Un service mis de côté est contrôlé chaque minute et repris dès qu'il répond, au plus tard
  après 30 minutes.
- Hors connexion, aucun échec n'est compté, aucun service mis de côté n'est contrôlé et aucune bascule n'est tentée :
  un service n'est mis de côté que pour ses propres échecs, et un relais ne travaille que s'il peut répondre.
- Le spectre passe au vert quand un relais travaille ; la première bascule d'une panne est annoncée.

## Reprise après erreur

- Fin d'écoute encore parlée : les derniers paquets micro continuent d'alimenter le flux et le fichier jusqu'à
  30 ms de silence observé, pendant 180 ms au maximum. Sans paquet récent ou après une pause déjà silencieuse,
  l'arrêt reste immédiat. La demande d'arrêt passe la bulle en traitement ; ses délais se mesurent dès le
  relâchement, y compris cette protection. Une annulation ou un arrêt forcé n'attend pas la fin de voix.
  Un nouveau geste coupe cette prolongation et attend seulement que ce micro soit fermé, jamais la transcription ou la correction
  précédente. Aucun enregistrement simultané sur le moteur partagé, aucun appel de correction ajouté.

- Erreur réseau, de clé ou de quota : l'audio reste dans l'historique ; **Retranscrire** puis **Copier**.
- Texte qui n'a pas pu être écrit : jamais en silence. La bulle le dit dans une carte « Texte prêt à copier »
  (titre de 14 points), avec sous le titre la seule raison (12 points) et des boutons de 30 points sur une ligne
  séparée, **Copier** en évidence et **Coller** : « Pas de champ où écrire » (focus sur une liste, un bouton, un
  menu, ou le bureau et les fenêtres du Finder, avant l'envoi), « Le texte n'est pas arrivé dans le champ » (champ
  lisible resté identique 1 s après ⌘V), « Le curseur a quitté le champ » (voir ci-dessous), « Accessibilité non
  autorisée » (accessibilité retirée dans Réglages
  Système, ou jamais donnée : ni ⌘V ni lecture du champ), « Collage impossible » (app cible fermée ou qui a perdu le
  premier plan, presse-papiers non modifiable, ⌘V non envoyé), « Champ sécurisé ». Le menu de Wispad et le bandeau
  de la fenêtre, sans ce titre, ajoutent « : le texte est prêt » (« Pas de champ où écrire : le texte est prêt »).
  Le texte est déjà copié, sauf pour un champ sécurisé. 12 s, avec un anneau qui se vide autour de la pastille
  orange (en pause au survol) ; ✕ au survol ou Échap la ferment. Elle ne prend jamais le focus : **Copier** remet le texte au
  presse-papiers et confirme « Copié » (1,5 s), **Coller** le colle dans le champ de l'app active (même collage que
  « Coller la dernière dictée »). Le collage garde tous les formats du presse-papiers précédent et refuse les champs
  sécurisés.
- Curseur sorti du champ pendant la dictée : elle a commencé dans un champ de texte reconnu (rôle de texte ou curseur
  de texte), et au moment de coller, le focus de la même app est sur un autre élément lisible qui n'en est pas un (la
  page, la conversation, un groupe). L'app expose ses champs, puisque celui du début a été lu : ce n'est pas un
  éditeur caché. Aucun ⌘V n'est envoyé (il partirait dans le vide sans que rien ne le prouve), la carte « Texte prêt
  à copier » dit « Le curseur a quitté le champ » ; **Coller** l'écrit là où le curseur est revenu. Un focus illisible
  (apps Electron qui n'exposent rien), une dictée commencée hors d'un champ ou le même élément qu'au début : le
  collage part comme avant.
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
- Dictée commencée dans un champ ou sur une sélection : si son app perd le premier plan, elle n'est pas réactivée
  de force ; la bulle propose de récupérer le texte.
- Dictée commencée sans champ de texte reconnu ni sélection : on peut ensuite placer le curseur dans une autre
  app, pendant l'écoute ou la finition. Le collage choisit alors l'app au premier plan et relit son champ avec les
  mêmes contrôles (accessibilité, champ sécurisé, touches relâchées). Une fois la destination choisie, un nouveau
  changement d'app pendant ces contrôles retient le collage. L'historique et l'apprentissage suivent la destination
  choisie. Un champ de texte ou une sélection présents au départ restent liés à leur app ; elle n'est jamais
  réactivée de force. Aucun appel de correction ni délai d'attente supplémentaire.
- Lectures d'accessibilité bornées au collage : champ actif 0,3 s avant ⌘V, confirmation 1 s après. Une app qui
  construit encore son arbre (Chrome à la première dictée) ne retarde ni le texte ni la dictée suivante.
  Le focus est relu pendant la confirmation, y compris si le composant web a recréé son champ. La valeur attendue
  après remplacement de la sélection est comparée au texte observé, en tolérant les transformations typographiques
  des éditeurs riches. Remplacer une sélection par le même texte demande aussi que le curseur se soit déplacé à sa
  fin. À défaut de sélection exploitable, le début du texte doit apparaître une fois de plus dans le même champ.
  Les lectures initiales réutilisent la valeur et la sélection déjà obtenues, sans les redemander plusieurs fois. Un collage non confirmé laisse sa cause dans le journal `insertion`, sans texte.
- Le spectre de traitement disparaît dès l'envoi de ⌘V. La confirmation continue sans bloquer l'affichage ; seul un
  échec avéré fait paraître la carte **Copier / Coller**. Collage confirmé : le presse-papiers précédent revient
  aussitôt. Sinon, il revient 0,15 s après que l'app a lu la dictée (fournie à la demande : Wispad voit cette
  lecture), sans attendre la confirmation ; un ⌘V fait juste après recolle bien ce que l'utilisateur avait copié.
  Une lecture faite avant ⌘V (service système) ne compte pas. Sans lecture, la dictée y reste au plus 1,5 s, car
  une app occupée (page web lourde, Electron) peut le lire tard ; le statut, lui, n'attend pas. La dictée posée au
  presse-papiers porte la marque org.nspasteboard.TransientType : les gestionnaires de presse-papiers ne la
  gardent pas dans leur historique. Le presse-papiers reste réservé jusqu'à sa restauration : les dictées
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
- Carte « Coût par mois, face aux abonnements », sur chaque période : la dépense de la période ramenée à un mois
  moyen (total ÷ jours × 30,44), taxe comprise, en dollars ; « ≥ » si des coûts sont inconnus. Jours comptés : un
  pour « Aujourd'hui » (« Au rythme d'aujourd'hui »), 7 ou 30 pour les derniers jours (« Au rythme des 7 derniers
  jours »), sans dépasser les jours d'utilisation (« Moyenne sur 12 jours d'utilisation » pour 30 jours après
  12 jours d'usage), tous les jours d'utilisation pour « Tout ». Sans appel sur la période, pas de carte. Barres
  comparées aux abonnements de dictée publics, au mois et hors taxes, relevés le 16 octobre 2026 :
  Wispr Flow Pro (15 $), Willow Voice Pro (15 $), Superwhisper Pro (8,49 $), chacun lié à sa page de tarifs, avec
  l'écart (« 7,8 fois plus cher ») quand il dépasse 10 %. Une phrase chiffre l'économie face à Wispr Flow Pro, par
  mois et par an (« jusqu'à » si des coûts sont inconnus), ou dit que Wispad revient plus cher à ce rythme. Moins de
  7 jours comptés : l'estimation est dite provisoire. Les prix à l'année sont rappelés en note.
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

- Où sont tes clés ? (en tête de Fournisseurs › Clés API) : « Sur ce Mac » (fichier de l'app) ou « Serveur ou
  gestionnaire » : une commande lancée dans un shell de connexion de l'utilisateur (son PATH : Homebrew, op…), où
  « {name} » devient le nom de la clé (WISPAD_XAI_API_KEY, WISPAD_OPENAI_API_KEY, WISPAD_DEEPSEEK_API_KEY,
  WISPAD_XAI_MANAGEMENT_KEY, TYPESAFE_API_KEY). « Modèles » propose SSH vers un serveur, 1Password, Doppler, Infisical,
  Bitwarden et une adresse web (curl). « Tester » lit chaque clé sans la choisir et dit lesquelles sont trouvées (« 3
  clés trouvées : xAI, OpenAI, DeepSeek »), jamais leur valeur ; « Utiliser cette source » n'est possible qu'après un
  test réussi de cette commande exacte. La source s'applique tout de suite, sans relance, et les clés sont relues à
  chaque lancement. Code 0 avec une valeur : clé trouvée ; code 0 vide ou code 1 : absente ; autre code ou plus de
  20 s : source injoignable (deux nouveaux essais). Rien n'est écrit sur ce Mac ; la source se lit seulement :
  « Ajouter une clé » est remplacé par « ajoute une clé dans ton serveur ou ton gestionnaire, puis recharge ». Revenir
  à « Sur ce Mac » relit le fichier. Un coffre configuré à part (WISPAD_SECRET_COMMAND ou wispad.secretCommand) garde
  la priorité : la ligne dit seulement « Clés lues dans ton coffre de secrets (outil) ».
- Modèle local (section sous Clés API) : Aucun, Ollama (http://localhost:11434/v1), LM Studio
  (http://localhost:1234/v1) ou une autre adresse compatible OpenAI, et un interrupteur. Wispad lit la liste de ses
  modèles (« 2 modèles : qwen2.5, llama3.2 », modèles d'embedding écartés) ou dit « Aucun serveur ne répond à … ».
  Ses modèles apparaissent dans le menu de la correction, section Local, « gratuit, sur ce Mac » ; ils servent aussi
  à l'analyse des sujets. Aucune clé ni réglage de raisonnement n'est envoyé ; délai de 15 s (chargement du modèle).
  Les appels comptent dans Consommation à 0 $ (« Modèle local · correction »). Repasser sur Aucun remet la correction
  en automatique si elle utilisait le modèle local.
- Fournisseurs › Clés API liste les clés enregistrées, une ligne par clé : fournisseur, rôle, clé masquée (son
  début connu, comme « xai- » ou « sk-proj- », et ses quatre derniers caractères : « xai-••••3f9a »), un interrupteur
  et, pour le fichier de l'app, une corbeille (après confirmation). Une clé coupée reste enregistrée mais n'est plus
  utilisée nulle part : voix, relais, correction, Jev, soldes. Choisir pour la voix un fournisseur dont la clé est
  coupée : la dictée dit « Ta clé … est coupée dans Fournisseurs » sans relire le coffre ni ouvrir le micro. Avec un
  coffre de secrets, pas de corbeille : une clé se supprime avec l'outil du coffre. Le choix coupé ou non est gardé
  dans les réglages (`disabledKeys`), jamais avec la clé ; supprimer une clé l'oublie.
- « Ajouter une clé » : on colle la clé, son fournisseur s'affiche aussitôt d'après sa forme, sans réseau. « xai- » :
  xAI ; « sk- » suivi de 32 caractères hexadécimaux : DeepSeek ; toute autre clé « sk- » (« sk-proj- »,
  « sk-svcacct- », anciennes clés) : OpenAI. « Bearer », guillemets et espaces autour sont retirés. Une clé
  Anthropic, OpenRouter, Groq, Google ou Hugging Face est nommée et refusée (Wispad ne s'en sert pas). Une clé sans
  forme reconnue (TypeSafe) demande seulement de choisir son fournisseur. La clé est vérifiée chez ce fournisseur
  seul, jamais envoyée à un autre pour essayer ; une clé xAI refusée comme clé d'API est essayée comme clé de gestion,
  toujours chez xAI. Vérifiée, elle est enregistrée, remplace l'ancienne clé de ce compte et devient active.
- Fournisseurs › Modèles montre les quatre étapes d'une dictée, numérotées dans leur ordre et reliées par un trait :
  1 Voix en direct (fournisseur et modèle dans un seul menu, groupé par xAI puis OpenAI, puis « Relais si xAI ne
  répond pas »), 2 Vérification (interrupteur ; même fournisseur que la voix), 3 Correction (« Automatique · selon
  tes clés » ou un modèle, l'interrupteur de la correction, puis son relais), 4 Mots appris (« Comme la correction »
  ou Jev, et l'interrupteur de l'apprentissage). Les interrupteurs sont ceux de Réglages. Un modèle dont la clé
  manque ou est coupée ne se choisit pas et le dit (« aucune clé », « clé coupée ») ; le relais de la correction ne
  peut pas être le service principal (« déjà en premier »). Sous chaque étape, une ligne dit ce qu'elle fait
  maintenant : prix en direct de la voix et de son relais, modèle et prix de l'enregistrement complet, services de
  correction réellement essayés (« Maintenant : DeepSeek deepseek-flash · relais : OpenAI gpt-5.4-mini »), juge des
  mots. Pastille
  rouge : l'étape travaille ; orange : elle ne peut pas comme choisi (clé absente ou coupée) ; grise : coupée.
  Choisir Jev allume la clé TypeSafe, « Comme la correction » la coupe (elle ne sert qu'aux mots appris).
- Fournisseurs recommande, sous les clés : xAI pour la voix, DeepSeek pour la correction (la moins chère), et Jev
  (TypeSafe), facultatif, pour les mots à apprendre. Chaque service se remplace par un autre dont on a la clé ; sans
  clé TypeSafe, le modèle de correction juge seul.
- Par défaut : fichier de l'app (`Application Support/Wispad/api-keys.json`, lisible par le seul utilisateur du Mac).
- Coffre de secrets, au choix : une commande qui répond à `get NOM` (valeur sur la sortie, code 1 si absente) et
  `put NOM` (valeur sur l'entrée), indiquée par `WISPAD_SECRET_COMMAND` ou
  `defaults write com.yatofix.wispad wispad.secretCommand /chemin/vers/commande`. Clés lues au lancement, gardées
  en mémoire, rien d'écrit sur le Mac. Chaque lecture dure 5 s au plus ; une clé que le coffre ne rend pas (connexion
  ratée ou restée sans réponse) est redemandée cinq fois (après 0,5, 1, 1,5, 2 puis 3 s) ; une clé absente ne l'est
  pas. Noms : `WISPAD_XAI_API_KEY`, `WISPAD_OPENAI_API_KEY`,
  `WISPAD_DEEPSEEK_API_KEY`, `WISPAD_XAI_MANAGEMENT_KEY`, `TYPESAFE_API_KEY`.
- Une dictée sans clé en mémoire relit les clés, ou rejoint la relecture déjà en cours (lancement, appui précédent),
  10 s au plus : un coffre qui ne répond plus est dit injoignable, sans ouvrir le micro, et le raccourci reste libre.
  La relecture continue seule ; l'appui suivant la rejoint au lieu d'en lancer une autre.
- Exception, la toute première lecture du coffre (lancement, relance après une mise à jour) : la clé n'est pas
  absente, elle arrive. Le micro s'ouvre aussitôt et écoute ; la transcription part dès l'arrivée des clés, en direct
  si l'écoute continue, sinon sur le fichier. Sans clés au bout de 40 s, la dictée s'arrête, dit pourquoi, et rien
  n'est envoyé. Le 31 octobre, juste après une mise à jour, macOS réenregistrait la nouvelle app pour le réseau
  local : le coffre lu par SSH sur le réseau de la maison est resté muet une vingtaine de secondes, le premier appui
  disait « coffre injoignable » et les suivants ouvraient le micro 13 à 18 s plus tard.
- Chaque clé de voix ou de correction (xAI, OpenAI, DeepSeek) est vérifiée chez le fournisseur avant d'être
  enregistrée, comme la clé TypeSafe (liste des modèles de Jev, gratuite) et la clé de gestion xAI
  (`management-api.x.ai/auth/management-keys/validation`). Une réponse 400, 401 ou 403 est un refus (« Clé refusée ») ;
  une autre réponse ou l'absence de réseau laisse la clé non vérifiée. Dans les deux cas, rien n'est enregistré.
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
  l'étoile a été donnée : le clic suffit. Dessous, toujours visibles et sur une seule ligne : une pastille de version,
  puis à droite les logos GitHub et X du développeur (profil GitHub `samirmedani`, compte X `@Mayuu_France`), qui
  ouvrent ces pages dans le navigateur ; leur nom et l'adresse s'affichent au survol. La pastille réunit un point de
  couleur, le numéro (le nom de l'app est déjà en haut de la barre), l'état et, au bout, la flèche ↻ de recherche :
  « ● 0.3.3 À jour ↻ » en vert ; « ● 0.3.3 → 0.3.4 » en rouge de l'app quand une version plus récente est publiée
  (cliquable, sans ↻) ; pour un build de développement, le commit et son retard, en orange s'il est en retard
  (cliquable). Trop étroite (grand texte), elle ne garde que le point et le numéro, l'état restant dans l'infobulle ;
  elle ne passe jamais sur deux lignes.
- **Release ou build de développement** : une release est l'app du `Wispad.dmg` publié sur GitHub ; seul
  `scripts/release.sh` ajoute à son Info.plist la clé `WispadRelease` (vraie), avant de la signer. Sans cette clé,
  c'est un build de développement, compilé depuis les sources (Xcode, `scripts/build.sh`, `scripts/install.sh`). Une
  clé posée par le script de release plutôt que l'absence de signature Developer ID : explicite et testable, couverte
  par la signature de l'app, et un contributeur qui signe son build avec son propre certificat Developer ID reste un
  build de développement.
- **Release** : la version seule (« 0.1.1 »), puis « À jour », ou « → 0.1.2 » (un clic ouvre la
  fenêtre de mise à jour ; « Wispad 0.1.2 est disponible » au survol) et, dessous, le bouton « Mettre à jour », qui
  ouvre aussi cette fenêtre : l'installation
  ne démarre qu'après lecture des notes, avec son bouton « Mettre à jour ». Le tag de la dernière release
  (« v0.1.2 ») et la version de l'app (`CFBundleShortVersionString`) se comparent en semver : X.Y.Z, une pré-version
  avant la version
  finale. Une app plus récente que la dernière release (release retirée) reste « À jour ».
- **Build de développement** : la version et le commit court gravé à la compilation (« 0.1.0 · abc1234 »),
  puis la release publiée plus récente si elle existe, même si le commit local est inconnu de GitHub. Sinon,
  « À jour » ou « N commits de retard » (« 1 commit de retard ») sur la branche `main` du dépôt public.
  Un clic sur le retard ouvre la page des commits. Le build local reste identifié comme tel ; son bouton de mise
  à jour ouvre la page GitHub, sans remplacer le build de développement automatiquement.
- **Vérification**, seul contact hors des fournisseurs : tous les builds lisent
  `GET https://api.github.com/repos/samirmedani/wispad/releases/latest`. Un build de développement consulte aussi
  `GET https://api.github.com/repos/samirmedani/wispad/compare/<commit>...main` (le retard est le champ `ahead_by`)
  si aucune release plus récente n'est proposée et que GitHub ne limite pas les recherches.
  API publique, sans clé ni cookie, avec l'en-tête User-Agent demandé par GitHub ; 5 s après le lancement, puis
  toutes les 6 heures, 8 s au plus par requête. Rien d'autre n'est envoyé (pour un build de développement, le commit de la
  version, dans l'adresse). Ni le démarrage ni la dictée n'attendent cette requête.
- **Rechercher une mise à jour** : la flèche ↻ au bout de la pastille de version (barre latérale) et Réglages › Aide ›
  Mises à jour lancent tout de suite la même recherche ; la vérification automatique continue à son rythme. Une
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
  sans aucune réponse lisible, seule la version s'affiche. Build de développement sans release plus récente à proposer :
  dépôt privé (404), commit inconnu
  (compilation locale non publiée) ou commit non gravé (git absent à la compilation) → seule la version.
- **Rappel discret** d'une nouvelle version, une seule fois par version, dans la bulle : « Wispad 0.1.2 est
  disponible », avec « Voir » (la fenêtre s'ouvre sur les notes de version) et « Ne plus me rappeler » ; ✕ au survol,
  départ seul après 10 s, décompte en pause au survol. Il attend que la bulle se libère après une dictée (ou après un
  autre message) : on est alors devant le Mac et on la regarde. Jamais pendant une dictée ni pendant la configuration
  guidée ; la bulle ne prend ni le focus ni le premier plan. Coupé par une dictée qui commence, il reparaît à la fin
  de celle-ci. Une version rappelée (réglage `updateRemindedVersion`) ne l'est plus jamais, même après une relance ;
  une version plus récente l'est à son tour. La barre latérale la propose toujours.
- **Fenêtre de mise à jour** : en tête, « Wispad 0.3.3 », une étiquette « Nouvelle version » et « Tu as la 0.3.2 »
  (« · 2 versions à rattraper » si d'autres sont sorties depuis). Dessous, l'accroche de la version (première phrase
  de ses notes) en titre, puis une carte par version à rattraper, de la plus récente à la plus ancienne (30 au plus,
  lues dès que la vérification automatique trouve la nouvelle version, sinon à l'ouverture ; sans réponse, la seule
  version disponible ; les 3 plus récentes dépliées, les autres derrière « Afficher les N versions précédentes ») : numéro, date de
  publication, accroche (sauf pour la plus récente), puis ses rubriques en couleur avec leur icône, **Nouveau**
  (rouge de l'app), **Corrigé** (orange), **Amélioré** (bleu), et leurs points : un point « titre : détail » montre
  le titre en gras et le détail dessous. Ce qui ne sert que sur GitHub n'y est pas : les citations (conseil pour une
  ancienne version) et l'empreinte SHA-256. Texte sélectionnable. En pied : ce que fait le clic (« Wispad télécharge
  cette version (8,6 Mo), vérifie qu'elle vient bien de son développeur, puis redémarre. Tes réglages, tes clés et
  ton historique restent. »), « Voir sur GitHub », « Plus tard » et « Mettre à jour ». Pendant l'installation :
  quatre étapes numérotées (Téléchargement, Vérification, Installation, Redémarrage), cochées en vert une fois
  faites, celle en cours en rouge ; dessous, son détail, sa progression, et « Annuler » tant que rien n'est
  remplacé. En cas d'échec : la raison, « Ouvrir la page de la release » et « Réessayer ».
- **Nouveautés de cette version** (Réglages › Aide › Mises à jour, « Voir les nouveautés ») : la même fenêtre pour la
  version installée, lue sur GitHub, avec l'étiquette « Installée » et sa date, sans installation (« Voir sur
  GitHub » et « Fermer »). Hors ligne ou pour une version non publiée : « Nouveautés indisponibles pour l'instant :
  vérifie ta connexion. »
- **Revenir à une version précédente** (Réglages › Aide › Mises à jour, version publiée seulement), si une mise à jour
  pose problème : « Choisir une version » liste les 5 dernières versions publiées avant celle qui tourne, avec leur
  date (lues sur GitHub à l'ouverture ; sans réponse, « Réessayer »). Le choix se confirme (« Revenir à la 0.7.4 ? »,
  avec ce qui reste : réglages, clés, historique), puis s'installe comme une mise à jour en un clic, avec les mêmes
  vérifications : disque de la release, taille et empreinte, signature Developer ID de la même équipe, jamais pendant
  une dictée. Le disque doit contenir exactement la version demandée, sinon « Le disque ne contient pas la version
  demandée : rien n'a été installé. » L'avancement s'affiche dans la ligne, avec « Annuler » tant que rien n'est
  remplacé. La version quittée n'est plus rappelée dans la bulle ; la barre latérale de la version précédente la
  propose toujours (« Mettre à jour »), pour revenir quand on veut. Les réglages qu'elle ne connaît pas sont gardés
  tels quels et retrouvés en revenant.
- Notes publiées (`scripts/release.sh`) : celles du CHANGELOG, telles quelles ; l'empreinte du disque n'y est plus
  ajoutée (GitHub l'affiche à côté du fichier, et l'app vérifie celle que l'API annonce).
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
     renommages, l'ancienne app remise en place si le second échoue) ;
  6. relance : « Redémarrage » s'affiche, puis l'ancienne version (dans la copie cachée) est effacée, la fenêtre de
     mise à jour se ferme (affichée en feuille, elle fait refuser, sans rien dire, la fermeture de l'app par macOS),
     et Wispad quitte ; une petite aide attend la fin de cette instance (60 s au plus), puis ouvre la nouvelle
     version. Fenêtre affichée avant la relance : la nouvelle version la rouvre aussitôt, sans attendre les clés,
     sur la fenêtre de mise à jour là où elle s'était arrêtée (« Redémarrage » en cours) ; l'étape se coche, puis
     « Wispad 0.1.2 est installé. », « Mise à jour depuis la 0.1.1 » (« Retour depuis… » après un retour en arrière)
     et les notes de version, lues dans ce que l'ancienne version a noté juste avant sa relance
     (`wispad.update.completion`, version et notes publiques, lu une seule fois, 10 min au plus), donc même hors
     ligne. Installée par une version qui ne notait rien encore (avant la 0.7.7) : les notes sont lues sur GitHub,
     sans la ligne « Mise à jour depuis… » ; sans réponse, la bulle seule. Fenêtre fermée : la bulle confirme
     « Wispad 0.1.2 est installé ». Si macOS refuse quand même de fermer Wispad (trois demandes, par exemple une
     autre feuille ouverte), Wispad s'arrête de force après avoir rangé comme à une fermeture normale (son du Mac
     rétabli, réglages écrits) : une fois ses fichiers remplacés, l'ancienne instance n'a plus accès au micro ni à
     l'accessibilité et ne peut plus dicter. L'aide ouvre alors la nouvelle version.

  Vérification, installation et redémarrage restent chacune affichées 0,6 s au moins : l'échange des noms est
  instantané, et sans cette pause les étapes 3 et 4 n'apparaissaient jamais avant la fermeture.

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
