# Journal des modifications

Les versions publiées de Wispad, de la plus récente à la plus ancienne. Le fichier `Wispad.dmg` de chaque version
est sur la page [Releases](https://github.com/samirmedani/wispad/releases).

## 0.8.36 — 14 novembre 2026

Wispad 0.8.36 donne le même survol animé à toutes les petites icônes.

**Amélioré**
- **Survol animé partout** : dans l'Historique (copier, retranscrire, écouter, supprimer, détails), le lecteur audio, le Dictionnaire et les fenêtres, l'icône sous le pointeur s'éclaircit, grossit un peu et prend un rond, puis se tasse au clic. Le rond de la corbeille est rouge.

## 0.8.35 — 14 novembre 2026

Wispad 0.8.35 rend plus vivantes les icônes de la dernière dictée.

**Amélioré**
- **Copier et masquer réagissent au survol** : dans la carte de la barre latérale, l'icône sous le pointeur s'éclaircit, grossit un peu et prend un rond, puis se tasse au clic. L'icône copier est maintenant un vrai bouton.

## 0.8.34 — 14 novembre 2026

Wispad 0.8.34 découpe tes longues dictées en paragraphes.

**Nouveau**
- **Paragraphes automatiques**, activé par défaut (Réglages › Correction) : à partir d'une quarantaine de mots, la correction passe à la ligne à chaque changement d'idée. Dans un message, la salutation et la formule de fin vont à part. Les messages courts restent d'un seul bloc, et aucun mot ne change.

**Amélioré**
- **Paragraphes bien plus fiables** : avant, la consigne était trop discrète et une longue dictée sortait presque toujours d'un seul bloc.
- **« Structurer les listes »** ne s'occupe plus que des listes à puces et numérotées ; les paragraphes ont leur propre réglage.

## 0.8.33 — 14 novembre 2026

Wispad 0.8.33 montre les vrais logos des fournisseurs.

**Amélioré**
- **Logos officiels** de xAI, OpenAI, DeepSeek et TypeSafe, sur la couleur de leur marque, dans Fournisseurs (clés API, modèles, choix du modèle) à la place des pictogrammes génériques.

## 0.8.32 — 14 novembre 2026

Wispad 0.8.32 protège et rend plus pratique la dernière dictée de la barre latérale.

**Amélioré**
- **Floutée par défaut** : le texte de ta dernière dictée ne se lit qu'en passant la souris dessus.
- **Copier en un clic** : un clic sur la case, ou sur son icône, copie le texte ; une coche confirme la copie.
- **Croix pour la masquer** : elle disparaît tout de suite, la dictée suivante s'affichera de nouveau.

## 0.8.31 — 14 novembre 2026

Wispad 0.8.31 a une nouvelle barre latérale, plus calme et plus utile.

**Nouveau**
- **Carte de dictée** en haut : l'état de Wispad, un bouton micro pour dicter sans le raccourci, tes mots du jour avec les sept derniers jours, et ta dernière dictée (un clic ouvre l'Historique).
- **Sections rangées en trois groupes** : Dictée, Toi, Services. Chacune affiche son chiffre du moment : mots et dictées du jour, série de jours, suggestions du Dictionnaire à valider, état des fournisseurs, dépense des 30 derniers jours.
- **Dépense en bas** : ce que tes dictées ont coûté ces 30 derniers jours, face au prix d'un abonnement à Wispr Flow.

**Amélioré**
- Symboles plus sobres ; la section ouverte se repère à son trait de couleur.
- Les raccourcis ⌘1 à ⌘7 suivent l'ordre de la barre latérale. Le bouton d'apparence passe en bas, à côté des liens.

## 0.8.30 — 8 novembre 2026

- Historique : le bouton d'informations est aligné à la même place sur toutes les lignes.
- README : nouvelles captures de l'app, avec des données de démonstration.

## 0.8.29 — 8 novembre 2026

- Les sections de la barre latérale réagissent au survol avec un fond discret. La sélection native reste distincte.
- Les vignettes d’apparence, filtres du dictionnaire et réglages avancés des fournisseurs répondent aussi au survol.
- Le fond ne déplace aucun contenu et respecte le réglage Réduire les animations de macOS.

## 0.8.28 — 7 novembre 2026

- Les alertes et les messages restent au même endroit que le spectre, y compris après la mise à jour d’anciens réglages. Les positions séparées restent disponibles dans Réglages → Bulle et messages.
- Codex reçoit la demande d’accessibilité étendue. Si Wispad ne peut pas lire son champ et que le collage n’a certainement pas lu le presse-papiers, la carte de récupération apparaît.

## 0.8.27 — 7 novembre 2026

- Historique : les boutons apparaissent au survol sans faire bouger le texte ni changer les retours à la ligne.
- L’aperçu complet attend toujours une demi-seconde de survol. Sur macOS 15 et plus, le délai repart quand le défilement s’arrête.
- Les lignes réutilisent leurs mesures quand on revient dessus ; le contrôle de troncature ne met plus en page toute la dictée.

## 0.8.26 — 7 novembre 2026

- Les messages de dictée utilisent le Liquid Glass natif sur macOS 26, sans liseré ni reflet blanc ajouté par Wispad. Sur les macOS précédents et avec la transparence réduite, le fond reste mat.
- La carte « Texte prêt à copier » garde une petite icône et des boutons macOS compacts ; Copier suit la couleur d’accent du système.

## 0.8.25 — 7 novembre 2026

- Les messages et alertes suivent la position du spectre, sauf si tu leur as attribué leur propre emplacement dans Réglages → Bulle et messages.
- Les messages et leurs boutons adoptent des rectangles compacts à coins arrondis. Les cartes « Texte prêt à copier » occupent moins de place.
- L’évitement du champ de saisie devient optionnel par défaut. Les choix déjà enregistrés restent en place.

## 0.8.24 — 7 novembre 2026

- Quand aucun champ n’est actif, Wispad peut insérer la dictée dans un champ vide et visible de la fenêtre active, si le choix est clair. Il ne déplace pas le focus et n’envoie pas le message.
- Le réglage **Chercher un champ de saisie** est activé par défaut. Il se désactive dans **Réglages → Général**.

## 0.8.23 — 6 novembre 2026

Wispad 0.8.23 allège sa fenêtre, à la manière de Superwhisper.

**Amélioré**
- **Barre latérale épurée** : seulement les sections, puis un pied discret (étoile, version, liens).
- **Raccourcis sur l’Accueil** : une rangée de touches en bas de l’écran (mains libres, maintien, Maj pour envoyer, annuler, coller la dernière).
- **Titres plus légers** et cartes posées à plat, sans ombre.

## 0.8.22 — 6 novembre 2026

Wispad 0.8.22 colle ta dictée là où est ton curseur.

