import Foundation

// Logique du premier lancement guidé : quelle étape, quand une étape est réussie, que faire en cas de problème.
// Aucune dépendance au système ni texte d'interface : l'app lit macOS, appelle ces fonctions et affiche le résultat.

/// Étapes du premier lancement guidé, dans l'ordre.
public enum OnboardingStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case permissions
    case microphone
    case provider
    case shortcut
    case trial
    case finish

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var next: OnboardingStep? { Self.allCases.indices.contains(index + 1) ? Self.allCases[index + 1] : nil }
    public var previous: OnboardingStep? { index > 0 ? Self.allCases[index - 1] : nil }

    /// L'étape se vérifie (✓ ou ✗) ; Bienvenue et Fin se passent toujours.
    public var isChecked: Bool { self != .welcome && self != .finish }

    /// « Plus tard » est proposé : le test du micro, de la touche et l'essai se refont à tout moment, alors que
    /// sans autorisations ni clé valide aucune dictée ne peut partir.
    public var allowsLater: Bool {
        switch self {
        case .microphone, .shortcut, .trial: return true
        case .welcome, .permissions, .provider, .finish: return false
        }
    }
}

/// État d'une étape, affiché dans la barre de progression et sur l'écran.
public enum OnboardingStatus: Equatable, Sendable {
    case todo
    case inProgress
    case succeeded
    case failed(OnboardingIssue)

    public var isSucceeded: Bool { self == .succeeded }

    public var issue: OnboardingIssue? {
        if case .failed(let issue) = self { return issue }
        return nil
    }
}

/// Problème précis d'une étape ; l'app en tire le message et la marche à suivre.
public enum OnboardingIssue: Equatable, Sendable {
    /// Autorisation absente, refusée ou en attente d'une relance de l'app.
    case permission(PermissionKind, PermissionState)
    /// Aucun périphérique d'entrée audio.
    case noInputDevice
    /// Le micro n'a pas pu s'ouvrir pour le test.
    case microphoneUnavailable
    /// Micro ouvert, mais aucune voix entendue.
    case silence
    /// Clé du fournisseur de voix vérifiée sans succès.
    case key(KeyCheck)
    /// Rien reçu du raccourci alors que l'écoute du clavier est autorisée.
    case noKeyEvent
    /// Essai de dictée raté, avec sa cause.
    case trial(TrialFailure)
}

public enum OnboardingFlow {
    /// « Continuer » n'est actif que sur une étape réussie (ou sans vérification).
    public static func canContinue(_ step: OnboardingStep, status: OnboardingStatus) -> Bool {
        !step.isChecked || status.isSucceeded
    }

    /// Étape où reprendre après une relance de l'app (autorisation qui l'exige). Lecture tolérante : une valeur
    /// absente ou inconnue repart du début ; la fin n'est jamais reprise, elle se refait depuis Bienvenue.
    public static func resumeStep(saved: String?) -> OnboardingStep {
        guard let saved, let step = OnboardingStep(rawValue: saved), step != .finish else { return .welcome }
        return step
    }

    /// Étape à revoir pour régler un problème signalé ailleurs (essai raté).
    public static func stepToFix(_ issue: OnboardingIssue) -> OnboardingStep? {
        switch issue {
        case .permission: return .permissions
        case .noInputDevice, .microphoneUnavailable, .silence: return .microphone
        case .key: return .provider
        case .noKeyEvent: return .shortcut
        case .trial(let failure): return TrialCheck.stepToFix(failure)
        }
    }
}

// MARK: - Autorisations

/// Autorisations macOS réellement utilisées par Wispad.
public enum PermissionKind: String, CaseIterable, Sendable {
    /// Ouvrir le micro pendant une dictée.
    case microphone
    /// Coller le texte, lire le champ actif.
    case accessibility
    /// Recevoir la touche fn (écoute globale du clavier).
    case inputMonitoring

    /// Ancre du panneau de Réglages Système (Confidentialité et sécurité).
    public var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    /// Jamais demandée par cette session.
    case notRequested
    /// Demandée : on attend la réponse ou l'interrupteur dans Réglages Système.
    case waiting
    /// Refus explicite, à réactiver dans Réglages Système.
    case denied
    /// Accordée, mais macOS ne l'applique qu'après une relance de l'app.
    case needsRelaunch
    case granted
}

