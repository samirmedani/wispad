# Architecture

## Modules

| Module | Rôle | Dépend de |
| --- | --- | --- |
| `WispadCore` | Logique pure et testable : requêtes de transcription et de correction, consigne, garde-fou, format des dates et des heures (`DictationDateFormat`, `DateTimeWriter`), des nombres, montants et unités (`DictationNumberFormat`, `NumberWriter`), comparaison flux/fichier, historique SQLite, coûts, retard de la version sur `main` (`BuildFreshness`), adresses d'aide et de retour (`FeedbackLinks`), releases et mises à jour (`ReleaseUpdate`, `UpdateInstallRules`), progression du premier lancement guidé (`OnboardingFlow`), place de la bulle et zone de saisie à éviter (`OverlayPlacement`, `OverlayGeometry`). Aucun texte d'interface. | — |
| `Wispad` (app) | Coordinateur de dictée, raccourci, bulle, écrans SwiftUI, clés, traductions. | `WispadCore` |

Le projet Xcode (hors Git) est généré par xcodegen depuis `project.yml`. `Package.swift` décrit les mêmes
modules pour les tests (`swift test`), sans dépendance externe, l'app y devenant la cible `WispadApp`. La signature
de l'app se règle dans `Signing.local.xcconfig`, ignoré par Git ; `Signing.xcconfig` garde la signature locale par défaut (voir le README).

## Version et mises à jour

Une phase de compilation (`scripts/build-commit.sh`) grave le commit court du dépôt dans l'Info.plist de l'app
(clé `WispadBuildCommit`, absente si git ne répond pas). `scripts/release.sh` ajoute en plus, avant de signer, la clé
`WispadRelease` (vraie) : c'est elle qui fait une release (`BuildKind`, WispadCore) ; sans elle, l'app est un build de
développement. Une clé posée par le seul script de release plutôt que l'absence de signature Developer ID : explicite,
testée (`ReleaseScriptTests`), couverte par la signature de l'app, et indépendante du certificat d'un contributeur.

- **Affichage** : `BuildStatus` (app) lit la version, le commit et `BuildKind`, puis interroge l'API publique de GitHub
  en arrière-plan : `releases/latest` pour une release, `compare/<commit>...main` pour un build de développement.
  Lecture des réponses (`ReleaseCheck.result`, `BuildFreshnessCheck.freshness`), délais (`ReleaseCheck.delay`),
  versions (`SemanticVersion`) et choix de l'affichage (`UpdateDisplay.make`) sont dans WispadCore
  (`ReleaseUpdate.swift`, `BuildFreshness.swift`), testés par `ReleaseUpdateTests` et `BuildFreshnessTests`. La barre
  latérale (`ProjectFooter`) montre `BuildStatus.display` ; la lecture réseau est remplaçable (`fetchLatest`).
- **Rappel** : `BuildStatus.onAvailable` → `AppModel.noteAvailableRelease` (une fois par version : `UpdateReminder`,
  réglage `updateRemindedVersion`) → `DictationCoordinator.offerUpdate`. Comme une proposition de mot appris, la bulle
  le montre (`OverlayMode.update`) au prochain moment où elle se libère, jamais pendant une dictée.
