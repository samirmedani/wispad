# Journal des modifications

Les versions publiées de Wispad, de la plus récente à la plus ancienne. Le fichier `Wispad.dmg` de chaque version
est sur la page [Releases](https://github.com/samirmedani/wispad/releases).

## 0.2.2 — 15 octobre 2026

Une dictée ne peut plus être remplacée par un texte que tu n'as pas dit.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.2 est déjà installée.

**Corrigé**
- Quand la correction répondait à côté au lieu de corriger ta dictée (texte de la fenêtre recopié, réponse à ta question, traduction), Wispad collait cette réponse. C'est arrivé pendant une panne de DeepSeek, avec le fournisseur de secours. Wispad colle maintenant ce que tu as dit.
- Historique : la recherche trouve aussi une dictée par les mots que tu as vraiment dits, même quand le texte collé était différent.

## 0.2.1 — 15 octobre 2026

Corrige deux plantages de la 0.2.0, rend la mise à jour en un clic fiable et rend Wispad plus solide partout :
dictée, raccourci, réglages, réseau et mémoire.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.1 est déjà installée.

**Corrigé**
- Wispad pouvait se fermer brutalement : à la fin d'une dictée juste après son lancement (le texte n'était pas collé), ou en dictant pendant que sa propre fenêtre était au premier plan.
- Mise à jour en un clic : Wispad restait sur « Relance… », et la dictée ne marchait plus, car macOS refusait de le fermer tant que la fenêtre de mise à jour était ouverte. Il ferme maintenant cette fenêtre, puis se relance tout seul. Depuis la 0.2.0, si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le : la nouvelle version est déjà installée.
- « Mettre à jour » dans la barre latérale ouvre d'abord les notes de version ; l'installation se confirme dans cette fenêtre.
- « Relancer Wispad » (autorisations) ne peut plus rester sans effet quand une fenêtre bloque la fermeture.
- La mise à jour en un clic continuera de fonctionner quand macOS retirera `hdiutil attach`, signalé obsolète depuis macOS 27.
- Montants et unités : « 1,5 kilomètre par heure » devient « 1,5 km/h », « 15 kilowatt-hours » est reconnu, « payé 20 € 3 fois » et « $5m » restent justes. Dates en anglais : « on 3 May 8 people came » ne prend plus 8 pour le jour, « May 14/15 » reste tel quel.
- Une dictée ne devient plus jamais un collage vide, et un texte contenant un caractère invisible inhabituel est gardé en entier dans l'historique.
- Raccourci : un double appui suivi aussitôt d'Échap, ou une dictée annulée pendant qu'un autre geste attendait son tour, ne décale plus le raccourci (l'appui suivant n'est plus perdu) ; relâcher la touche ou Échap pendant un redémarrage du micro ne fige plus Wispad.
- Deux clés vérifiées au même moment (Fournisseurs, premier lancement) : la première n'est plus perdue au lancement suivant.
- Premier lancement guidé : plus aucune étape sans issue. Un micro muet, une clé xAI fausse, une clé refusée faute de crédit ou une touche jamais reçue s'expliquent, avec un bouton pour réessayer ; une étape réussie le reste quand la fenêtre est rouverte, et quitter Wispad sur l'écran de fin ne fait plus tout recommencer.

**Plus fiable**
- Une dictée ne reste plus bloquée : un micro qui ne redémarre pas est abandonné après 4 s, un micro débranché en pleine dictée sans autre micro arrête la dictée et colle ce qui a déjà été dit, et un coffre de secrets qui ne répond plus est signalé après 10 s.
- Le raccourci ne reste plus mort ni bloqué quand macOS a manqué un relâchement de touche (veille, écran verrouillé, champ de mot de passe), et enregistrer un nouveau raccourci ne lance plus de dictée.
- Hors connexion, une dictée ratée ne fait plus passer les suivantes chez le fournisseur de secours une fois la connexion revenue.
- Réglages et clés : un réglage lisible n'est jamais remplacé, même par une version plus ancienne ou après un fichier abîmé, dont la partie intacte est gardée.
- Wispad démarre même quand un autre programme tient la base de l'historique plus de 2 s (elle s'ouvre sans rien écrire), et le ménage des audios se fait en une seule écriture.
- Une mise à jour ne peut plus laisser Wispad à moitié remplacé : deux Wispad ouverts n'installent jamais en même temps, et les restes d'une installation interrompue sont effacés.
- Des réponses inattendues (nombre dit démesuré, compteurs de fournisseur énormes, sélection illisible) ne peuvent plus fermer Wispad.
- Écran externe branché ou débranché, autre résolution : la bulle, dictée en cours comprise, reprend aussitôt sa place, toujours entière sur un écran existant, et retrouve la place choisie quand son écran revient.
- Autorisation retirée dans Réglages Système pendant que Wispad tourne : rien ne reste bloqué, une dictée en cours s'arrête en collant ce qui a déjà été dit, et la bulle dit laquelle manque. Rendue, tout repart sans relancer Wispad.