**Corrigé**
- **Plus de faux « Champ sécurisé »** : Wispad refusait parfois de coller dans Codex ou Chrome alors que tu étais dans un champ de message, juste parce qu’une app gardait la saisie protégée des mots de passe. Il ne refuse plus que dans un vrai champ de mot de passe.
- **Plus de texte perdu dans le vide** : une dictée finie alors qu’aucun champ n’était actif partait dans le vide ; maintenant la carte « Clique dans un champ » attend ton clic et le texte s’y écrit.
- **Le texte suit ton curseur** : si tu cliques dans un champ d’une autre app avant la fin de la dictée, le texte y va. Si tu as tapé au clavier entre-temps, il reste dans l’app de départ, pour ne pas écrire au milieu de ce que tu tapes.

## 0.8.21 — 6 novembre 2026

Wispad 0.8.21 rend l’historique plus calme et plus fluide.

**Amélioré**
- **Ouvrir une dictée au survol** : laisse ta souris une demi-seconde sur une dictée coupée pour l’afficher en entier. Un passage rapide n’ouvre rien et ne fait plus bouger la liste. La dictée se referme quand la souris s’en va ; « Afficher tout » la garde ouverte.
- **Plus de mots qui se chevauchent** : à l’ouverture, le texte reste en place et seule sa hauteur s’agrandit.
- **Défilement plus fluide** : chaque image de l’historique demande environ 20 % de calcul en moins, ce qui laisse tenir 120 images par seconde sur un écran ProMotion.

## 0.8.20 — 6 novembre 2026

Wispad 0.8.20 accorde ce que tu dis de toi.

**Nouveau**
- **Quand tu parles de toi** (Réglages › Mise en forme) : choisis Au féminin ou Au masculin, et Wispad écrit « je suis allée » ou « je suis allé », « je me suis trompée », « je suis seule »… L’oreille ne fait pas la différence, la transcription l’écrivait souvent au masculin.
- Seuls les mots qui se rapportent à toi et qui se prononcent pareil changent. Une phrase sur quelqu’un d’autre et le reste du texte ne bougent pas. Rien n’est analysé dans ta voix. Par défaut, c’est Comme entendu.

## 0.8.19 — 5 novembre 2026

Wispad 0.8.19 passe d’un écran à l’autre plus vite.

**Amélioré**
- **Changer de section** est environ deux fois plus rapide : chaque écran est gardé une fois ouvert, et les autres se préparent pendant que Wispad est au repos.
- Revenir sur un écran retrouve sa place (défilement, recherche).
- Consommation ne refait plus tous ses calculs à chaque affichage.
- Quand tu dictes dans une autre app, Wispad ne fait pas plus de travail qu’avant.

## 0.8.18 — 5 novembre 2026

Wispad 0.8.18 envoie ton message avec Maj.

**Nouveau**
- **Maj pour envoyer** : pendant que tu tiens fn, appuie sur Maj pour finir la dictée. Le texte se colle, puis Entrée l’envoie. En mains libres, Maj et fn ensemble font la même chose.
- Entrée ne part que si le texte est bien arrivé dans le champ et que tu n’as rien tapé ni cliqué entre-temps. Le réglage se coupe dans Réglages › Général.

## 0.8.17 — 5 novembre 2026

Wispad 0.8.17 ressemble enfin à une app Mac.

**Nouveau**
- **Barre latérale de macOS** : la liste des sections est celle du système, avec une pastille de couleur par section, comme dans Réglages Système.
- **Couleur de ton Mac** : sélections, liens, graphiques et boutons prennent la couleur d’accent choisie dans Réglages Système. Le rouge de Wispad reste pour la marque et pendant l’écoute.
- **Survol plus sobre** : les boutons ne grossissent plus au passage de la souris.
- **Icône de la barre des menus** : un petit point montre l’étape de la dictée (jaune au démarrage, bleu pendant la transcription, vert quand le texte est écrit, orange en cas d’erreur).

## 0.8.16 — 5 novembre 2026

Wispad 0.8.16 écrit ta dictée même quand le champ ignore le collage.

**Corrigé**
- **Champ qui refuse le collage** : quand une page ou une app ignore le collage de Wispad (par exemple certains champs de saisie dans Chrome), le texte n’attend plus derrière « Texte prêt ». Wispad l’écrit directement dans le champ, une seule fois, à condition que tu n’aies rien tapé et que tu sois toujours dans le même champ.

## 0.8.15 — 5 novembre 2026

Wispad 0.8.15 écrit là où tu cliques, même si tu lisais une page web en lançant la dictée.

**Corrigé**
- **Dictée lancée depuis une page web** : si tu commences à parler en lisant une page dans Chrome (ou dans une app comme Codex), sans être dans un champ, puis que tu cliques dans un champ d’une autre app, le texte s’y écrit. Avant, Wispad prenait la page pour un champ et gardait le texte avec « Collage impossible ».
- **Dictée finie sur la page** : Wispad ne colle plus dans le vide. La carte « Clique dans un champ » attend que tu cliques dans un vrai champ.

## 0.8.14 — 4 novembre 2026

Wispad 0.8.14 attend que tu choisisses où écrire.

**Nouveau**
- **Clique après avoir parlé** : si tu lances une dictée sans curseur dans un champ et que tu ne cliques dans le champ qu’après, Wispad affiche « Clique dans un champ : le texte s’y écrira ». Le texte s’y colle dès que tu cliques, tant que la carte est affichée.

## 0.8.13 — 3 novembre 2026

Wispad 0.8.13 nettoie ce qui faisait « oral » dans tes textes.

**Amélioré**
- **« S’te plaît » et « y’a »** : Wispad écrit maintenant « s’il te plaît » et « y a ».
- **Mots répétés** : les bégaiements disparaissent (« tu tu peux » → « tu peux », « c’est, c’est » → « c’est »). Les répétitions voulues restent, comme « non non », « vas-y, vas-y » ou « ça, ça sent l’arnaque ».

## 0.8.12 — 3 novembre 2026

Wispad 0.8.12 garde mieux tes mots et ta façon de parler.

**Corrigé**
- **Plus de mot remplacé à tort** : un mot qui a déjà un sens n’est plus changé pour un mot qui se prononce presque pareil, comme « en disant » devenu « en lisant ».
- **Tes questions restent les tiennes** : « Pourquoi on n’arrive pas ? » ne devient plus « Pourquoi n’arrive-t-on pas ? », et « c’est les » ne devient plus « ce sont les ».

## 0.8.11 — 3 novembre 2026

Wispad 0.8.11 n’écrit plus « m’créer » ni « j’pense ».

**Corrigé**
- **Élisions de l’oral** : « m’créer », « j’pense », « d’faire » ou « qu’tu » s’écrivent maintenant « me créer », « je pense », « de faire » et « que tu », même avec le ton détendu. « T’as », « t’es » et « y a » restent comme tu les dis.

## 0.8.10 — 2 novembre 2026

Wispad 0.8.10 n’invente plus de phrase quand il n’a presque rien entendu.