- **Installation** : `UpdateInstaller` (`UpdateInstaller.swift`) enchaîne le téléchargement (`DiskImageDownload`,
  progression, taille et SHA-256), le montage (`hdiutil -nobrowse`), la vérification de la signature (`CodeSignature`,
  exigence `UpdateInstallRules.requirement` : Developer ID, même identifiant, même Team ID), la copie cachée à côté de
  l'app (`ditto`), l'attente de la fin de la dictée, l'échange atomique (`renamex_np`) puis la relance par une aide
  `/bin/sh`, le tout sous un verrou partagé par les instances de Wispad (`flock`, `UpdateTools.lock`). Toutes ses
  frontières passent par `UpdateSystem`, remplacé dans `UpdateInstallerTests` et `UpdateInterruptionTests` (disque
  simulé : l'app reste entière à chaque état, même Wispad tué) ; échange, verrou et aide réels sont testés dans
  `UpdateToolsTests`. Les règles (qui s'installe en place, signature exigée, chemins, sortie de `hdiutil`) sont dans
  `UpdateInstallRules` (WispadCore).
  Fenêtre de mise à jour et notes de version (`ReleaseNotes` découpe le markdown simple) : `UpdateViews.swift`.
- **Publier** : `scripts/release.sh` (en-tête : variables d'environnement, étapes). Rien de propre au mainteneur
  (équipe, certificat, clé de notarisation) n'est dans le dépôt.

« Aide et retours » : `HelpPage` (`HelpPages.swift`) donne les trois liens de Réglages (`HelpSection`), dont les
deux premiers servent aussi au menu de la barre (`StatusMenu`) et au menu Aide (`MainMenu.helpMenu`, actions du
délégué de l'app) ; chaque page s'ouvre avec `NSWorkspace.shared.open`. L'adresse du ticket de bug prérempli est
la fonction pure `FeedbackLinks.bugReportURL` (WispadCore, testée) : version et commit de `BuildStatus`, version de
macOS, rien d'autre, encodés pour l'adresse.

## Premier lancement guidé

`AppModel.onboarding` (un `OnboardingController`) remplace la fenêtre principale tant que `onboardingCompleted`
est faux, ou quand l'utilisateur rejoue la configuration depuis Réglages (`replayOnboarding`, sans rien effacer).

- **Décisions** : `OnboardingFlow.swift` (WispadCore, testé par `OnboardingFlowTests`) dit l'ordre des étapes,
  quand chacune est réussie (`PermissionsCheck`, `MicrophoneCheck` et `VoiceDetector`, `ProviderCheck` et
  `KeyCheck`, `ShortcutCheck`, `TrialCheck`), où « Plus tard » est permis et quelle étape règle un problème.
- **Bulle de l'accueil** : `BubbleDemo` reprend `SpectrumBars` et le verre de la bulle ; ses niveaux viennent de
  `SimulatedVoice` (WispadCore, fonction pure du temps, testée par `SimulatedVoiceTests`).
- **État vivant** : `OnboardingController` lit macOS par `OnboardingSystem` (autorisations sans demande, Réglages
  Système, relance, micros, vumètre), sondé toutes les 0,5 s pendant l'affichage (`poll`, arrêté par `suspend` quand
  la fenêtre se ferme, relancé par `resume`) ; les tests le remplacent (`OnboardingControllerTests`). Écrans dans
  `OnboardingView.swift`.
- **Micro** : `MicrophoneMeter` ne sort que des niveaux (rien d'écrit ni d'envoyé) ; le micro choisi
  (`microphoneUID`, `AudioInputDevices`) sert ensuite à `AudioCapture`, sans toucher au micro du système.
- **Touche** : pendant l'étape, `AppModel.shortcutProbe` reçoit les appuis à la place du coordinateur
  (`HotkeyMonitor` → `AppModel.shortcutReceived`) : aucune dictée ne démarre. Hors de l'étape « Touche », un test
  resté actif est rendu, et l'entrée dans l'essai l'arrête toujours.
- **Essai** : chaque trace terminée passe par `AppModel.noteCompletion` (issue et dictée, jamais de texte) ;
  l'essai réussit quand une dictée arrive dans son champ. Dictée visant Wispad lui-même : le coordinateur écrit
  le texte final directement dans le champ (`OnboardingController.receiveDictation`) au lieu de `TextInserter`.
  Geste reçu sans écoute (`TrialCheck.startGrace`) ou dictée bloquée (`TrialCheck.stallLimit`) : échec expliqué.
- **Relance** : l'étape courante est gardée dans `onboardingResume` ; `OnboardingFlow.resumeStep` la relit de façon
  tolérante.

## Parcours d'une dictée

1. `KeyboardTap` (fil dédié) reconnaît maintien, double appui ou Échap (`HotkeyLogic`) ; `HotkeyMonitor`, sur
   le fil principal, transmet ces effets au coordinateur.
2. `DictationCoordinator.begin` vérifie la clé du fournisseur de voix, lit l'app au premier plan et lance en
   parallèle la lecture du champ actif (`ContextProbe`) et, si la correction et le réglage le permettent, de la
   conversation visible (`WindowTextProbe`). Puis il affiche la bulle et ouvre le micro (`AudioCapture`).
   Le démarrage est surveillé : délai de `audio.start`, puis premier paquet attendu, un redémarrage sur un moteur
   neuf (même délai), puis abandon expliqué dans la bulle (règle `MicrophoneStartWatch`, WispadCore). `AudioCapture`
   relance aussi son moteur sur `AVAudioEngineConfigurationChange`, referme seul un démarrage ou un redémarrage
   abandonné (`abandonStart`, dans l'ordre de sa file) et signale une écoute qui ne peut plus repartir
   (`onInterruption`) : le coordinateur termine alors la dictée avec l'audio déjà reçu.
3. Le flux en direct (`LiveSpeechSession`) reçoit l'audio dès que le champ actif est lu (150 ms au plus), et
   l'audio est aussi enregistré ; à chaque pause, une correction est préparée (`DictationCoordinator+EarlyCorrection`).
4. `endCapture` ferme le micro ; un `FinishJob` termine la dictée en arrière-plan.
5. `DictationCoordinator+Transcription` choisit le texte retenu : flux, enregistrement complet
   (`TranscriptEquivalence`, mots du fichier reportés par `CorrectionPatch`) ou relais ; le fichier part chez le
   fournisseur (`BatchTranscriber`). À l'arrêt, `prepareCorrectionAtRelease` lance déjà la correction de ce que le
   flux a affiché ; la fin de dictée la prend si le texte final est équivalent. `FileLedger.completion` expose le fichier déjà revenu : dans ce cas, le choix
   précède la correction, sans appel spéculatif devenu inutile. Sans réponse, l'audio reste dans l'historique pour Retranscrire. Le texte passe par `FranglaisNormalizer` avant et après la correction.
6. `TextCleaner` corrige (consigne `CorrectionPrompt`, puis `FidelityGuard`, puis `DateTimeWriter`, puis
   `DictationStructure`) ; une consigne sur la sélection passe par `TextCleaner.transform`, sans garde-fou.
   `FidelityGuard` juge la ressemblance à l'oreille (homophones, lettres épelées, nombres) avec `PhoneticKey`, et
   reconnaît une date ou une heure réécrite à ses nombres (`MomentReading`) ; il retire une année non dite
   (`DateTimeWriter.removingUnspokenYears`). Le format choisi (`DictationDateFormat`, dans `CorrectionRequest.dateFormat`)
   donne ses exemples à la consigne, puis `DateTimeWriter.apply` l'impose aux dates et heures déjà en chiffres du
   texte retenu ; `NumberWriter.apply` fait de même pour les montants, pourcentages, mesures et téléphones
   (`CorrectionRequest.numberFormat`). Les raccourcis vocaux (`VoiceSnippets`) s'appliquent ensuite.
7. La dictée est enregistrée (`HistoryStore`), collée dans l'ordre (`TextInserter`, raccord `SmartJoin`), puis
   surveillée pour l'apprentissage (`CorrectionWatcher`, tri par `JevJudge` et `TermJudge` ; chaque mot retenu porte
   son juge, voir « Origine des mots du dictionnaire »). `TextInserter` envoie ⌘V au système (`pasteEvents`) puis
   relit le champ : confirmé (`inserted`), même champ lisible resté identique (`failed`), aucun champ
   (`FocusedFieldKind.notText`, `noTarget`) ou champ illisible (`pasteSent`, livré sans carte). Tout statut non
   livré passe par `DictationCoordinator.offerReadyText` : texte copié, bulle avec Copier et Coller
   (`readyMessage`). Après l'envoi, `InsertionSystem.locate` lit la zone de saisie (`ContextProbe.inputLocation`,
   règles `OverlayGeometry.inputZone`) dans `InputZoneTracker` ; `OverlayController.targetFrame` place chaque
   mode selon son rôle (`OverlayMode.role`, réglage `OverlayPlacement`) et décale les messages hors de cette zone. Les messages de la bulle partent seuls (`MessageTimer`, décompte
   `MessageCountdown` de WispadCore) ; `OverlayController` met ce décompte en pause pendant le survol
   (`DictationCoordinator.holdMessages`) et la ✕ appelle `closeMessage`.
   Le callback final de `AppDependencies.insert` signale ⌘V avant la relecture d'accessibilité :
   `FinishJob.pasteSent` retire le spectre lorsque seule la confirmation reste. Le job reste dans la file jusqu'à
   la restauration du presse-papiers ; une autre dictée en cours garde l'overlay. Un échec reconnu ensuite affiche
   toujours la récupération du texte. `LatencyMarks.pasteSent` sépare l'envoi du résultat final dans les traces.
8. Chaque appel facturable devient un `UsageEvent` ; la trace sans texte (`DictationTraceRecorder`) alimente le
   détail et le diagnostic.
   L'écran Consommation compte tous les appels enregistrés, filtrés par la seule période
   (`UsagePresentation.events`) ; les bascules vers un fournisseur de secours sont lues dans ces appels
   (`FallbackSummary`, textes de la carte dans `FallbackPresentation`).
   Une clé devenue inutile dans `app_metadata` est supprimée à l'ouverture de `HistoryStore`, jamais les appels.

## Origine des mots du dictionnaire

- **Données** (WispadCore) : `DictionaryEntry.origin` est un `DictionaryOrigin` : `user` (ajout à la main,
  `AppModel.addTerm`), `learned(DictionaryJudge)` (mot appris) ou `unknown` (avant le suivi). `DictionaryJudge`
  garde le type de juge (`jev`, `correctionModel`), le fournisseur et le modèle de l'appel qui a tranché.
  `confirmedAt` note le « Oui » de la bulle (`DictationCoordinator.acceptLearning` → `AppModel.confirmLearnedTerm`)
  sans changer l'origine.
- **Juge par mot** : `TermJudgement.kept` est une liste de `LearnedTerm` (mot et juge). `TermJudge.decide` attribue
  chaque mot : Jev pour une note nette ou quand le modèle de correction ne répond pas, le modèle de correction pour un
  cas douteux qu'il approuve. `TermJudge.askModel` rend la route qui a répondu (`ModelAnswer` : fournisseur et
  modèle de `TextCleaner.Route`) ; Jev, le modèle de son appel (`UsageEvent.model`, annoncé par TypeSafe). Aucune
  valeur fixe : le juge suit les clés et le fournisseur du moment.
- **Base** : table `dictionary`, colonnes `origin` (`user`, `jev`, `model` ; NULL : avant le suivi),
  `judge_provider`, `judge_model`, `confirmed_at`, ajoutées à une ancienne base à l'ouverture de `HistoryStore`.
  Lecture tolérante : une valeur inconnue ou un juge incomplet donnent `unknown`. `addTerm(_:origin:)` sans origine
  écrit `unknown`, jamais « ajouté par toi ».
- **Écran** : `DictionaryRow` / `DictionaryPhraseRow` affichent `OriginBadge` et `DictionaryOriginText`.
  `DictionaryKind` classe le texte sans changer la base. Section, origine et période sont dans `AppSettings` ;
  recherche éphémère, filtrage pur dans `DictionaryFilter.matchingEntries`.
- **Notification** : `DictationCoordinator` regroupe jusqu'à trois ajouts dans `learningOfferedTerms` ;
  `LearningNoticePill` les annonce avec Voir / Annuler l'ajout. Le panneau reste fixe, assez haut pour cette carte,
  tandis que les autres messages gardent leur pilule compacte. Une dictée suspend et remet en file le groupe.
- **Concurrence** : `AppModel.considerLearning` revalide les candidats après l'attente puis `learn` relit les
  refus et déduplique avant écriture. Couper l'apprentissage pendant le jugement empêche un ajout tardif.

## Coller la dernière dictée

- **Clavier** : `HotkeyConfig.paste` (nil si désactivé ou en cours d'enregistrement) ; `HotkeyLogic` reconnaît la
  combinaison avant le raccourci de dictée (`PasteShortcut.matches` : modificateurs exacts, jamais avec fn), l'avale
  et rend `HotkeyOutput.pasteLast`. `HotkeyMonitor` appelle `DictationCoordinator.pasteLastDictation`.
- **Choix et statut** : `PasteLastChoice` (WispadCore) choisit la dictée et dit si un nouveau collage améliore son
  statut ; le collage passe par `AppDependencies.insert` (`TextInserter`), après `modifiersReleased`, vers
  `AppDependencies.frontmostApp`.
- **Fin** : collé (`InsertionStatus.delivered`), il finit comme une dictée : `HistoryStore.updateDelivery` (statut
  et app cible), surveillance par le même `DictationCoordinator.watchCorrections` (règle
  `CorrectionWatch.shouldStart`, consigne lue dans la trace de la dictée) et « Collé » par `announce`.
- **Réglage** : `AppSettings.pasteLastShortcut` (`PasteShortcut`, lecture tolérante champ par champ, combinaison
  invalide → ⌃⌥V via `PasteShortcut.restored`). `PasteShortcutRules.problem` refuse une combinaison (raisons sans
  texte, écrites par `PasteShortcutText`) ; les raccourcis de macOS viennent de `SystemShortcuts`
  (`CopySymbolicHotKeys`, via `AppDependencies.systemShortcuts`). L'enregistreur (`AppModel.recordPasteShortcut`,
  vue `PasteShortcutRow`) écoute les frappes de la fenêtre avec un moniteur local, le temps d'un enregistrement.

## Raccourcis dessinés

`ShortcutKeyViews.swift` : `ShortcutKeys` traduit un raccourci (dictée ou collage) en touches `ShortcutKey`
(symbole, nom, code de touche) ; `ShortcutKeyCaps` les dessine en touches compactes séparées par « + »
(`compact` : symboles seuls), `ShortcutRecordingField` les remplace pendant un enregistrement, `MacKeyboardDiagram`
allume leurs codes sur le clavier de MacBook décrit par `MacKeyboardLayout` (unités de touche, codes de macOS,
testé par `ShortcutKeysTests`). Inscriptions des lettres et chiffres : `KeyboardLayout.characters` (disposition
active). Les deux rangées de Réglages › Raccourci sont des `ShortcutRow` (`SettingsRows.swift`) : libellé à
gauche ; ⓘ (popover avec le schéma), touches et boutons à droite, sur une ligne ; un `ViewThatFits` réduit les
boutons, puis les touches, plutôt que de passer à la ligne.

Toutes les frontières du système (micro, réseau, clés, collage, son) passent par
`AppDependencies` : les tests les remplacent et n'ouvrent jamais le vrai micro ni le vrai réseau.

## Écran Historique

`HistoryView` (`HistoryViews.swift`) affiche `AppModel.history` dans une pile paresseuse (`LazyVStack`), une section
par jour (`DayGroup`, titre calculé au regroupement) et une ligne par dictée, identifiée par son `id`. Rien de ce que
le défilement fait passer à l'écran ne doit être recalculé :

- **Modèle de ligne** : `HistoryRowItem` (`HistoryRowModel.swift`) précalcule heure, libellé « app · N mots ·
  fournisseur », statut et présence d'audio ; `HistoryRowCache.shared` le garde par dictée tant qu'elle ne change pas.
- **Troncature** : un texte long ou sur plusieurs lignes est mesuré une fois (copie cachée sans limite de lignes,
  lue dans la même passe que le texte affiché) ; le résultat est gardé par dictée, texte et largeur, et la copie
  cachée disparaît. Une ligne qui revient à l'écran ne remesure rien.
- **Icônes** : `AppIcons` garde chaque icône d'app, y compris l'absence d'app, déjà réduite à sa taille d'affichage.
- **Survol** : état local de la ligne ; pas de masque par ligne, le fond de carte et le fond de survol ont sa forme.
- **Recherche** : appliquée 150 ms après la dernière frappe (`appliedQuery`), tout de suite quand on l'efface.

Ces caches sont en mémoire seulement, bornés, et vidés avec l'app. `HistoryRenderingObserver` permet aux tests et à
la sonde de compter les lignes évaluées.

## Ajouter…

**Un fournisseur de correction** : une route dans `TextCleaner.routes`, un cas `UsageAPI`, son tarif dans
`Pricing.tokenRate`, son libellé dans `Presentation.swift`, une clé dans `APIKeys.accounts`.

**Un fournisseur de voix** : un cas `ProviderID` (catalogue et modèles dans `Catalog.swift`), le flux dans
`LiveSpeechSession`, le fichier dans `BatchTranscriber`, les coûts dans `UsageAPI` et `ProviderCatalog`.

**Un réglage** : une propriété dans `AppSettings` (`AppSettings.swift`) avec sa lecture tolérante dans
`init(from:)` (un réglage composé, comme `dateFormat`, lit lui-même ses champs un par un), puis son contrôle dans
l'écran : une rangée `SettingRow` ou `SettingToggle` (`SettingsRows.swift`)
dont les textes (libellé, résumé d'une ligne, détails du popover ⓘ) sont dans `SettingsPresentation`, testés par
`SettingsPresentationTests`. Pas de texte sous la section. Voir « Réglages et mises à jour » ci-dessous.

**Un texte d'interface** : en français, comme littéral SwiftUI (`Text("…")`, `Button("…")`) ou avec
`String(localized: "…")` pour un texte construit. Puis `scripts/localize.sh export`, traduire `en.xliff`,
`scripts/localize.sh import`, et `scripts/localize.sh check` doit passer.

**Un outil de développement** (aperçu, démo, sonde) : dans `DevTools` ou un fichier entouré de `#if DEBUG` ; il ne
doit jamais être dans la version Release (`scripts/check.sh` cherche `DesignPreview` et `DevTools` dans le
binaire Release ; les autres fichiers `#if DEBUG` ne sont pas contrôlés).

## Réglages et mises à jour

Une mise à jour ne doit jamais faire perdre à l'utilisateur ses fournisseurs, ses réglages ni ses clés.

- Les réglages sont un seul bloc JSON (`AppSettings`, clé `wispad.settings.v1` des préférences de
  `com.yatofix.wispad`) ; les clés API vivent à part (`APIKeys` : `Application Support/Wispad/api-keys.json` ou le
  coffre). L'identifiant, le dossier, la base, la clé du bloc et les noms des comptes de clés ne changent pas
  (`StorageIdentityTests`) ; un changement passe par une reprise comme `LegacyMigration`.
- **Lecture champ par champ** : `init(from:)` lit chaque réglage à part. Clé absente : valeur par défaut. Valeur
  illisible, d'un mauvais type, hors limites ou retirée : valeur par défaut de ce seul réglage, ou la plus proche
  valide (fournisseur retiré → fournisseur par défaut du même rôle, modèle retiré → modèle par défaut du même
  fournisseur). Un élément illisible d'une liste ou d'un dictionnaire est écarté seul (`Lenient`). Clé inconnue : ignorée.
- **Écriture par fusion** : `save` remplace les clés connues de cette version et garde les autres (réglage retiré ou
  ajouté par une version plus récente), pour qu'un retour en arrière retrouve ses choix. Lire ne réécrit jamais le bloc.
  Exception : les clés de `AppSettings.retiredKeys` (raccourcis vocaux, transcription sur le Mac, serveur de
  correction compatible OpenAI), retirées volontairement, sont effacées au lancement (`removeRetiredKeys`) et jamais
  recopiées.
- **Bloc illisible en entier** (pas un objet JSON) : copié une fois sous `wispad.settings.v1.illisible` avant toute
  écriture, jamais effacé ; l'app repart des valeurs d'une installation existante.
- **Base SQLite** (`HistoryStore`) : elle évolue par colonnes ajoutées à l'ouverture (`ALTER TABLE … ADD COLUMN`
  si `PRAGMA table_info` ne la trouve pas), jamais retirées ni renommées. Les lignes existantes gardent NULL dans les
  nouvelles colonnes, lu comme « inconnu » (origine d'un mot du dictionnaire : « Avant le suivi »). Ajoutées en fin
  de table, elles restent invisibles pour une version précédente.
- Valeur par défaut d'un ancien bloc : la propriété porte celle d'une nouvelle installation ; si une installation
  existante doit garder l'ancien comportement, `init(from:)` donne une autre valeur quand la clé est absente
  (`useWindowContext`, `onboardingCompleted`, `language`).

Les choix d'affichage à retrouver au lancement suivant (périodes de l'Accueil et de Consommation, section ouverte,
partie dépliée) sont des réglages comme les autres, écrits au changement par `AppModel.setDisplayChoice` (seulement
s'ils changent). Une recherche ou une saisie en cours reste un `@State` éphémère.

**Ajouter un réglage** : nouvelle clé, jamais le nom d'une clé retirée ; sa lecture avec `value(...)` (ou `table`,
`number` avec ses bornes) ; un test qui décode un ancien bloc sans la clé.

**Retirer un réglage, un mode ou un fournisseur** : supprimer la propriété ou le cas de l'énumération suffit, la
lecture tolérante fait le reste ; ne pas réutiliser son nom. Pour effacer ses anciennes valeurs (données
personnelles sans usage), ajouter sa clé à `retiredKeys`. Si l'ancienne valeur doit se convertir (un mode retiré
vers le plus proche), le faire dans `init(from:)`, à partir de la valeur brute. Ne jamais supprimer la clé API d'un
fournisseur retiré : `APIKeys.LocalFile` garde les comptes qu'il ne connaît pas. Ajouter un test de
`SettingsUpgradeTests` avec un bloc qui contient encore l'ancienne valeur.