**Plus rapide et plus sobre**
- Le traitement local du texte (franglais, garde-fou, contexte de la fenêtre, suivi des corrections) est environ 2,4 fois plus rapide.
- Wispad se réveille moins souvent au repos, et sa mémoire reste stable même ouvert pendant des jours.
- Les autorisations sont relues sans jamais faire attendre le clavier ni l'affichage : chaque question à macOS prend une dizaine de millisecondes.
- Une app lente ou figée ne peut plus retarder une dictée : les lectures qui attendent macOS, une autre app ou le disque ne prennent plus les fils partagés de Wispad.

## 0.2.0 — 13 octobre 2026

Wispad colle plus vite et plus sûrement, se met à jour tout seul et écrit tes nombres comme il faut.

**Nouveau**
- Mises à jour en un clic : quand une version sort, la barre latérale propose « Mettre à jour ». Wispad télécharge la version, vérifie sa signature Apple, la met à la place de l'ancienne et se relance. Réglages, clés, historique et dictionnaire restent.
- Montants, pourcentages et unités : « vingt-cinq euros » → « 25 € », « quinze pour cent » → « 15 % », « cinq kilomètres » → « 5 km », « mille cinq cents euros » → « 1 500 € ». Les numéros de téléphone s'écrivent par paires : « 06 12 34 56 78 ». Symboles ou toutes lettres, et séparateur des milliers, dans Réglages › Mise en forme.
- Dates et heures à ton format : « le vingt-quatre octobre deux mille vingt-six » → « 24/10/2026 », « à quatorze heures trente » → « à 14h30 » (ou « 14 h 30 », « 14:30 », « 2:30 PM »). Jamais d'année inventée, et une durée reste une durée.
- La bulle ne cache plus ton champ de saisie : ses messages se placent juste au-dessus. Dans Réglages › Bulle et messages, l'option se désactive, et chaque bulle (dictée, alertes de collage, messages) se place à la main sur un écran quadrillé, avec un aperçu.
- Dictionnaire refait : mots et expressions séparés, origine de chaque mot (ajouté par toi ou appris automatiquement, avec le modèle qui l'a jugé), tri par date, origine ou mot, filtres mémorisés. Les derniers ajouts sont en haut.
- « Aide et retours » dans Réglages et les menus : signaler un bug ou proposer une idée sur GitHub, avec la version déjà remplie.

**Plus rapide**
- La correction démarre dès l'arrêt, sur ce qui a déjà été entendu, au lieu d'attendre le texte final du flux : 0,3 à 0,5 s de moins sur une phrase courte.
- Quand la vérification sur l'enregistrement complet change un ou deux mots, ils sont reportés dans la correction déjà prête au lieu d'en attendre une nouvelle.
- Le spectre de chargement disparaît dès l'envoi du texte.

**Corrigé**
- Collage dans Chrome (ChatGPT et autres pages web) et dans les apps comme Codex : Wispad colle comme au clavier, et laisse le texte au presse-papiers le temps qu'une page lente le lise.
- Plus de message « collage non confirmé » à chaque dictée dans les apps qui ne montrent pas leur champ. La carte « Texte prêt à copier », plus lisible, n'apparaît qu'en cas d'échec réel.
- Mots appris : moins de faux ajouts ; plusieurs ajouts sont regroupés dans une seule bulle, avec « Annuler l'ajout ».
- « 2 mois et 1/2 » devient « 2 mois et demi » ; l'impératif et les homophones grammaticaux sont corrigés (« Écris à Julie »).
- Les mots repris de l'enregistrement complet gardent le format choisi (« 80 m² » ne redevient pas « 80 mètres carrés »).
- Une mise à jour interrompue ne laisse plus de copie de l'app derrière elle.

**Installer** : télécharge `Wispad.dmg`, glisse Wispad dans Applications. Une mise à jour garde tes réglages, clés, historique et dictionnaire.

macOS 14 ou plus récent, Mac Intel ou Apple Silicon. Signée et notarisée par Apple.

## 0.1.1 — 12 octobre 2026

Wispad corrige mieux ce que tu dictes.

- Un mot mal entendu qui rend la phrase absurde est remplacé par celui qui sonne pareil et a du sens.
- Les tics et répétitions inutiles disparaissent (« par exemple, par exemple », « nan nan nan »).
- Les mots ou phrases que tu cites passent entre guillemets.
- Les mots épelés sont regroupés au lieu de rester en lettres isolées.
- Formulaires « Signaler un bug » et « Proposer une idée » sur GitHub, et Discussions pour les questions et les suggestions.

## 0.1.0 — 12 octobre 2026

Première version téléchargeable de Wispad : dictée vocale pour macOS, signée et notarisée par Apple. Le premier
lancement guide les autorisations, le micro, le fournisseur, la touche de dictée et un essai.