**Corrigé**
- **Plus de phrase inventée** : sur une dictée très courte ou peu audible, l’écoute en direct pouvait imaginer une phrase entière, comme « Je suis un peu fatigué. », et Wispad la collait. Une écoute qui n’a rien en commun avec l’enregistrement n’est plus utilisée.

## 0.8.9 — 2 novembre 2026

Wispad 0.8.9 colle plus vite quand tu finis ta phrase au dernier moment.

**Corrigé**
- **Fin de dictée plus rapide** : quand tes derniers mots arrivent juste après le relâchement de la touche, Wispad prépare leur correction tout de suite au lieu d’attendre la transcription complète. Environ une seconde de gagnée dans ce cas.
- **Virgules naturelles** : la ponctuation reste sobre, mais les virgules qui isolent « frère », « quoi » ou une interjection sont de retour (« Ah putain, la dinguerie, frère »).

## 0.8.8 — 2 novembre 2026

Wispad 0.8.8 tient mieux le coup quand macOS fait des siennes avec le micro.

**Corrigé**
- **Plus de gel à la fin d’une dictée** : Wispad n’attend plus que macOS ait rendu le micro pour envoyer ta dictée. Le 2 novembre, cette attente avait figé l’app 9 secondes avant qu’elle se ferme.
- **Ta dictée n’est plus perdue** : si Wispad se ferme de façon inattendue pendant ou juste après une dictée, son audio est retrouvé au lancement suivant et t’attend dans l’Historique, prêt à transcrire.

**Nouveau**
- **Relance automatique après un plantage** : Wispad revient tout seul en arrière-plan, sans fenêtre. Une bulle te le signale. Si tu le quittes toi-même, il reste fermé.

## 0.8.7 — 2 novembre 2026

Wispad 0.8.7 se met à jour sans te déranger.

**Corrigé**
- **Fin de mise à jour discrète** : l’icône de Wispad ne rebondit plus dans le Dock et la fenêtre des nouveautés ne s’ouvre plus. Une bulle confirme que la mise à jour est installée, et elle s’efface dès que tu commences à parler. Les nouveautés restent dans Réglages › Aide.

## 0.8.6 — 2 novembre 2026

Wispad 0.8.6 écrit comme tu parles, selon l’endroit où tu écris.

**Nouveau**
- **Ton selon le site** : dans ton navigateur, Wispad reconnaît le site au titre de la page. Sur X, LinkedIn, Reddit ou Bluesky, il passe en ton détendu ; sur Discord, WhatsApp ou Slack aussi ; sur Gmail ou Outlook, en ton soigné. Ton choix dans Réglages › Mise en forme › Ton selon l’app l’emporte toujours, avec une nouvelle catégorie « Réseaux sociaux ».

**Corrigé**
- **Tes mots restent les tiens** : « ouais » ne devient plus « oui », « grave dommage » ne devient plus « vraiment dommage », « j’en sais rien » reste « j’en sais rien ».
- **Ponctuation moins « rédigée »** : plus de virgule après « Du coup » ou « En vrai » quand tu l’as dit d’un trait, plus de point-virgule, plus de deux-points pour découper une phrase, et « mdr » en minuscules.
- **Ton détendu plus fidèle** : il garde « t’as », « faut », « y a » et les petits mots comme « bah » ou « genre ».

## 0.8.5 — 1er novembre 2026

Wispad 0.8.5 raccorde mieux ta dictée au texte déjà écrit et garde sa mise en forme.

**Corrigé**
- **Majuscule au milieu d’une phrase** : quand tu dictes après « Je pense que », ta dictée continue la phrase (« Je pense que demain, c’est mieux. ») au lieu de repartir avec une majuscule. En début de champ, de ligne ou après un point, la majuscule est bien là. Les noms propres et les sigles gardent la leur.
- **Reprise après un arrêt** : si tu t’arrêtes au milieu d’une phrase puis reprends, Wispad retire le point qu’il avait mis à la fin de la première partie et continue la phrase (« Je voulais te dire que demain on se voit. »).
- **Mise en forme perdue** : quand le texte que tu dictais était aussi affiché à l’écran, Wispad pouvait jeter toute la correction, paragraphes compris, pour un seul mot repris de l’écran. Il garde maintenant la mise en forme.

**Amélioré**
- **Raccord** : la correction voit ce qui précède le curseur et ajoute une virgule quand la phrase en demande une (« Bonjour Paul, je voulais te dire merci. »). Si la phrase continue après le curseur, ta dictée n’y met plus de point final.

## 0.8.4 — 1er novembre 2026

Wispad 0.8.4 affiche ton vrai crédit xAI.

**Corrigé**
- **Solde xAI** : avec la clé de gestion xAI, Consommation affichait le crédit sans retirer ce que tu avais consommé depuis le début du mois. xAI ne le déduit qu’à la facture mensuelle, vers le 10 du mois suivant. Le solde pouvait donc paraître presque deux fois trop élevé. Wispad affiche maintenant le crédit réellement disponible.

**Nouveau**
- **Détail du compte xAI**, sous le solde : nombre de jours de crédit restants au rythme des 30 derniers jours, consommation du mois en cours, dépense des 30 derniers jours par clé API et par service, et dernière recharge, avec la mention automatique ou manuelle. Ces montants viennent de la facturation xAI ; ce ne sont pas des estimations.

## 0.8.3 — 1er novembre 2026

Wispad 0.8.3 tranche mieux quand ses deux transcriptions se contredisent sur un mot.

**Corrigé**
- **« v. » au lieu de « vers »** : la transcription de l’enregistrement complet abrégeait « vers » en « v. » (« aller v. la gare »), et l’abréviation arrivait parfois jusque dans le texte collé. Wispad écrit « vers ».

**Amélioré**
- **Vote des écoutes** : quand la transcription de l’enregistrement complet contredit celle en direct sur un mot, et que la seconde écoute sur ton Mac l’a entendu comme le direct, Wispad garde ce mot (« des vices dans la boîte » → « des vis dans la boîte »). Avant, la correction faisait ce choix seule et se trompait parfois. Les noms, marques, termes techniques, mots anglais et nombres ne sont jamais touchés.
- **Plus rapide dans ces cas-là** : la correction préparée pendant que tu parlais sert telle quelle.
- **Qualité vérifiée** : le banc de dictées mesure aussi les mots mal entendus, sur une référence de ce qui a vraiment été dit.

## 0.8.2 — 31 octobre 2026

Wispad 0.8.2 ne coupe plus tes phrases à chaque pause, dès la transcription.

**Corrigé**
- **Pauses au milieu d’une phrase** : la transcription en direct posait un point à chaque pause, et un petit morceau comme « Ou pas. » ou « Sans le modifier. » restait seul. Il est maintenant recollé à sa phrase dès la transcription : le texte reste propre même quand la correction n’est pas disponible.

**Amélioré**
- **Qualité vérifiée** : chaque version qui touche au texte passe d’abord sur un banc de dictées, qui compare sa qualité, sa vitesse et son coût à la version précédente.

