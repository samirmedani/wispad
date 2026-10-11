# Architecture

## Modules

| Module | Rôle | Dépend de |
| --- | --- | --- |
| `WispadCore` | Logique pure et testable : requêtes de transcription et de correction, consigne, garde-fou, comparaison flux/fichier, historique SQLite, coûts, retard de la version sur `main` (`BuildFreshness`), progression du premier lancement guidé (`OnboardingFlow`). Aucun texte d'interface. | — |
| `Wispad` (app) | Coordinateur de dictée, raccourci, bulle, écrans SwiftUI, clés, traductions. | `WispadCore` |

Le projet Xcode (hors Git) est généré par xcodegen depuis `project.yml`. `Package.swift` décrit les mêmes
modules pour les tests (`swift test`), sans dépendance externe, l'app y devenant la cible `WispadApp`. La signature
de l'app se règle dans `Signing.local.xcconfig`, ignoré par Git ; `Signing.xcconfig` garde la signature locale par défaut (voir le README).

Une phase de compilation (`scripts/build-commit.sh`) grave le commit court du dépôt dans l'Info.plist de l'app
(clé `WispadBuildCommit`, absente si git ne répond pas). `BuildStatus` l'affiche avec la version dans la barre
latérale et compare ce commit à `main` sur l'API publique de GitHub, en arrière-plan ; la lecture de la réponse est
la fonction pure `BuildFreshnessCheck.freshness` (WispadCore, testée).

## Premier lancement guidé

`AppModel.onboarding` (un `OnboardingController`) remplace la fenêtre principale tant que `onboardingCompleted`
est faux, ou quand l'utilisateur rejoue la configuration depuis Réglages (`replayOnboarding`, sans rien effacer).

- **Décisions** : `OnboardingFlow.swift` (WispadCore, testé par `OnboardingFlowTests`) dit l'ordre des étapes,
  quand chacune est réussie (`PermissionsCheck`, `MicrophoneCheck` et `VoiceDetector`, `ProviderCheck` et
  `KeyCheck`, `ShortcutCheck`, `TrialCheck`), où « Plus tard » est permis et quelle étape règle un problème.
- **État vivant** : `OnboardingController` lit macOS par `OnboardingSystem` (autorisations sans demande, Réglages
  Système, relance, micros, vumètre), sondé toutes les 0,5 s pendant l'affichage ; les tests le remplacent
  (`OnboardingControllerTests`). Écrans dans `OnboardingView.swift`.
- **Micro** : `MicrophoneMeter` ne sort que des niveaux (rien d'écrit ni d'envoyé) ; le micro choisi
  (`microphoneUID`, `AudioInputDevices`) sert ensuite à `AudioCapture`, sans toucher au micro du système.
- **Touche** : pendant l'étape, `AppModel.shortcutProbe` reçoit les appuis à la place du coordinateur
  (`HotkeyMonitor`) : aucune dictée ne démarre.
- **Essai** : chaque trace terminée passe par `AppModel.noteCompletion` (issue et dictée, jamais de texte) ;
  l'essai réussit quand une dictée collée arrive dans son champ.
- **Relance** : l'étape courante est gardée dans `onboardingResume` ; `OnboardingFlow.resumeStep` la relit de façon
  tolérante.

## Parcours d'une dictée

1. `KeyboardTap` (fil dédié) reconnaît maintien, double appui ou Échap (`HotkeyLogic`) ; `HotkeyMonitor`, sur
   le fil principal, transmet ces effets au coordinateur.
2. `DictationCoordinator.begin` vérifie la clé du fournisseur de voix, lit l'app au premier plan et lance en
   parallèle la lecture du champ actif (`ContextProbe`) et, si la correction et le réglage le permettent, de la
   conversation visible (`WindowTextProbe`). Puis il affiche la bulle et ouvre le micro (`AudioCapture`).
3. Le flux en direct (`LiveSpeechSession`) reçoit l'audio dès que le champ actif est lu (150 ms au plus), et
   l'audio est aussi enregistré ; à chaque pause, une correction est préparée (`DictationCoordinator+EarlyCorrection`).
4. `endCapture` ferme le micro ; un `FinishJob` termine la dictée en arrière-plan.
5. `DictationCoordinator+Transcription` choisit le texte retenu : flux, enregistrement complet
   (`TranscriptEquivalence`, mots du fichier reportés par `CorrectionPatch`) ou relais ; le fichier part chez le
   fournisseur (`BatchTranscriber`). Sans réponse, l'audio reste dans l'historique pour Retranscrire. Le texte passe par `FranglaisNormalizer` avant et après la correction.
