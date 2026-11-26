import AppKit
import ApplicationServices
import Carbon
import Foundation
import WispadCore
import os

/// État éphémère du champ. Son contenu ne quitte jamais la mémoire de l'insertion.
struct InsertionField: @unchecked Sendable {
    var element: AXUIElement?
    var isSecure = false
    var value: String?
    var before: String?
    /// Début du texte juste après le curseur (ou la sélection) : la phrase continue-t-elle ?
    var after: String?
    var role: String?
    var subrole: String?
    var hasTextCursor = false
    /// Page web (ou lien, bouton, liste avec un curseur) qui se déclare modifiable : son curseur est celui d'un champ.
    var editable = false
    var selection: NSRange?

    static func read(pid: pid_t) -> InsertionField {
        guard let element = ContextProbe.focusedElement(pid: pid) else { return InsertionField() }
        guard !ContextProbe.isSecure(element) else { return InsertionField(element: element, isSecure: true) }
        let selection = ContextProbe.selectedRange(element)
        let value = ContextProbe.valueForCheck(element)
        let before: String?
        var after: String?
        if let value, let selection, selection.location <= (value as NSString).length {
            let start = max(0, selection.location - 32)
            before = (value as NSString).substring(with: NSRange(location: start, length: selection.location - start))
            let ns = value as NSString
            let end = min(ns.length, selection.location + max(0, selection.length))
            after = ns.substring(with: NSRange(location: end, length: min(16, ns.length - end)))
        } else {
            before = ContextProbe.textBeforeCursor(element)
        }
        let role = ContextProbe.string(kAXRoleAttribute, element)
        return InsertionField(
            element: element, value: value, before: before, after: after,
            role: role,
            subrole: ContextProbe.string(kAXSubroleAttribute, element),
            hasTextCursor: selection != nil,
            editable: FocusedField.needsEditableCheck(role: role, hasTextCursor: selection != nil)
                && ContextProbe.isEditable(element),
            selection: selection
        )
    }

    func kind(bundleID: String?) -> FocusedFieldKind {
        if isSecure { return .text }
        return FocusedField.kind(role: role, subrole: subrole, hasTextCursor: hasTextCursor, editable: editable,
                                 bundleID: bundleID)
    }

    /// Un nouveau nœud AX n'est accepté que s'il contient l'édition attendue, typographie normalisée.
    /// Un autre champ déjà rempli avec une ancienne dictée ne suffit pas à confirmer.
    func confirmsReplacement(in after: InsertionField, inserted: String) -> Bool {
        guard InsertionCheck.matchesReplacement(before: value, selection: selection, after: after.value, inserted: inserted) else { return false }
        if value != after.value { return true }
        // Remplacer une sélection par le même texte est un succès si le curseur s'est bien déplacé à sa fin.
        guard let selection, selection.length > 0 else { return false }
        return after.selection == NSRange(location: selection.location + (inserted as NSString).length, length: 0)
    }

    func sameElement(as other: InsertionField) -> Bool {
        guard let element, let other = other.element else { return false }
        return CFEqual(element, other)
    }

    /// Champ actif de l'app, `seconds` au plus ; un champ vide sans réponse à temps. Chaque lecture a sa file, jamais un
    /// fil de Swift concurrency : relancée pendant qu'une précédente attend encore une app lente, elle ne l'attend pas.
    /// `reader` : la lecture, remplacée dans les tests.
    @MainActor static func read(pid: pid_t, within seconds: Double,
                                reader: @escaping @Sendable (pid_t) -> InsertionField = { InsertionField.read(pid: $0) })
        async -> InsertionField {
        let task = Task.detached(priority: .userInitiated) {
            await BlockingQueue.run(label: "wispad.insertion") { reader(pid) }
        }
        return await DictationCoordinator.value(of: task, within: seconds) ?? InsertionField()
    }
}