## 0.8.1 — 31 octobre 2026

Wispad 0.8.1 écrit tes phrases d’un seul tenant, même quand tu marques une pause en parlant.

**Corrigé**
- **Phrases coupées par une pause** : un morceau comme « Ou non. » ou « Où quand… » est rattaché à sa phrase au lieu de rester isolé : « … si la facture est payée ou non. »
- **« ou » et « où »** : « une appli où tu peux tout ranger » prend l’accent quand il désigne un lieu ou un moment.
- Comprend toutes les nouveautés de la 0.8.0.

## 0.8.0 — 31 octobre 2026

Wispad 0.8.0 est plus simple, plus clair et plus fluide.

**Nouveau**
- **Profil à ta façon** : le bouton « Personnaliser » masque les cartes que tu ne veux pas voir. Une carte masquée n'est pas calculée. « Ton cerveau » et « Sujets · IA » sont masqués par défaut ; tu peux les réafficher quand tu veux.
- **Sujets IA en images** : une illustration et deux lignes au lieu d'un bloc de texte.
- **Copier le diagnostic** en un clic, à côté de « Signaler un problème » (Réglages › Aide).
- **Enquêter avec ton agent IA** : un prompt à coller dans Codex ou Claude Code, qui cherche la cause sur ton Mac et prépare avec toi un ticket anonyme.
- **Derniers appels** : copie un appel, tout le tableau, ou exporte-le en CSV.

**Amélioré**
- **Profil** : il s'ouvre tout de suite, sans écran de chargement.
- **Consommation** : un résumé clair en tête et une carte « Relais de secours » qui explique ce qui s'est passé.
- **Fournisseurs** : une vue d'ensemble, des modèles choisis sur des cartes avec leur prix, et les réglages avancés rangés à part.
- **Dictionnaire** : une seule liste pour les mots et les expressions, « Tout ajouter » pour les suggestions, et il apprend aussi les noms que tu écris de plusieurs façons.
- **Fluidité** : les écrans s'ouvrent plus vite.

## 0.7.7 — 31 octobre 2026

Wispad 0.7.7 te montre toute l’installation d’une mise à jour, jusqu’au redémarrage.

- Les étapes Vérification, Installation et Redémarrage restent visibles un instant chacune, au lieu de passer d’un coup avant la fermeture.
- Après la relance, Wispad rouvre aussitôt la fenêtre de mise à jour là où elle s’était arrêtée. « Redémarrage » se coche, puis « Wispad 0.7.7 est installé. » s’affiche avec les nouveautés, même hors ligne.
- Comprend le retour à une version précédente de la 0.7.6, dans Réglages › Aide › Mises à jour.

## 0.7.6 — 31 octobre 2026

Wispad 0.7.6 te permet de revenir à une version précédente si une mise à jour pose problème.

- Dans Réglages › Aide › Mises à jour, « Revenir à une version précédente » propose les 5 dernières versions publiées. Tu choisis, tu confirmes, et Wispad installe cette version avec les mêmes vérifications qu'une mise à jour, puis redémarre.
- Tes réglages, tes clés et ton historique restent. La version que tu quittes reste proposée dans « Mettre à jour », pour revenir quand tu veux.
- Comprend les corrections de la 0.7.5 : le micro s'ouvre tout de suite après une mise à jour, même pendant que Wispad récupère tes clés.

## 0.7.5 — 31 octobre 2026

Wispad 0.7.5 corrige le démarrage qui suit une mise à jour.

- Juste après une mise à jour, le raccourci pouvait répondre « Coffre de secrets injoignable », puis ouvrir le micro avec 10 à 20 secondes de retard. La cause : macOS réenregistre la nouvelle version de Wispad, et le coffre de secrets restait injoignable une vingtaine de secondes.
- Désormais, le micro s'ouvre aussitôt pendant que Wispad récupère tes clés. Ta dictée est transcrite dès qu'elles arrivent, même si tu as déjà fini de parler.
- Le coffre est relu par essais courts et rapprochés : Wispad le retrouve dès qu'il répond.
- Comprend la seconde écoute sur le Mac de la 0.7.4 et le presse-papiers rendu après le collage de la 0.7.3.

## 0.7.4 — 31 octobre 2026

Wispad 0.7.4 ajoute une seconde écoute sur ton Mac pour rattraper les mots courants mal entendus.

- Pendant que tu parles, le moteur de dictée d'Apple écoute aussi, entièrement sur le Mac : rien ne part ailleurs et il n'y a rien à installer. Quand la transcription donne une phrase sans sens et que cette seconde écoute a entendu autre chose, la correction peut reprendre la bonne version (par exemple « il fait noir » au lieu de « il fait voir »).
- Les noms, marques, termes techniques et nombres restent ceux de la transcription.
- Même rapidité de correction. Sans macOS 26 ou sans le modèle d'Apple déjà installé, Wispad fonctionne comme avant.
- Comprend la correction de la 0.7.3 : ton presse-papiers revient juste après le collage.

## 0.7.3 — 31 octobre 2026

Wispad 0.7.3 rend ton presse-papiers juste après le collage.

- Après une dictée, Wispad remet ce que tu avais copié dès que l'app a reçu le texte. Avant, la dictée restait jusqu'à 1,5 s dans le presse-papiers : un ⌘V fait juste après recollait la dictée au lieu de ton lien.
- La dictée est marquée comme temporaire : les gestionnaires de presse-papiers ne la gardent plus dans leur historique.
- Comprend les corrections de la 0.7.2 : les dictées orales gardent leur correction au lieu d'être collées brutes.

## 0.7.2 — 31 octobre 2026

Wispad 0.7.2 rend la correction à tes dictées orales.

- Depuis la 0.6.9, Wispad jetait souvent toute la correction dès qu'elle retirait un faux départ, une répétition ou un « en gros » ; il collait alors le texte brut, « euh » compris. La correction est maintenant gardée.
- Si la correction retire par erreur un mot qui porte le sens (« pas », « vraiment », « dans ce cas »), ce mot reprend sa place au lieu de faire tout jeter.
- « mmh » est reconnu comme une hésitation.

## 0.7.1 — 30 octobre 2026

Wispad 0.7.1 corrige une coupure du micro pendant une dictée.

- Quand une autre app active le traitement de la voix sur le micro du Mac (page web, appel, vidéo), le spectre pouvait se figer et la suite de la dictée était perdue jusqu'à l'arrêt. Wispad continue désormais d'enregistrer ta voix pendant ce temps.
- Aucune limite de durée n'est en cause : les longues dictées ne sont pas coupées.

## 0.7.0 — 30 octobre 2026

Une dictée plus cohérente à l'écrit, fidèle à ta façon de parler.

**Amélioré**
- Le ton par défaut, désormais nommé « Naturel », demande un français écrit grammatical dans toute la dictée :
  négations certaines complètes, sujets impersonnels omis rétablis, nuances et incertitudes conservées.
