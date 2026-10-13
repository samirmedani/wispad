# Journal des modifications

Les versions publiées de Wispad, de la plus récente à la plus ancienne. Le fichier `Wispad.dmg` de chaque version
est sur la page [Releases](https://github.com/samirmedani/wispad/releases).

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