/// Frontières macOS remplaçables dans les tests, sans envoyer de touches aux apps de l'utilisateur.
@MainActor
struct InsertionSystem {
    var trusted: () -> Bool = { PermissionCenter.accessibilityTrusted(prompt: false) }
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var bundleID: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    var appName: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.localizedName }
    var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
    /// App qui tient la saisie sécurisée de macOS (champ de mot de passe, gestionnaire de mots de passe…), nil si
    /// macOS ne le dit pas. Demandée par un outil en ligne de commande, elle est attribuée à l'app au premier plan
    /// (mesuré le 17 octobre 2026).
    var secureInputHolder: () -> pid_t? = { TextInserter.secureInputHolder() }
    /// Attend que les touches modificatrices soient relâchées ; rend celles encore tenues au bout de l'attente
    /// (masques `ModifierMask`), 0 si toutes le sont.
    var modifiersStillHeld: () async -> UInt64 = { await TextInserter.waitForModifierRelease() }
    var read: (pid_t) async -> InsertionField = { pid in
        await InsertionField.read(pid: pid, within: TextInserter.fieldReadLimit)
    }
    /// Champ le plus probable de la fenêtre active, lu en lecture seule (`ProbableInput`).
    var findProbableInput: (ProbableInput.Request) async -> ProbableInput.Target? = { await ProbableInput.find($0) }
    /// Place le focus dans le champ choisi, comme un clic ; faux si rien n'a pu être vérifié.
    var focusProbableInput: (ProbableInput.Target, pid_t, Int) async -> Bool = {
        await ProbableInput.focus($0, pid: $1, typingKeys: $2)
    }
    var fillProbableInput: (ProbableInput.Target, String, pid_t, Int) async -> InsertionStatus = {
        await ProbableInput.fill($0, text: $1, pid: $2, typingKeys: $3)
    }
    /// Dernier clic depuis cet instant (horloge de KeyboardTap.now()), et pointeur de la souris.
    var click: (Int) -> CGPoint? = { ClickTracker.click(since: $0) }
    var latestClick: () -> ClickTracker.Click? = { ClickTracker.latest }
    var pointer: () -> CGPoint? = { ClickTracker.pointer() }
    /// Champ où la dictée vient d'arriver : il compte pour les prochaines dictées sans curseur dans un champ.
    var remember: (pid_t, String?, AXUIElement?) -> Void = { pid, bundle, element in
        ProbableInput.remember(pid: pid, bundleID: bundle, element: element)
    }
    var pasteboard: NSPasteboard = .general
    /// Sur le fil principal : la touche V se cherche dans la disposition du clavier, que macOS n'autorise que là.
    var postPaste: @MainActor (pid_t) async -> Bool = { _ in TextInserter.postCommandV() }
    /// Une touche Effacer, avant le collage qui prolonge la dictée précédente : retire son point final.
    var deleteBackward: @MainActor (pid_t) async -> Bool = { _ in TextInserter.postDeleteBackward() }
    /// Zone de saisie lue après l'envoi, pour que les messages de la bulle ne la couvrent pas.
    var locate: (pid_t) async -> CGRect? = { pid in
        await ContextProbe.inputZone(pid: pid, within: TextInserter.fieldReadLimit)
    }
    /// Écriture de secours, quand le champ a ignoré ⌘V : le champ se déclare-t-il modifiable ?
    var editable: (AXUIElement) async -> Bool = { element in
        await TextInserter.axCall(UncheckedSendable(element)) { ContextProbe.isEditable($0) } ?? false
    }
    /// Remplace la sélection (ou insère au curseur) par l'accessibilité. Faux si le champ ne l'accepte pas.
    var replaceSelection: (AXUIElement, String) async -> Bool = { element, text in
        await TextInserter.axCall(UncheckedSendable(element)) { TextInserter.replaceSelectedText($0, with: text) } ?? false
    }
    /// Tape le texte comme au clavier, dans l'app au premier plan.
    var typeText: @MainActor (String) async -> Bool = { await TextInserter.typeCharacters($0) }
    /// Compteur de frappes et clics réels : une frappe ou un Entrée après lecture du presse-papiers change le champ.
    var keystrokes: () -> Int = { KeyboardTap.keystrokes }
    var confirmationLimit: Double = TextInserter.confirmationLimit
    var lateConfirmationLimit: Double = TextInserter.lateConfirmationLimit
    var clipboardHold: Double = TextInserter.clipboardHold
}

/// Dernière zone de saisie connue, par app : les messages de la bulle s'en écartent.
@MainActor
enum InputZoneTracker {
    private static var latest: (zone: CGRect, pid: pid_t, at: Date)?
    /// Au-delà, la fenêtre a pu bouger : la zone n'est plus fiable.
    static let lifetime: TimeInterval = 120

    static func note(_ zone: CGRect?, pid: pid_t) {
        latest = zone.map { ($0, pid, Date()) }
    }

    /// Zone de l'app au premier plan, si elle a été lue récemment.
    static func zone(frontmost pid: pid_t?) -> CGRect? {
        guard let latest, let pid, latest.pid == pid, Date().timeIntervalSince(latest.at) < lifetime else { return nil }
        return latest.zone
    }

    static func reset() { latest = nil }
}