public enum PermissionsCheck {
    /// Micro : réponse de macOS (accordé, refusé ou restreint, pas encore demandé).
    public static func microphone(granted: Bool, denied: Bool, requested: Bool) -> PermissionState {
        if granted { return .granted }
        if denied { return .denied }
        return requested ? .waiting : .notRequested
    }

    /// Accessibilité : macOS ne distingue pas un refus d'une absence, l'interrupteur se règle dans Réglages Système.
    public static func accessibility(trusted: Bool, requested: Bool) -> PermissionState {
        trusted ? .granted : (requested ? .waiting : .notRequested)
    }

    /// Surveillance des entrées : accordée, elle n'est effective que si l'écoute du clavier a pu s'installer ;
    /// sinon macOS attend une relance de l'app. `settling` : l'autorisation vient d'arriver, l'écoute s'installe
    /// encore (quelques secondes au plus) et l'on n'annonce pas encore de relance.
    public static func inputMonitoring(trusted: Bool, listening: Bool, requested: Bool, settling: Bool = false) -> PermissionState {
        if trusted {
            if listening { return .granted }
            return settling ? .waiting : .needsRelaunch
        }
        return requested ? .waiting : .notRequested
    }

    /// Réussie quand toutes sont accordées ; un refus ou une relance attendue est un problème à régler.
    public static func status(_ states: [PermissionKind: PermissionState]) -> OnboardingStatus {
        let ordered = PermissionKind.allCases.map { ($0, states[$0] ?? .notRequested) }
        if ordered.allSatisfy({ $0.1 == .granted }) { return .succeeded }
        if let blocked = ordered.first(where: { $0.1 == .denied || $0.1 == .needsRelaunch }) {
            return .failed(.permission(blocked.0, blocked.1))
        }
        return ordered.contains { $0.1 != .notRequested } ? .inProgress : .todo
    }

    /// Prochaine autorisation à demander, dans l'ordre de l'écran.
    public static func next(_ states: [PermissionKind: PermissionState]) -> PermissionKind? {
        PermissionKind.allCases.first { (states[$0] ?? .notRequested) != .granted }
    }

    /// Une relance de Wispad est nécessaire pour au moins une autorisation.
    public static func needsRelaunch(_ states: [PermissionKind: PermissionState]) -> Bool {
        states.values.contains(.needsRelaunch)
    }
}

// MARK: - Micro

/// Niveau d'un paquet audio, en décibels pleine échelle (dBFS).
public enum SignalLevel {
    public static let silence = -100.0

    /// Niveau RMS d'échantillons flottants (-1…1).
    public static func decibels(samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return silence }
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return decibels(rms: (sum / Double(samples.count)).squareRoot())
    }

    public static func decibels(rms: Double) -> Double {
        guard rms > 0, rms.isFinite else { return silence }
        return max(silence, 20 * log10(rms))
    }

    /// Position du vumètre (0…1) : -60 dBFS en bas, -10 dBFS en haut.
    public static func meterFraction(_ decibels: Double) -> Double {
        min(1, max(0, (decibels + 60) / 50))
    }
}

/// Détecte une vraie voix dans le flux du micro : plus forte que le bruit de fond, assez longtemps pour ne pas
/// être un clic ou un souffle. Rien n'est enregistré : seuls des niveaux arrivent ici.
public struct VoiceDetector: Equatable, Sendable {
    /// Voix cumulée exigée.
    public static let requiredVoiceSeconds = 0.6
    /// En dessous, c'est du silence quelle que soit la pièce.
    public static let minimumVoiceLevel = -48.0
    /// La voix dépasse le bruit de fond d'au moins cet écart.
    public static let marginOverNoise = 10.0
    /// Le bruit de fond remonte lentement (un ventilateur qui démarre), mais redescend aussitôt.
    public static let noiseRisePerSecond = 3.0

    public private(set) var noiseFloor: Double?
    public private(set) var voicedSeconds = 0.0
    public private(set) var heardSeconds = 0.0
    public private(set) var lastLevel = SignalLevel.silence

    public init() {}

    public var detected: Bool { voicedSeconds >= Self.requiredVoiceSeconds }