6. `TextCleaner` corrige (consigne `CorrectionPrompt`, puis `FidelityGuard`, puis `DictationStructure`) ; une
   consigne sur la sélection passe par `TextCleaner.transform`, sans garde-fou. Les raccourcis vocaux
   (`VoiceSnippets`) s'appliquent ensuite.
7. La dictée est enregistrée (`HistoryStore`), collée dans l'ordre (`TextInserter`, raccord `SmartJoin`), puis
   surveillée pour l'apprentissage (`CorrectionWatcher`, tri par `JevJudge` et `TermJudge`).
8. Chaque appel facturable devient un `UsageEvent` ; la trace sans texte (`DictationTraceRecorder`) alimente le
   détail et le diagnostic.
   L'écran Consommation compte tous les appels enregistrés, filtrés par la seule période
   (`UsagePresentation.events`) ; les bascules vers un fournisseur de secours sont lues dans ces appels
   (`FallbackSummary`, textes de la carte dans `FallbackPresentation`).
   Une clé devenue inutile dans `app_metadata` est supprimée à l'ouverture de `HistoryStore`, jamais les appels.

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
`init(from:)`, puis son contrôle dans l'écran. Voir « Réglages et mises à jour » ci-dessous.

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
- Valeur par défaut d'un ancien bloc : la propriété porte celle d'une nouvelle installation ; si une installation
  existante doit garder l'ancien comportement, `init(from:)` donne une autre valeur quand la clé est absente
  (`useWindowContext`, `onboardingCompleted`, `language`).

**Ajouter un réglage** : nouvelle clé, jamais le nom d'une clé retirée ; sa lecture avec `value(...)` (ou `table`,
`number` avec ses bornes) ; un test qui décode un ancien bloc sans la clé.

**Retirer un réglage, un mode ou un fournisseur** : supprimer la propriété ou le cas de l'énumération suffit, la
lecture tolérante fait le reste ; ne pas réutiliser son nom. Pour effacer ses anciennes valeurs (données
personnelles sans usage), ajouter sa clé à `retiredKeys`. Si l'ancienne valeur doit se convertir (un mode retiré
vers le plus proche), le faire dans `init(from:)`, à partir de la valeur brute. Ne jamais supprimer la clé API d'un
fournisseur retiré : `APIKeys.LocalFile` garde les comptes qu'il ne connaît pas. Ajouter un test de
`SettingsUpgradeTests` avec un bloc qui contient encore l'ancienne valeur.

**Réinstaller** : `scripts/install.sh` ne remplace que le paquet `.app` ; préférences, dossier
`Application Support/Wispad` et clés restent en place (vérifié par `StorageIdentityTests`).

## Vérifier

- `scripts/test.sh` : tests locaux, sans micro, réseau, clé ni fenêtre visible.
- `scripts/check.sh` : tests, traductions, compilation Release.
- Rendu de l'interface hors écran, sans rien afficher :
  `Wispad --design-preview --offscreen --snapshot fichier.png [--section providers] [--dark] [--size 900x700]`
  avec le build Debug ; options d'état : `--onboarding-step <étape>` (welcome, permissions, microphone, provider,
  shortcut, trial, finish) avec `--onboarding-state done|failed|progress` (états fictifs, aucune autorisation
  demandée ni micro ouvert), `--customer-preview`, `-AppleLanguages "(en)"`.
- Fluidité de l'historique, hors écran : `Wispad --design-preview --offscreen --history-count 1000
  --performance-probe [--scroll-steps 240]` avec le build Debug. Lignes `PERFORMANCE` : deux ouvertures de l'écran
  (temps, vues natives, lignes rendues), puis un défilement simulé vers le bas et vers le haut (temps par étape :
  moyenne, p95, max, étapes de plus de 16 ms ; évaluations de lignes et lignes distinctes).
- Tests réseau à la demande, clés de test seulement : `scripts/live-test.sh SelfCorrectionLiveTests`.
- Erreurs signalées depuis l'historique (`ErrorReportArchive`) : `scripts/report-bench.sh <nom>` les rejoue et compte
  les mots faux avant et après un changement de consigne, de garde-fou ou de fournisseur.