@MainActor
enum TextInserter {
    private static let log = Logger.wispad("insertion")
    private struct Memory {
        var pid: pid_t
        var element: AXUIElement?
        var text: String
        var keystrokes: Int
        var at: Date
    }
    private static var last: Memory?
    /// Toutes les entrées (dictée, historique, bouton et raccourci) partagent le même presse-papiers.
    private static var tail: AsyncResult<Void>?
    static let fieldReadLimit = 0.3
    /// Relecture du champ après ⌘V. Elle suit l'envoi : le spectre de traitement a déjà disparu.
    static let confirmationLimit = 1.0
    /// L'app a lu la dictée mais son champ paraît encore identique : une app Electron chargée (Antigravity,
    /// 22 novembre 2026) montre le texte collé à l'accessibilité plus d'une seconde après. Relecture jusqu'à ce délai.
    static let lateConfirmationLimit = 2.5
    /// Sans lecture du presse-papiers par l'app, le texte y reste au plus ce temps après ⌘V : une app occupée
    /// (page web chargée, Electron) peut le lire tard ; le restaurer avant ferait coller l'ancien contenu.
    static let clipboardHold = 1.5
    /// Après la lecture du collage, le temps de ses lectures groupées (texte, puis autres formats demandés).
    static let readGrace = 0.15

    /// Le curseur de l'app au premier plan est dans un champ de texte reconnu (rôle de texte ou curseur de texte), ni
    /// sécurisé ni dans Wispad. Un conteneur illisible ne compte pas : rien ne prouve qu'on y écrit.
    @MainActor static func frontmostFocusTakesText(system: InsertionSystem = InsertionSystem()) async -> Bool {
        guard system.trusted(), let pid = system.frontmostPID(), pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        let field = await system.read(pid)
        guard !field.isSecure, system.frontmostPID() == pid else { return false }
        return field.kind(bundleID: system.bundleID(pid)) == .text
    }