- Le ton « Soigné » développe aussi les contractions familières ; le ton « Détendu » garde ses tournures orales.
  Les citations, le code et les adresses conservent leur contenu.
- Les phrases courtes correctement complétées ne sont plus rejetées comme des ajouts inventés. Cette autorisation
  reste limitée aux constructions reconnues : elle ne permet ni un détail ajouté ni une fin de phrase supprimée.
- Une finition locale complète les sujets impersonnels certains que le modèle aurait laissés à l'oral,
  aussi lorsqu'une correction anticipée reçoit les derniers mots du fichier. Le mode détendu reste préservé.
- Une reprise de quantité avec le même nom répété garde bien sa valeur finale, sans permettre la disparition
  d'un signe négatif ou d'un pourcentage.
- Ces améliorations partagent la correction existante, sans nouvel appel IA, changement de modèle ni attente
  volontaire supplémentaire avant le collage. Les protections des fins de voix et du collage sont conservées.

## 0.6.9 — 30 octobre 2026

Préserve les mots dictés et les fins de voix.

**Corrigé**
- Une correction ne peut plus supprimer un petit groupe de mots ordinaires au milieu d'une phrase. Les
  hésitations explicites, répétitions, reprises orales et commandes de mise en forme gardent leur traitement.
- Si la voix est encore présente au relâchement, le micro garde les derniers paquets avant de terminer le flux
  et le fichier, jusqu'au silence constaté et pendant 180 ms au maximum. Une pause déjà silencieuse n'ajoute
  aucune attente. Cela évite la fermeture immédiate en pleine syllabe, notamment sur les dictées très courtes.
- L'annulation reste immédiate et une nouvelle dictée attend seulement la fermeture du micro précédent,
  jamais sa transcription ou sa correction. Aucun appel IA ni modèle supplémentaire.

## 0.6.8 — 30 octobre 2026

Commence à parler, puis choisis où écrire.

**Corrigé**
- Une dictée commencée hors d'un champ peut maintenant rejoindre le champ choisi ensuite dans une autre app,
  pendant l'écoute ou la finition. Elle ne reste plus bloquée sur l'app du démarrage avec « Texte prêt à copier ».
  Les protections des champs sécurisés et des sélections sont conservées, sans correction ni attente supplémentaire.
- L'historique et l'apprentissage suivent l'app réellement choisie pour le collage.

## 0.6.7 — 30 octobre 2026

Moins d'attente quand le flux n'a pas encore terminé sa phrase.

**Amélioré**
- Avec la vérification audio, un partiel sans fin de phrase attend le texte final du flux : sa correction peut
  alors démarrer pendant que le fichier est encore attendu. Un segment déjà final ou ponctué garde son avance
  au relâchement, sans nouvelle série d'appels. La vérification audio et les garde-fous de fidélité sont conservés.

## 0.6.6 — 30 octobre 2026

Moins de corrections payantes, sans perdre l'avance d'une pause finale.

**Corrigé**
- Une pause finale peut de nouveau préparer le texte avant l'arrêt, pour que le collage retrouve son avance.
  Une seule anticipation est permise par dictée ; reprendre la parole ne lance pas de série de corrections.
  Le texte de l'arrêt peut être préparé s'il a changé, puis le fichier corrigé une dernière fois seulement s'il
  apporte encore un autre texte : trois corrections au plus, avec les mêmes vérifications audio et garde-fous.

- Une analyse du profil en échec ne se relance plus chaque minute. Les appels restent comptés même après un échec
  ou une annulation, et les lots ratés restent à relire.
- Un refus de paramètre ne répète plus une demande identique ; les nouvelles tentatives gardent leur attribution
  au fournisseur de secours sans multiplier les bascules.
- Un build local recherche aussi les versions publiées plus récentes. Un commit local inconnu de GitHub ne masque
  plus une mise à jour disponible.

## 0.6.4 — 29 octobre 2026

Un mot entendu ne se double plus.

**Corrigé**
- Quand les deux écoutes de Wispad entendent un petit mot différent, la correction pouvait garder les deux à la fois (« donne-le-lui » au lieu de « donne-lui »). Seul le mot entendu reste.

## 0.6.3 — 28 octobre 2026

Wispad n'écrit plus un petit mot que personne n'a dit.

**Corrigé**
- « Envoie-lui » ne devient plus « envoie-la ». Quand les deux écoutes de Wispad entendent un petit mot différent (« envoie-le » et « envoie-lui »), la correction pouvait en écrire un troisième pour accorder la phrase. Le texte garde maintenant l'un des mots entendus.

## 0.6.2 — 28 octobre 2026

La correction tranche quand les deux écoutes ne sont pas d'accord.

**Corrigé**
- « Prends un deuxième billet » ne devient plus « Prends 1/2 billet », ni « des mots » « des mope ». Wispad écoute ta voix deux fois, en direct et sur l'enregistrement complet. Quand les deux différaient d'un ou deux mots, il recopiait ceux de l'enregistrement complet sans que la correction les juge. Il ne le fait plus quand l'enregistrement met des chiffres à la place de mots, ou un mot qui n'existe pas à la place de vrais mots : la correction reçoit les deux écoutes et garde la bonne.
- « T'as » ne s'écrit plus « T as » : une apostrophe ne se perd plus quand les deux écoutes diffèrent sur ce mot.

## 0.6.1 — 28 octobre 2026

Les termes anglais dits avec l'accent français sont compris.

**Corrigé**
- Termes anglais entendus comme du français : dans une phrase sur les modèles d'IA, « habilitée RAID » devient « abliterated ». Quand des mots français ne veulent rien dire ensemble et que le sujet appelle un terme technique anglais qui sonne pareil, la correction l'écrit. Une phrase française qui a un sens garde ses mots (« les personnes habilitées », « un RAID 5 »).
- Mot de la page à la place de ce que tu as dit : la correction ne peut plus remplacer tes mots par un mot lu dans la fenêtre qui ne leur ressemble pas (« habilitée RAID » pouvait devenir « quantifiées »).
- « Tu vois » qui pose une question n'est plus retiré comme un tic de langage.

**Amélioré**
- La correction connaît le jargon de l'IA : abliterated, uncensored, LoRA, Ollama, Hugging Face, embeddings…

## 0.6.0 — 28 octobre 2026

Ta configuration te suit d'un appareil à l'autre, sans compte.

**Nouveau**
- Exporter la configuration : dans Réglages › Général, un fichier lisible qui dit quand il a été exporté, depuis quelle version et ce qu'il contient. Il garde tes réglages (voix, correction, mise en forme, raccourcis, sons, bulle, apparence) et ton dictionnaire, chaque mot avec son origine. Jamais tes clés API, ton historique ni ton audio.
- Importer une configuration : depuis Réglages, ou en ouvrant le fichier avec Wispad. Avant tout changement, Wispad montre ce qui changera, et tu choisis les réglages, le dictionnaire, ou les deux. Le micro, les clés et les réglages propres à ce Mac ne bougent pas.
- Configurer avec ton agent : copie un prompt pour Codex, Claude Code ou un autre agent. Il installe Wispad sur l'autre appareil, applique ta configuration, puis te demande tes clés.

