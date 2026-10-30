# Journal des modifications

Les versions publiées de Wispad, de la plus récente à la plus ancienne. Le fichier `Wispad.dmg` de chaque version
est sur la page [Releases](https://github.com/samirmedani/wispad/releases).

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