    static func insert(
        _ text: String, context: DictationContext,
        shouldProceed: @escaping @MainActor () -> Bool = { true },
        didSendPaste: @escaping @MainActor () -> Void = {},
        system: InsertionSystem = InsertionSystem()
    ) async -> InsertionStatus {
        let previous = tail
        let done = AsyncResult<Void>()
        tail = done
        try? await previous?.value()
        var releasesLater = false
        defer { if !releasesLater { finishTurn(done) } }
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        // Champ de mot de passe : jugé plus bas, sur le champ lu au moment du collage (le curseur a pu le quitter).
        guard system.trusted() else {
            // Accessibilité retirée (ou jamais donnée) : ni ⌘V ni lecture du champ, le texte reste à copier.
            log.notice("collage retenu : accessibilité non autorisée")
            context.accessibilityRefused = true
            return .failed
        }
        let frontmost = system.frontmostPID()
        // Le texte va là où est l'utilisateur à la fin, comme on l'attend d'une dictée, même s'il a changé d'app ou
        // tapé entre-temps. Seule une sélection réécrite sur consigne reste liée à son app (jamais de réécriture ailleurs).
        let followsFocus = Self.followsFocus(context)
        let target = followsFocus ? frontmost : context.pid ?? frontmost
        guard let pid = target, frontmost == pid else {
            // Ne pas réactiver une ancienne app pendant que l'utilisateur écrit ailleurs.
            log.notice("collage retenu : app cible plus au premier plan")
            return .noTarget
        }
        let waitStarted = Date()
        let held = await system.modifiersStillHeld()
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        guard held == 0 else {
            log.notice("collage retenu : touches \(TextInserter.modifierNames(held), privacy: .public) encore maintenues")
            context.heldModifiers = held
            // Pas de ⌘V : la zone de saisie est quand même repérée, pour que la carte « Texte prêt » ne la couvre pas.
            InputZoneTracker.note(await system.locate(pid), pid: pid)
            return .failed
        }
        let waited = Date().timeIntervalSince(waitStarted)
        if waited > 0.3 {
            log.notice("collage attendu \(Int(waited * 1_000), privacy: .public) ms : touches modificatrices relâchées")
        }
        let bundle = system.bundleID(pid)
        var field = await system.read(pid)
        guard shouldProceed(), !Task.isCancelled else { return .cancelled }
        guard system.frontmostPID() == pid else { return .noTarget }
        let originalPID = context.pid
        if context.pid != pid {
            // L'historique et l'apprentissage doivent viser l'app réellement choisie, pas celle du démarrage.
            context.pid = pid
            context.bundleID = bundle
            context.appName = system.appName(pid)
        }
        if Self.refusesSecure(context: context, field: field) {
            Self.logSecureRefusal(field: field, system: system, target: pid)
            return .refusedSecure
        }
        var kind = field.kind(bundleID: bundle)
        let isCodex = bundle == ContextProbe.codexBundleID
        // Curseur hors d'un champ : le champ le plus probable de la fenêtre (zone de message, champ du début, dernier
        // champ utilisé, sous le dernier clic). Focus illisible ou indécis : un éditeur caché l'a peut-être, il faut une
        // preuve forte. Jamais si l'utilisateur tape depuis l'arrêt, ni pour une sélection, ni vers un mot de passe.
        var choseField = false
        if kind != .text, let typing = context.probableInputKeys, typing == KeyboardTap.typingKeys,
           !ContextProbe.isOwnProcess(pid), !context.isSecure, !context.rewritesSelection,
           !Self.secureInputHeld(by: pid, system: system) {
            let request = ProbableInput.Request(
                pid: pid, bundleID: bundle, focus: field.element, start: originalPID == pid ? context.element : nil,
                click: system.click(context.startedAt), pointer: system.pointer(), strict: kind == .unknown
            )
            let candidate = await system.findProbableInput(request)
            guard shouldProceed(), !Task.isCancelled else { return .cancelled }
            guard system.frontmostPID() == pid, typing == KeyboardTap.typingKeys else { return .noTarget }
            if let candidate {
                if await system.focusProbableInput(candidate, pid, typing) {
                    choseField = true
                    context.usedProbableInput = true
                    field = await system.read(pid)
                    guard shouldProceed(), !Task.isCancelled else { return .cancelled }
                    guard system.frontmostPID() == pid else { return .noTarget }
                    if field.isSecure {
                        Self.logSecureRefusal(field: field, system: system, target: pid)
                        return .refusedSecure
                    }
                    kind = field.kind(bundleID: bundle)
                } else if candidate.native, candidate.empty {
                    // Champ natif où le focus ne se place pas : sa valeur s'écrit directement, sans touche.
                    let status = await system.fillProbableInput(candidate, text, pid, typing)
                    if status.delivered {
                        context.usedProbableInput = true
                        last = nil
                        didSendPaste()
                        if status == .inserted { system.remember(pid, bundle, candidate.element) }
                    }
                    if status != .noTarget { return status }
                }
            }
        }
        guard kind != .notText || choseField else { return .noTarget }
        if !choseField, Self.leftTextField(context: context, field: field, kind: kind, pid: pid) {
            log.notice("collage retenu : le curseur a quitté le champ du début de la dictée")
            context.leftTextField = true
            // Pas de ⌘V : la zone de saisie est quand même repérée, pour que la carte « Texte prêt » ne la couvre pas.
            InputZoneTracker.note(await system.locate(pid), pid: pid)
            return .noTarget
        }
        let memory = previousMemory(pid: pid, element: field.element)
        var before = SmartJoin.textBefore(read: field.before, previous: memory?.text, previousConfirmed: memory != nil)
        // La dictée précédente finit par un point que la correction prolonge : il part avant le collage.
        if SmartJoin.continuesPreviousPaste(text, before: before, previous: memory?.text), let known = before,
           shouldProceed(), !Task.isCancelled, system.frontmostPID() == pid, await system.deleteBackward(pid) {
            before = String(known.dropLast())
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let joined = SmartJoin.adjust(SmartJoin.fit(text, before: before, after: field.after), before: before)
        let keystrokes = system.keystrokes()
        guard let transaction = PasteboardTransaction(text: joined, pasteboard: system.pasteboard) else {
            log.notice("collage impossible : presse-papiers non modifiable")
            return .failed
        }
        transaction.expectPaste()
        guard shouldProceed(), !Task.isCancelled, system.frontmostPID() == pid, await system.postPaste(pid) else {
            transaction.restoreIfUnchanged()
            if !shouldProceed() || Task.isCancelled { return .cancelled }
            return system.frontmostPID() == pid ? .failed : .noTarget
        }
        didSendPaste()
        // Le presse-papiers revient dès que l'app a lu la dictée, sans attendre la confirmation : un ⌘V fait juste
        // après colle à nouveau ce que l'utilisateur avait copié. Faute de lecture, au bout du délai de lecture.
        let hold = system.clipboardHold
        let restoring = Task { @MainActor in
            if await transaction.waitForPasteRead(within: hold) {
                try? await Task.sleep(nanoseconds: UInt64(Self.readGrace * 1_000_000_000))
            }
            let unread = transaction.wasDefinitelyUnread
            transaction.restoreIfUnchanged()
            return unread
        }
        let sentAt = Date()
        // Où écrit l'utilisateur : lu après l'envoi, sans retarder le texte ni l'apparition de la bulle.
        let locate = system.locate
        Task { @MainActor in InputZoneTracker.note(await locate(pid), pid: pid) }
        let deadline = sentAt.addingTimeInterval(system.confirmationLimit)
        let lateDeadline = sentAt.addingTimeInterval(max(system.confirmationLimit, system.lateConfirmationLimit))
        var unchangedTarget = false
        var confirmed = false
        repeat {
            // Relire immédiatement : une insertion déjà visible n'attend aucun minuteur.
            // Chaque lecture système est elle-même bornée à fieldReadLimit.
            guard system.frontmostPID() == pid else {
                // App quittée avant la fin de la relecture : un instantané antérieur ne prouve pas un échec.
                unchangedTarget = false
                break
            }
            if transaction.wasRead, system.keystrokes() != keystrokes {
                // L'app a lu le presse-papiers et l'utilisateur a déjà agi (ex. Entrée pour envoyer, ce qui vide le champ).
                unchangedTarget = false
                break
            }
            let after = await system.read(pid)
            guard !after.isSecure else {
                unchangedTarget = false
                break
            }
            // Un composant web peut recréer son nœud après input : le focus est relu à chaque fois.
            let sameTarget = field.sameElement(as: after)
            let selectionMoved = sameTarget && transaction.wasRead
                && field.selection != nil && after.selection != nil && after.selection != field.selection
            unchangedTarget = sameTarget && field.value != nil && after.value == field.value && !selectionMoved
            if field.confirmsReplacement(in: after, inserted: joined) ||
                ((sameTarget || field.element == nil) && InsertionCheck.confirms(before: field.value, after: after.value, inserted: joined)) ||
                (sameTarget && InsertionCheck.confirmsBeforeCursor(before: field.before, after: after.before, inserted: joined)) {
                confirmed = true
                break
            }
            if transaction.wasRead, system.keystrokes() != keystrokes {
                unchangedTarget = false
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        } while Date() < deadline || (unchangedTarget && transaction.wasRead && Date() < lateDeadline)
        if !confirmed, unchangedTarget, transaction.wasRead, system.keystrokes() != keystrokes {
            unchangedTarget = false
        }
        // Même champ, toujours lisible et inchangé une seconde après ⌘V : le texte n'est pas arrivé.
        // Presse-papiers lu par l'app : l'attente va jusqu'à lateConfirmationLimit, son champ peut se mettre à jour tard.
        // Un champ illisible (apps Electron, éditeurs dessinés) ne prouve rien : collage envoyé, sans alerte.
        var status: InsertionStatus = confirmed ? .inserted : unchangedTarget ? .failed : .pasteSent
        // Dans Codex, un champ opaque peut vraiment prendre ⌘V. Attendre toute la fenêtre de lecture avant
        // d'afficher la carte ; ne jamais réessayer automatiquement un collage déjà lu ou incertain.
        if isCodex, kind == .unknown, status == .pasteSent,
           await restoring.value, shouldProceed(), !Task.isCancelled,
           system.frontmostPID() == pid, system.keystrokes() == keystrokes {
            status = .failed
        }
        if !confirmed {
            log.notice("collage non confirmé : champ_inchangé=\(unchangedTarget, privacy: .public) statut=\(status.rawValue, privacy: .public)")
        }
        if !confirmed, unchangedTarget, kind == .text, shouldProceed(), !Task.isCancelled {
            switch await writeDirectly(joined, into: field, pid: pid, keystrokes: keystrokes, pasteRead: transaction.wasRead,
                                       shouldProceed: shouldProceed, system: system) {
            case .written, .arrivedLate:
                confirmed = true
                status = .inserted
            case .changedLate:
                // L'app a lu la dictée et son champ a bougé, sans que le texte s'y reconnaisse tel quel (mise en forme
                // de l'éditeur) : rien ne prouve un échec. Sans lecture du presse-papiers, l'échec reste signalé.
                if transaction.wasRead { status = .pasteSent }
            case .notWritten:
                break
            }
        }
        if status == .failed {
            // La carte « Texte prêt » s'écarte du champ tel qu'il est maintenant : il a pu grandir depuis ⌘V.
            InputZoneTracker.note(await system.locate(pid), pid: pid)
        }
        // Un texte non confirmé ne doit jamais servir à inventer une espace à la dictée suivante.
        last = confirmed ? Memory(pid: pid, element: field.element, text: joined, keystrokes: keystrokes, at: Date()) : nil
        // Champ confirmé : il compte pour les prochaines dictées finies sans curseur dans un champ.
        if confirmed, context.probableInputKeys != nil { system.remember(pid, bundle, field.element) }
        if confirmed {
            transaction.restoreIfUnchanged()
        } else {
            // Le statut part tout de suite ; le tour suivant attend la restauration du presse-papiers.
            releasesLater = true
            Task { @MainActor in
                _ = await restoring.value
                finishTurn(done)
            }
        }
        return status
    }

    private static func finishTurn(_ done: AsyncResult<Void>) {
        done.resolve(.success(()))
        if tail === done { tail = nil }
    }

    /// Issue de l'écriture de secours.
    enum BackupWrite: Equatable {
        /// Le texte est arrivé par l'accessibilité ou la frappe.
        case written
        /// Le collage est arrivé tard dans le champ, juste avant l'écriture de secours : rien n'a été écrit en plus.
        case arrivedLate
        /// Le champ a changé depuis ⌘V sans que le texte s'y reconnaisse : rien n'a été écrit.
        case changedLate
        /// Rien n'a été écrit (champ non modifiable, focus ou app changés, frappe, écriture sans effet).
        case notWritten
    }

    /// ⌘V envoyé, et le champ lisible est resté identique : l'app n'a pas pris le collage (page qui intercepte le
    /// collage ou le raccourci, ⌘V perdu). Le 5 novembre 2026, deux dictées dans un champ de Chrome finissaient ainsi en
    /// « Texte prêt ». Le texte est écrit une seule fois dans ce même champ, autrement : remplacement de la sélection
    /// par l'accessibilité si le champ l'accepte, sinon frappe des caractères. Jamais si l'utilisateur a tapé depuis, si
    /// le focus ou l'app a changé, si le champ a bougé, est sécurisé ou ne se déclare pas modifiable. Un collage arrivé
    /// tard (le champ contient maintenant le texte) compte comme écrit, sans seconde écriture.
    static func writeDirectly(_ text: String, into field: InsertionField, pid: pid_t, keystrokes: Int, pasteRead: Bool,
                              shouldProceed: @MainActor () -> Bool, system: InsertionSystem) async -> BackupWrite {
        guard let element = field.element, !field.isSecure, !text.isEmpty else { return .notWritten }
        guard await system.editable(element) else { return .notWritten }
        // Dernière vérification juste avant d'écrire : même app, même champ, toujours identique, aucune frappe.
        // Le champ a changé : le collage est peut-être arrivé tard, et rien ne doit s'écrire en double.
        func untouched() async -> BackupWrite? {
            guard shouldProceed(), !Task.isCancelled, system.keystrokes() == keystrokes,
                  system.frontmostPID() == pid else { return .notWritten }
            let now = await system.read(pid)
            guard !now.isSecure, field.sameElement(as: now) else { return .notWritten }
            guard now.value != field.value else { return nil }
            if field.confirmsReplacement(in: now, inserted: text) ||
                InsertionCheck.confirms(before: field.value, after: now.value, inserted: text) {
                log.notice("collage arrivé tard (presse-papiers lu : \(pasteRead, privacy: .public)) : aucune écriture de secours")
                return .arrivedLate
            }
            return .changedLate
        }
        if let stop = await untouched() { return stop }
        if await system.replaceSelection(element, text), await confirmsWrite(text, in: field, pid: pid, within: 0.3, system: system) {
            log.notice("collage ignoré par l'app (presse-papiers lu : \(pasteRead, privacy: .public)) : écrit par l'accessibilité")
            return .written
        }
        // L'accessibilité n'a rien changé (ou le champ la refuse) : frappe, si rien n'a bougé entre-temps.
        if let stop = await untouched() { return stop == .arrivedLate ? .arrivedLate : .notWritten }
        guard await system.typeText(text),
              await confirmsWrite(text, in: field, pid: pid, within: system.confirmationLimit, system: system) else {
            log.notice("collage ignoré par l'app (presse-papiers lu : \(pasteRead, privacy: .public)) : écriture de secours sans effet")
            return .notWritten
        }
        log.notice("collage ignoré par l'app (presse-papiers lu : \(pasteRead, privacy: .public)) : écrit par la frappe")
        return .written
    }

    private static func confirmsWrite(_ text: String, in field: InsertionField, pid: pid_t, within seconds: Double,
                                      system: InsertionSystem) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard system.frontmostPID() == pid else { return false }
            let after = await system.read(pid)
            guard !after.isSecure else { return false }
            if field.confirmsReplacement(in: after, inserted: text) ||
                (field.sameElement(as: after) && InsertionCheck.confirms(before: field.value, after: after.value, inserted: text)) {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        } while Date() < deadline
        return false
    }

    /// Appel d'accessibilité sur sa file, borné comme les lectures du champ : une app figée ne bloque rien.
    static func axCall<Value: Sendable>(_ element: UncheckedSendable<AXUIElement>,
                                        _ body: @escaping @Sendable (AXUIElement) -> Value) async -> Value? {
        let task = Task.detached(priority: .userInitiated) {
            await BlockingQueue.run(label: "wispad.insertion") { body(element.value) }
        }
        return await DictationCoordinator.value(of: task, within: fieldReadLimit)
    }

    nonisolated static func replaceSelectedText(_ element: AXUIElement, with text: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Le texte tapé comme au clavier, par morceaux de quelques caractères, marqués : l'écoute du clavier ne les compte
    /// pas comme des frappes. Un retour à la ligne part en ⇧↩, qui va à la ligne sans envoyer un message.
    @MainActor static func typeCharacters(_ text: String) async -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = KeyboardTap.syntheticMarker
        func post(_ units: [UniChar]) -> Bool {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        func newline() -> Bool {
            let returnKey: CGKeyCode = 0x24
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else { return false }
            down.flags = .maskShift
            up.flags = .maskShift
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            return true
        }
        for chunk in typingChunks(text) {
            guard !Task.isCancelled else { return false }
            guard chunk == "\n" ? newline() : post(Array(chunk.utf16)) else { return false }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return true
    }

    /// Morceaux de 16 unités UTF-16 au plus, sans couper un caractère ; chaque retour à la ligne est seul.
    nonisolated static func typingChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            if character == "\n" || character == "\r\n" {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append("\n")
                continue
            }
            if current.utf16.count + String(character).utf16.count > 16 { chunks.append(current); current = "" }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Le texte suit l'utilisateur jusqu'à l'app où il est à la fin de la dictée. Seule une sélection réécrite sur
    /// consigne reste liée à son app : jamais de réécriture ailleurs. Le 17 novembre 2026, trois dictées (Discord,
    /// Chrome) finissaient en « Texte prêt » parce qu'une touche tapée pendant l'écoute liait le texte à l'app du début.
    static func followsFocus(_ context: DictationContext) -> Bool {
        !context.rewritesSelection
    }

    /// Saisie sécurisée tenue par l'app visée, ou par une app que macOS ne nomme pas : aucun champ n'est cherché.
    static func secureInputHeld(by pid: pid_t, system: InsertionSystem) -> Bool {
        guard system.secureInput() else { return false }
        return system.secureInputHolder().map { $0 == pid } ?? true
    }

    /// Carte « Texte prêt » qui attend un champ : après un clic, le champ sous le clic (ou son éditeur parent) reçoit le
    /// focus s'il ne l'a pas pris lui-même (éditeur qui n'annonce pas son focus). Vrai quand le curseur est dans un champ.
    @MainActor static func focusInputAtLatestClick(system: InsertionSystem = InsertionSystem()) async -> Bool {
        guard system.trusted(), let pid = system.frontmostPID(), !ContextProbe.isOwnProcess(pid),
              let click = system.latestClick(), KeyboardTap.now() - click.at < 3_000 else { return false }
        let field = await system.read(pid)
        guard !field.isSecure, system.frontmostPID() == pid else { return false }
        if field.kind(bundleID: system.bundleID(pid)) == .text { return true }
        guard !secureInputHeld(by: pid, system: system) else { return false }
        let typing = KeyboardTap.typingKeys
        let request = ProbableInput.Request(pid: pid, bundleID: system.bundleID(pid), focus: field.element,
                                            click: click.point, clickOnly: true)
        guard let target = await system.findProbableInput(request), system.frontmostPID() == pid else { return false }
        return await system.focusProbableInput(target, pid, typing)
    }

    /// Le curseur a quitté le champ pendant la dictée : elle a commencé dans un champ de texte de cette app, et le focus
    /// est maintenant sur un autre élément lisible qui n'en est pas un (la page, la conversation, un groupe), sans champ
    /// probable trouvé. Cette app expose ses champs (celui du début a été lu) : ce n'est pas un éditeur caché, et un ⌘V
    /// partirait dans le vide. Un focus illisible ne prouve rien : le collage reste envoyé.
    static func leftTextField(context: DictationContext, field: InsertionField, kind: FocusedFieldKind, pid: pid_t) -> Bool {
        guard context.startedInTextField, context.pid == pid, kind != .text, field.role != nil,
              let now = field.element else { return false }
        if let start = context.element, CFEqual(start, now) { return false }
        return true
    }

    /// Attente des touches modificatrices tenues au moment de coller (raccourci de capture d'écran, touche gardée
    /// enfoncée). Le 17 octobre 2026, une touche tenue 2,4 s juste après une dictée faisait échouer le collage, qui
    /// n'attendait que 0,8 s : le texte part maintenant dès qu'elle est relâchée.
    static let modifierReleaseLimit = 5.0

    /// Un délai expiré est un échec récupérable, jamais une permission d'envoyer ⌃⌥⌘V. Rend les touches encore tenues
    /// (masques `ModifierMask`), 0 si toutes sont relâchées.
    static func waitForModifierRelease(limit: Double = modifierReleaseLimit) async -> UInt64 {
        let watched: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]
        let deadline = Date().addingTimeInterval(limit)
        var held = CGEventSource.flagsState(.hidSystemState).intersection(watched)
        while !held.isEmpty, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
            held = CGEventSource.flagsState(.hidSystemState).intersection(watched)
        }
        return held.rawValue & ModifierMask.relevant
    }

    /// « ⇧ », « ⇧⌘ », « ⌥ fn » : les touches modificatrices dans l'ordre des menus de macOS.
    nonisolated static func modifierNames(_ flags: UInt64) -> String {
        let symbols = PasteShortcut.modifierSymbols(flags).joined()
        guard flags & ModifierMask.function != 0 else { return symbols }
        return symbols.isEmpty ? "fn" : symbols + " fn"
    }

    private static func previousMemory(pid: pid_t, element: AXUIElement?) -> Memory? {
        guard let last, last.pid == pid, Date().timeIntervalSince(last.at) < 30,
              last.keystrokes == KeyboardTap.keystrokes else { return nil }
        if let element, let previous = last.element, !CFEqual(element, previous) { return nil }
        return last
    }

    /// Secours quand le texte du champ est illisible : collage confirmé dans ce champ précis,
    /// sans frappe ni clic depuis. Deux conversations peuvent partager le même processus.
    static func recentPaste(pid: pid_t?, element: AXUIElement?) -> String? {
        guard let pid, let element, let last = previousMemory(pid: pid, element: element),
              last.element != nil else { return nil }
        return last.text
    }

    /// ⌘V comme au clavier : ⌘ enfoncée, V, puis ⌘ relâchée, envoyés au système (l'app au premier plan, vérifiée
    /// juste avant). Chrome et les apps Electron ignorent parfois un ⌘V adressé à leur processus ou porté par la
    /// seule touche V (régression du 13 octobre 2026 : texte absent du champ).
    /// Refus de coller : seulement un champ de mot de passe lu comme tel au moment du collage, ou, quand le champ ne se
    /// lit plus, celui d'un mot de passe au début de la dictée. La saisie sécurisée de macOS ne suffit plus : Chrome et
    /// les apps Electron la gardent après un champ de mot de passe, et une commande du terminal qui la demande est
    /// attribuée à l'app au premier plan. Le 6 novembre 2026, Codex (champ illisible) la tenait : 234 mots refusés.
    static func refusesSecure(context: DictationContext, field: InsertionField) -> Bool {
        field.isSecure || (context.isSecure && field.element == nil)
    }

    /// Raison du refus, pour le diagnostic : jamais de texte, seulement le rôle et l'app qui tient la saisie sécurisée.
    private static func logSecureRefusal(field: InsertionField, system: InsertionSystem, target pid: pid_t) {
        let held = system.secureInput()
        let holder = held ? system.secureInputHolder() : nil
        let by = holder.map { $0 == pid ? "app visée" : "autre app" } ?? (held ? "inconnue" : "aucune")
        log.notice("collage refusé : champ de mot de passe (lu=\(field.isSecure, privacy: .public)) saisie sécurisée=\(by, privacy: .public)")
    }

    /// PID annoncé par macOS pour la saisie sécurisée, nil sans saisie sécurisée ou sans réponse.
    nonisolated static func secureInputHolder() -> pid_t? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? NSNumber, pid.int32Value > 0 else { return nil }
        return pid.int32Value
    }