    /// Avancement vers la détection (0…1), pour l'affichage.
    public var progress: Double { min(1, voicedSeconds / Self.requiredVoiceSeconds) }

    public mutating func add(level: Double, seconds: Double) {
        guard seconds > 0, level.isFinite else { return }
        lastLevel = level
        heardSeconds += seconds
        let floor = noiseFloor ?? level
        if level >= max(Self.minimumVoiceLevel, floor + Self.marginOverNoise) {
            voicedSeconds += seconds
        }
        noiseFloor = level < floor ? level : min(level, floor + Self.noiseRisePerSecond * seconds)
    }
}

public enum MicrophoneCheck {
    /// Après ce temps d'écoute sans voix, on explique quoi vérifier (l'écoute continue).
    public static let silenceTimeout = 12.0

    /// `listening` : secondes écoulées depuis l'ouverture du test, à l'horloge ; `meterStarted` : l'ouverture du micro
    /// a rendu la main. Un micro qui ne livre aucun son (aucun paquet, donc aucune seconde entendue) ou dont
    /// l'ouverture ne rend jamais la main finit aussi en problème expliqué, au lieu d'attendre une voix sans fin.
    public static func status(permission: PermissionState, hasInputDevice: Bool, meterFailed: Bool, detector: VoiceDetector,
                              listening: Double = 0, meterStarted: Bool = true) -> OnboardingStatus {
        if detector.detected { return .succeeded }
        if permission != .granted { return .failed(.permission(.microphone, permission)) }
        if !hasInputDevice { return .failed(.noInputDevice) }
        if meterFailed { return .failed(.microphoneUnavailable) }
        if max(detector.heardSeconds, listening) >= silenceTimeout {
            // Un paquet reçu prouve que le micro s'est ouvert, même avant que son ouverture soit notée.
            return .failed(meterStarted || detector.heardSeconds > 0 ? .silence : .microphoneUnavailable)
        }
        return detector.heardSeconds > 0 ? .inProgress : .todo
    }
}

/// Micro choisi par l'utilisateur, s'il est toujours branché ; sinon celui du système (nil).
public enum InputDeviceChoice {
    public static func effectiveUID(saved: String?, available: [String]) -> String? {
        guard let saved, available.contains(saved) else { return nil }
        return saved
    }
}

// MARK: - Fournisseur

/// Résultat de la vérification d'une clé auprès de son fournisseur.
public enum KeyCheck: Equatable, Sendable {
    case missing
    case verifying
    case valid
    /// Refusée par le fournisseur (HTTP 400, 401 ou 403).
    case rejected(Int)
    /// Réponse inattendue : la clé n'est ni confirmée ni refusée.
    case unverified(Int)
    /// Pas de réponse (réseau).
    case offline
    /// Valide, mais impossible à enregistrer.
    case notSaved

    public static func from(httpStatus: Int) -> KeyCheck {
        switch httpStatus {
        case 200: return .valid
        // xAI répond 400 à une clé fausse (« Incorrect API key provided ») ; la vérification, une simple lecture de la
        // liste des modèles sans paramètre, ne peut être refusée que pour sa clé. 403 : clé reconnue mais refusée.
        case 400, 401, 403: return .rejected(httpStatus)
        default: return .unverified(httpStatus)
        }
    }
}

public enum ProviderCheck {
    /// Réussie seulement avec une clé de voix confirmée par le fournisseur. La correction est facultative.
    public static func status(voice: KeyCheck) -> OnboardingStatus {
        switch voice {
        case .missing: return .todo
        case .verifying: return .inProgress
        case .valid: return .succeeded
        case .rejected, .unverified, .offline, .notSaved: return .failed(.key(voice))
        }
    }
}

// MARK: - Touche

/// Ce que l'écoute du clavier a reçu pendant l'étape de la touche. Aucune dictée n'est lancée pendant ce test.
public struct ShortcutProbe: Equatable, Sendable {
    public private(set) var presses = 0
    public private(set) var sawHold = false
    public private(set) var sawHandsFree = false

    public init() {}

    public mutating func notePress() { presses += 1 }

    public mutating func note(_ effect: GestureEffect) {
        switch effect {
        case .startPushToTalk: sawHold = true
        case .startToggle: sawHandsFree = true
        case .stopPushToTalk, .stopToggle: break
        }
    }
}