## 0.5.1 — 28 octobre 2026

Un pourcentage dit ne perd plus son « % ».

**Corrigé**
- Pourcentage perdu : quand la correction gardait le nombre mais oubliait le « % » (« c'est fiable à cent pour cent » collé « c'est fiable à 100 »), Wispad le remet de lui-même : « c'est fiable à 100 % ». Les autres nombres de la phrase ne bougent pas.

## 0.5.0 — 25 octobre 2026

Tes clés où tu veux, un modèle local gratuit, et un cerveau qui se tient à jour.

**Nouveau**
- Clés depuis un serveur : dans Fournisseurs › Clés API, choisis « Serveur ou gestionnaire » et donne une commande (SSH vers ton serveur, 1Password, Doppler, Infisical, Bitwarden, curl…). Tester dit quelles clés sont trouvées, sans jamais les afficher ; rien n'est écrit sur ton Mac.
- Modèle local : branche Ollama, LM Studio ou tout serveur compatible OpenAI. Ses modèles corrigent tes dictées et lisent tes sujets, gratuitement, sans que le texte quitte ton Mac.
- Sujets à jour : « Mettre à jour » ne relit que les nouvelles dictées, pour presque rien. En option, la mise à jour se fait seule chaque semaine, avec son coût annoncé.
- Du cerveau à l'Historique : clique un mot ou un sujet, puis « Voir ses dictées » ouvre l'Historique filtré sur elles.

**Amélioré**
- Publication : si Apple met trop de temps à valider une version, elle est soumise à nouveau toute seule.

## 0.4.4 — 24 octobre 2026

Un coût minuscule ne s'affiche plus comme gratuit.

**Corrigé**
- Profil › Ton cerveau : un coût estimé sous 0,001 $ s'affiche « < 0,001 $ » au lieu de « ≈ 0,00 $ ».

**Amélioré**
- README : captures refaites sur la version actuelle (données de démonstration), avec le Profil et son cerveau par sujets.

## 0.4.3 — 24 octobre 2026

Ton cerveau comprend enfin de quoi tu parles.

**Nouveau**
- Cerveau par sujets : dans Profil, choisis « Sujets · IA ». Une IA relit tout ton historique avec ta clé de correction et en tire tes sujets concrets (un projet, une activité, un voyage), rangés en grandes catégories comme Code, Travail ou Voyages. Clique un sujet pour voir ses mots-clés.
- Coût annoncé avant tout appel : l'option est coupée par défaut. Tu vois les jetons et le coût estimés, puis tu lances l'analyse toi-même. Le résultat reste sur ton Mac et le coût réel s'affiche ensuite.
- Portrait écrit : une option de plus, avec son propre coût, pour trois phrases sur ce qui t'occupe.