    @MainActor static func postCommandV() -> Bool {
        guard let events = pasteEvents() else { return false }
        for event in events { event.post(tap: .cghidEventTap) }
        return true
    }

    /// Maj pour envoyer : Entrée seule, sans modificateur, dans l'app qui vient de recevoir le texte et toujours au
    /// premier plan. Maj encore tenue après une seconde : rien n'est envoyé (⇧↩ ferait un retour à la ligne).
    @MainActor static func pressReturn(pid: pid_t) async -> Bool {
        // Le collage passe d'abord dans la file de l'app (page web, Electron).
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            log.notice("Entrée retenue : l'app du collage n'est plus au premier plan")
            return false
        }
        let held = await waitForModifierRelease(limit: 1)
        guard held == 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            log.notice("Entrée retenue : touches encore maintenues ou app changée")
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = KeyboardTap.syntheticMarker
        let returnKey: CGKeyCode = 0x24
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        // La touche synthétique n'est pas comptée par KeyboardTap : l'envoi peut vider le même champ.
        if last?.pid == pid { last = nil }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log.notice("Entrée envoyée après le collage (Maj pour envoyer)")
        return true
    }

    /// Touche Effacer, marquée comme ⌘V : l'écoute du clavier ne la compte pas comme une frappe.
    @MainActor static func postDeleteBackward() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = KeyboardTap.syntheticMarker
        let delete: CGKeyCode = 0x33
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: delete, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Marqués : l'écoute du clavier de Wispad les laisse passer sans les prendre pour une frappe.
    @MainActor static func pasteEvents() -> [CGEvent]? {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = KeyboardTap.syntheticMarker
        let command: CGKeyCode = 0x37
        let key = KeyboardLayout.keyCode(for: "v") ?? 9
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else { return nil }
        commandDown.flags = .maskCommand
        down.flags = .maskCommand
        up.flags = .maskCommand
        commandUp.flags = []
        return [commandDown, down, up, commandUp]
    }
}