public enum ShortcutCheck {
    /// Sans aucune frappe reçue après ce délai, on explique quoi vérifier.
    public static let patience = 10.0

    public static func status(probe: ShortcutProbe, waited: Double, inputMonitoring: PermissionState) -> OnboardingStatus {
        if probe.presses > 0 { return .succeeded }
        if inputMonitoring != .granted { return .failed(.permission(.inputMonitoring, inputMonitoring)) }
        return waited >= patience ? .failed(.noKeyEvent) : .todo
    }

    /// Réglage macOS « Touche fn/🌐 » (`AppleFnUsageType` : 0 = ne rien faire). Il n'intéresse que le raccourci fn
    /// et seulement s'il lance autre chose (emojis, source de saisie, dictée Apple).
    public static func fnSettingMatters(shortcutIsFn: Bool, fnUsage: Int?) -> Bool {
        guard shortcutIsFn, let fnUsage else { return false }
        return fnUsage != 0
    }
}

// MARK: - Essai

/// Cause d'un essai de dictée raté.
public enum TrialFailure: String, Equatable, Sendable {
    case microphone
    case key
    case network
    /// Le fournisseur a refusé ou n'a pas répondu (clé, quota).
    case provider
    case noSpeech
    case paste
    case cancelled
    case storage
    /// Le raccourci a été reçu, mais aucune écoute ne s'est ouverte.
    case notStarted
    /// L'écoute ne s'ouvre pas, ou la dictée ne se termine pas, dans le délai maximal.
    case timeout
}

public enum TrialCheck {
    /// Après une dictée collée, le texte doit apparaître dans le champ d'essai dans ce délai.
    public static let pasteGrace = 2.0
    /// Après un geste de dictée reçu pendant l'essai, l'écoute doit commencer dans ce délai.
    public static let startGrace = 4.0
    /// Ouverture du micro ou fin de la dictée (transcription, correction, collage) : au-delà, l'essai est raté.
    /// L'écoute elle-même n'a pas de limite : on peut parler aussi longtemps qu'on veut.
    public static let stallLimit = 45.0

    public static func failure(for outcome: DictationOutcome, online: Bool) -> TrialFailure? {
        switch outcome {
        case .inserted, .pasteSent, .pending: return nil
        case .microphoneDenied, .captureFailed: return .microphone
        case .keyUnavailable: return .key
        case .transcriptionFailed, .commandFailed: return online ? .provider : .network
        case .noSpeech: return .noSpeech
        case .noTarget, .refusedSecure, .insertionFailed: return .paste
        case .cancelled: return .cancelled
        case .historyFailed: return .storage
        }
    }

    /// `outcome` : issue de la dernière dictée commencée pendant l'essai ; `textArrived` : le champ d'essai a reçu
    /// du texte depuis ; `waited` : secondes depuis cette issue. `stalled` : secondes passées à ouvrir le micro ou à
    /// terminer la dictée (0 pendant l'écoute) ; `sincePress` : secondes depuis un geste de dictée reçu pendant
    /// l'essai et resté sans écoute ni issue. Aucune attente n'est infinie : chacune a son délai maximal.
    public static func status(dictating: Bool, outcome: DictationOutcome?, online: Bool, textArrived: Bool, waited: Double,
                              stalled: Double = 0, sincePress: Double? = nil) -> OnboardingStatus {
        if dictating {
            return stalled >= stallLimit ? .failed(.trial(online ? .timeout : .network)) : .inProgress
        }
        // Du texte tapé à la main ne prouve rien : seule une dictée terminée compte.
        guard let outcome else {
            guard let sincePress else { return .todo }
            return sincePress >= startGrace ? .failed(.trial(.notStarted)) : .inProgress
        }
        if let failure = failure(for: outcome, online: online) { return .failed(.trial(failure)) }
        if textArrived { return .succeeded }
        return waited >= pasteGrace ? .failed(.trial(.paste)) : .inProgress
    }

    public static func stepToFix(_ failure: TrialFailure) -> OnboardingStep? {
        switch failure {
        case .microphone: return .microphone
        case .key, .provider: return .provider
        case .paste: return .permissions
        case .network, .noSpeech, .cancelled, .storage, .notStarted, .timeout: return nil
        }
    }
}