**Amélioré**
- Cerveau par mots : les verbes et formules courantes (« passe », « d'accord », « utiliser », « vas-y »…) n'y apparaissent plus.

## 0.4.2 — 24 octobre 2026

Les sons de dictée se règlent au volume voulu.

**Nouveau**
- Volume des sons : dans Réglages › Général, un curseur pour les deux sons à la fois, puis un pour le son de début et un pour le son de fin, de 0 à 100 %. Le son se fait entendre au nouveau niveau dès que tu lâches le curseur.

## 0.4.1 — 24 octobre 2026

Les jours du Profil se lisent au survol.

**Amélioré**
- Profil › Tes jours : passe la souris sur une case pour voir tout de suite son jour et ses mots dictés (« vendredi 24 octobre · 1 240 mots »).

## 0.4.0 — 24 octobre 2026

Un Profil pour voir comment tu parles, et tous les modèles de tes clés pour corriger.

**Nouveau**
- Profil : tes chiffres (mots dictés, équivalent en pages ou en romans, temps gagné, séries de jours), ton rythme par heure et par jour, tes mots favoris, tes tics de langage et ce que Wispad corrige le plus. Tout est calculé sur ton Mac.
- Ton cerveau : tes mots fréquents en 3D, reliés quand tu les dis ensemble et colorés par sujet. Tu le fais tourner, tu zoomes, tu cliques un mot pour voir ses voisins. Un mot que tu ne veux pas voir se masque d'un clic droit.
- Tous les modèles de tes clés : la correction et son relais se choisissent parmi tous les modèles de texte de tes clés DeepSeek, OpenAI et xAI, dans un sous-menu par fournisseur rangé en rapides, équilibrés et lents, avec le coût estimé pour 100 dictées et la vitesse mesurée chez toi.

**Amélioré**
- Modèles sans réglage de raisonnement : Wispad ne leur envoie plus ce réglage, la correction ne fait plus de deuxième essai inutile.

## 0.3.6 — 23 octobre 2026

La fenêtre de mise à jour montre toutes les versions que tu as ratées.

**Amélioré**
- Notes prêtes d'avance : les notes des versions ratées sont chargées dès que Wispad trouve la mise à jour ; la fenêtre s'ouvre complète, même si GitHub ne répond plus.
- Toutes les versions ratées : jusqu'à 30, les 3 plus récentes dépliées, les autres derrière « Afficher les versions précédentes ».

**Corrigé**
- Mot coupé : quand tu parles vite et qu'il ne reste qu'une lettre (« v le bas »), la correction remet le mot (« vers le bas ») au lieu de laisser la lettre ou de bouleverser la phrase.

## 0.3.5 — 23 octobre 2026

La comparaison avec les abonnements reste visible sur toutes les périodes.

**Amélioré**
- Consommation › Coût par mois, face aux abonnements : aussi sur Aujourd'hui, 7 jours et 30 jours, au rythme de la période choisie (« Au rythme des 7 derniers jours »). Tout garde la moyenne sur tous tes jours d'utilisation.

## 0.3.4 — 23 octobre 2026

Le bas de la barre latérale tient sur une ligne, bien rangé.

**Amélioré**
- Version en une pastille : point de couleur, numéro, « À jour » et la recherche ↻ au bout, sur la même ligne que GitHub et X. Elle ne passe plus jamais sur deux lignes.
- Nouvelle version : la pastille passe en rouge avec « 0.3.4 → 0.3.5 », cliquable, et « Mettre à jour » apparaît dessous.

## 0.3.3 — 23 octobre 2026

La fenêtre de mise à jour devient claire : ce qui change, en rubriques, et ce que fait le clic.

**Nouveau**
- Fenêtre de mise à jour : l'accroche de la version en titre, puis une carte par version avec ses rubriques Nouveau, Corrigé et Amélioré. Chaque point a son titre en gras et son détail dessous.
- Versions sautées : si tu en as manqué, leurs notes sont là aussi, de la plus récente à la plus ancienne.
- Une phrase dit ce que fait « Mettre à jour » : téléchargement et sa taille, vérification de la signature, redémarrage, réglages gardés. Pendant l'installation, quatre étapes se cochent une à une.
- Réglages › Aide › Nouveautés de cette version : les notes de la version installée, dans la même fenêtre.

**Corrigé**
- Les notes n'affichent plus l'empreinte SHA-256 ni un vieux conseil de dépannage qui disait « déjà installée » pour la version proposée.

## 0.3.2 — 23 octobre 2026

La bulle de dictée se règle à ta taille.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.3.2 est déjà installée.

**Nouveau**
- Réglages › Bulle › Taille de la bulle : de 80 % à 160 %. Le spectre et les boutons des mains libres grandissent avec elle, les messages gardent leur taille. L'aperçu et la bulle affichée suivent le curseur.
- Une nouvelle installation commence toujours avec la bulle en Noir profond.

## 0.3.1 — 23 octobre 2026

Si tu sors du champ pendant que tu dictes, Wispad le voit et te garde le texte prêt.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.3.1 est déjà installée.

**Corrigé**
- Curseur sorti du champ pendant la dictée (un clic sur la conversation ou la page) : Wispad collait dans le vide sans rien dire. Il ne colle plus et affiche la carte « Texte prêt à copier · Le curseur a quitté le champ », avec Coller et Copier. Le texte est déjà copié.

## 0.3.0 — 23 octobre 2026

La bulle refaite : un vrai verre transparent, une ombre propre et un réglage du style qui montre la bulle en vrai.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.3.0 est déjà installée.

**Nouveau**
- Verre transparent : un verre sans aucun flou, dessiné par Wispad. Ce qu'il y a derrière la bulle reste net, sous un voile léger, un reflet et un liseré lumineux. Le verre « Transparent » d'Apple floutait autant que le dépoli sur macOS : c'est pour ça qu'il paraissait dépoli.
- Réglages › Bulle : trois cartes montrent la vraie bulle (Noir profond, Verre transparent, Verre dépoli) ; un clic suffit. Puis l'apparence du verre, sa densité et un grand aperçu avec les mains libres et un message.
- Sur le verre transparent, un fin halo garde le spectre, la croix et le carré lisibles sur n'importe quel fond, et les messages gardent un voile plus dense pour que leur texte se lise.

**Corrigé**
- L'ombre sous la bulle était coupée net par le bord de sa fenêtre, ce qui dessinait un rectangle sombre. Elle est plus douce et tient entière.

## 0.2.15 — 23 octobre 2026

Le relais de la voix et celui de la correction se choisissent, au lieu d'être décidés par Wispad.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.15 est déjà installée.

**Nouveau**
- Fournisseurs › Modèles, étape 1 : « Relais si xAI ne répond pas », un modèle de l'autre fournisseur ou « Aucun relais ».
- Étape 3 : le relais de la correction, n'importe quel modèle dont la clé est active, ou « Aucun relais ».
- Ton relais actuel est repris tel quel à la mise à jour, puis il ne change plus qu'à la main : couper une clé ne le remplace plus en douce, l'étape passe en orange.
- Prendre pour la voix le fournisseur du relais fait de l'ancien modèle de voix le relais.

## 0.2.14 — 23 octobre 2026

Fournisseurs montre les 4 étapes d'une dictée, numérotées, avec un modèle à choisir pour chacune.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.14 est déjà installée.

**Nouveau**
- Fournisseurs › Modèles : 1 Voix en direct, 2 Vérification, 3 Correction, 4 Mots appris. Chaque étape a son choix et une ligne qui dit ce qu'elle fait maintenant : modèle réel, relais, prix.
- Correction : « Automatique » comme avant, ou un modèle au choix parmi tes clés actives (DeepSeek deepseek-flash, OpenAI gpt-5.4-mini ou gpt-5.6-luna, xAI grok-4.7). Le modèle choisi passe en premier, l'ordre automatique reste son relais.
- Mots appris : « Comme la correction » ou Jev (TypeSafe), en un choix.
- Un modèle sans clé active ne se choisit pas, et l'étape passe en orange tant qu'il manque une clé.

**Corrigé**
- DeepSeek en pause passe bien en dernier, même derrière un autre modèle.

## 0.2.13 — 23 octobre 2026

Les clés API deviennent une liste simple : on colle, Wispad reconnaît le fournisseur.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.13 est déjà installée.

**Nouveau**
- Fournisseurs › Clés API : une ligne par clé, masquée (« xai-••••3f9a »), avec un interrupteur pour la couper sans la perdre et une corbeille pour la supprimer (clés enregistrées sur le Mac).
- « Ajouter une clé » : colle-la, son fournisseur s'affiche tout seul (xAI, OpenAI, DeepSeek), puis elle est vérifiée chez lui seul et enregistrée. Une clé TypeSafe demande juste de choisir le fournisseur. Une clé d'un service que Wispad n'utilise pas (Anthropic, OpenRouter…) est signalée.
- Le choix du fournisseur de voix indique ceux qui n'ont pas de clé active, et la section Correction affiche le service qui corrige maintenant.

**Corrigé**
- La clé de gestion xAI est maintenant vérifiée chez xAI avant d'être enregistrée.

## 0.2.12 — 23 octobre 2026

Un mot appris s'annonce en une ligne discrète.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.12 est déjà installée.

**Corrigé**
- L'ajout d'un mot au dictionnaire prenait une grande carte pendant 8 secondes. C'est maintenant une ligne de la taille de « Collé » : « « Figma » ajouté au dictionnaire », avec Voir et Retirer, pendant 5 secondes. Le pointeur sur la bulle arrête toujours le décompte.

## 0.2.11 — 22 octobre 2026

Une bulle en verre qui ressemble à du verre, et plus de dictées collées sans seconde correction.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.11 est déjà installée.

**Nouveau**
- Style Verre : la bulle de dictée passe à 40 points de haut, spectre et boutons agrandis d'autant, avec une ombre douce. La lentille et les reflets du Liquid Glass se voient enfin, comme sur iPhone. Le style Noir profond ne change pas.
- Réglages › Bulle et messages › Apparence du verre : Clair (par défaut, brillant, il laisse voir ce qu'il y a derrière, même une fenêtre sombre), Sombre (verre fumé) ou Comme l'app, le rendu d'avant.

**Plus rapide**
- Quand l'enregistrement complet entend un mot de plus ou de moins au milieu d'une phrase (« je ne sais pas » contre « je sais pas »), ce mot est ajouté ou retiré dans la correction déjà prête, sans seconde correction complète. Un mot présent plusieurs fois est maintenant situé grâce à ses voisins. Rejoué sur l'historique, ce raccourci sert à un tiers de dictées de plus ; chacune se colle environ 0,5 s plus tôt, jusqu'à 1,6 s pour les plus lentes.

## 0.2.10 — 19 octobre 2026

Jev, facultatif, est proposé à tous.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.10 est déjà installée.

**Nouveau**
- Fournisseurs › Clés facultatives propose à tous une clé TypeSafe. Avec elle, Jev donne le premier avis sur les mots à apprendre ; sans elle, le service de correction juge seul, comme avant.
- Sous les clés, une recommandation : xAI pour la voix, DeepSeek pour la correction, la moins chère, et Jev en option. Chaque service se remplace par un autre dont tu as la clé.

**Corrigé**
- Une clé TypeSafe est vérifiée avant d'être enregistrée : une clé refusée n'est plus gardée sans que tu le saches.

## 0.2.9 — 18 octobre 2026

Les petits nombres s'écrivent en lettres quand c'est plus naturel.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.9 est déjà installée.

**Nouveau**
- Nombres selon le contexte : « les deux premières barres », « trois fois », « il y a deux jours », mais « 5 secondes de latence », « 16 Go », « 12 serveurs » ou « entre 8 et 12 personnes ». Montants, mesures, dates, heures, versions et scores restent en chiffres. Pour tout garder en chiffres comme avant : Réglages › Mise en forme › Petits nombres › En chiffres.

## 0.2.8 — 18 octobre 2026

« Seconde » ne devient plus « 2ᵈᵉ ».

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.8 est déjà installée.

**Corrigé**
- La transcription écrivait certains mots en ordinaux : « 60 images par 2ᵈᵉ », « 5 2ᵈᵉˢ », « dans un 1ᵉʳ temps ». Wispad remet maintenant le mot dit : « seconde », « premier », « première », « deuxième »… Les dates gardent leur format (« le 1er mai »). Ces dictées se collent souvent plus vite : le flux et l'enregistrement complet ne se contredisent plus sur ces mots.

## 0.2.7 — 17 octobre 2026

Chaque dictée se colle un peu plus tôt.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.7 est déjà installée.

**Plus rapide**
- Fin de dictée : Wispad garde le texte final de la transcription dès qu'il arrive, sans attendre la confirmation qui suit 0,1 à 0,15 s plus tard. Le texte est le même qu'avant, et la correction démarre plus tôt.

## 0.2.6 — 17 octobre 2026

Un bouton pour chercher une mise à jour quand tu veux.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.6 est déjà installée.

**Nouveau**
- « Rechercher une mise à jour » : la flèche ↻ à droite de la version, en bas de la barre latérale, et Réglages › Aide › Mises à jour. Une nouvelle version s'ouvre aussitôt avec ses notes ; sinon, Wispad dit qu'il est à jour. Une recherche par minute au plus ; Wispad continue aussi de vérifier seul au lancement, puis toutes les 6 heures.

## 0.2.5 — 17 octobre 2026

Une bulle redessinée, en noir profond ou en verre transparent, des Réglages en onglets, et un dictionnaire qui
apprend seul les noms que la correction répare.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.5 est déjà installée.

**Nouveau**
- Bulle : messages redessinés en noir profond, sans contour. Une pastille de couleur dit de quoi il s'agit (erreur, collé, relais, nouvelle version, texte prêt, mots appris) et son anneau fait le décompte. Pointeur dessus, le décompte s'arrête et la pastille devient la ✕.
- Style Verre : toute la bulle, spectre compris, passe en Liquid Glass d'Apple. Réglages › Bulle propose les deux verres natifs, Transparent ou Dépoli, et leur intensité, avec un aperçu en direct.
- Réglages en sept onglets : Général, Dictée, Mise en forme, Bulle, Confidentialité, Autorisations et Aide. Plus besoin de tout faire défiler, et Wispad rouvre le dernier onglet.
- Dictionnaire : un nom que la correction répare dans au moins deux dictées est appris comme ceux que tu corriges à la main. Une carte Suggestions propose aussi d'ajouter ou de corriger des mots (Ajouter, Corriger, Ignorer), et chaque mot montre dans combien de dictées il sert et ce qui avait été entendu. Un crayon le renomme.
- Réglages › Dictée › Audio : « Réduire le bruit et l'écho du micro », pour parler loin du Mac ou dans une pièce qui résonne (désactivé par défaut).

**Corrigé**
- Collage : un champ de mot de passe resté actif dans une autre app (Chrome par exemple) faisait croire à un « Champ sécurisé » partout, et le texte n'était pas collé. Seule l'app où tu dictes compte maintenant.
- La carte « Texte prêt à copier » ne répète plus « le texte est prêt » : elle donne seulement la raison. Les messages de la bulle ne finissent plus par un point.

## 0.2.4 — 17 octobre 2026

Mode clair ou sombre, première dictée immédiate, et un collage qui ne rate plus quand une touche est tenue.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.4 est déjà installée.

**Nouveau**
- Apparence Système, Clair ou Sombre : un bouton en haut de la barre latérale, à droite de « Wispad », ou Réglages › Apparence. « Système » suit macOS ; la bulle de dictée reste sombre.
- Consommation › Bascules : « D'où venaient les échecs » sépare ta connexion, les fournisseurs et les clés refusées, puis donne pour chaque fournisseur, quel qu'il soit, ses causes (pas de réponse à temps, panne, limite atteinte, pas d'internet). Chaque dernière bascule dit aussi pourquoi le fournisseur principal a échoué.

**Corrigé**
- Première dictée après un lancement ou une mise à jour : la bulle pouvait rester figée jusqu'à 3 s avant que le micro s'ouvre, le temps qu'un service de macOS réponde. Wispad le prépare maintenant dès son lancement, sans ouvrir le micro.
- Collage : une touche ⌘, ⇧, ⌥, ⌃ ou fn tenue au moment de coller le faisait échouer. Wispad attend maintenant qu'elle soit relâchée, jusqu'à 5 s ; au-delà, la carte « Texte prêt » dit quelle touche était tenue et ne couvre plus le champ de saisie.

## 0.2.3 — 16 octobre 2026

Combien Wispad te coûte vraiment, face aux abonnements de dictée.

> Depuis la 0.2.0 : si la mise à jour reste sur « Relance… », ferme cette fenêtre, puis quitte Wispad et rouvre-le.
> La 0.2.3 est déjà installée.

**Nouveau**
- Consommation › Tout : ta dépense ramenée à un mois, taxe comprise, à côté de Wispr Flow Pro, Willow Voice Pro et Superwhisper Pro au même taux, avec l'économie par mois et par an.
- Un curseur « Taxes » règle ce taux (20 % par défaut, la TVA française) et affiche le pays au taux le plus proche, des Émirats (5 %) à la Finlande (25,5 %).
- Accueil et Consommation › Tout : depuis quand tu utilises Wispad, en jours, puis en mois et jours.
- Derniers appels : un vrai tableau, avec le fournisseur en couleur, le modèle, les jetons (dont ceux en cache), la durée et le coût. Les secours et les échecs sont bien visibles, et « Afficher plus » remonte plus loin.
- Bas de la barre latérale : la version et son état sur une seule ligne, avec les liens GitHub et X du développeur.

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