**Réinstaller** : `scripts/install.sh` ne remplace que le paquet `.app` ; préférences, dossier
`Application Support/Wispad` et clés restent en place (vérifié par `StorageIdentityTests`). La mise à jour en un clic
(`UpdateInstaller`) aussi : seul le paquet `.app` change, jamais effacé avant que la nouvelle version soit en place
(`UpdateInstallerTests`).

## Vérifier

- `scripts/test.sh` : tests locaux, sans micro, réseau, clé ni fenêtre visible.
- `scripts/check.sh` : tests, traductions, compilation Release.
- Rendu de l'interface hors écran, sans rien afficher :
  `Wispad --design-preview --offscreen --snapshot fichier.png [--section providers] [--dark] [--size 900x700]`
  avec le build Debug ; options d'état : `--onboarding-step <étape>` (welcome, permissions, microphone, provider,
  shortcut, trial, finish) avec `--onboarding-state done|failed|progress` (états fictifs, aucune autorisation
  demandée ni micro ouvert), `--shortcut-preview custom|long|disabled|recording` (Réglages › Raccourci avec des
  raccourcis fictifs), `--customer-preview`, `-AppleLanguages "(en)"`.
- Fluidité de l'historique, hors écran : `Wispad --design-preview --offscreen --history-count 1000
  --performance-probe [--scroll-steps 240]` avec le build Debug. Lignes `PERFORMANCE` : deux ouvertures de l'écran
  (temps, vues natives, lignes rendues), puis un défilement simulé vers le bas et vers le haut (temps par étape :
  moyenne, p95, max, étapes de plus de 16 ms ; évaluations de lignes et lignes distinctes).
- Tests réseau à la demande, clés de test seulement : `scripts/live-test.sh SelfCorrectionLiveTests`.
- Banc franglais (audios de `Tests/Fixtures/franglais`, clés de test) : `scripts/franglais-bench.sh <nom> [référence]` ;
  `BENCH_ONLY=h,r,g,l,e,d,n` ne rejoue que les cas de correction seule (champ `transcript` : transcription brute
  inventée, passée directement à la correction, sans audio ni flux xAI ; `dateFormat` facultatif).
- Erreurs signalées depuis l'historique (`ErrorReportArchive`) : `scripts/report-bench.sh <nom>` les rejoue et compte
  les mots faux avant et après un changement de consigne, de garde-fou ou de fournisseur.
