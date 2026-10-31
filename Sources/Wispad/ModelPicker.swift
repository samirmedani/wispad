import SwiftUI
import WispadCore

/// Choix ouvert dans le sélecteur de modèle.
enum ModelPickerKind: String, Identifiable, Hashable {
    case voice, voiceRelay, correction, correctionRelay

    var id: String { rawValue }
    var isCorrection: Bool { self == .correction || self == .correctionRelay }
}

/// Où la saisie d'une clé est ouverte dans Fournisseurs : une seule à la fois.
enum KeyEntryHost: Equatable {
    /// Clés API › Ajouter une clé.
    case keys
    /// Vue d'ensemble, pour ce fournisseur s'il est connu.
    case overview(String?)
    /// Mots appris : la clé TypeSafe de Jev.
    case learning
    /// Sélecteur de modèle, dans le groupe de ce fournisseur.
    case picker(String)
}

/// Sélecteur de modèle : une feuille de cartes groupées par fournisseur (pastille, nom, état de la clé). Chaque carte
/// donne le nom du modèle, ce qui le distingue (recommandé, le moins cher), sa rapidité et son prix ; le choix en
/// cours est mis en avant. Un modèle dont la clé n'est pas active est grisé, et son fournisseur propose d'ajouter ou
/// de rallumer la clé sur place. Choisir applique et ferme, avec les règles des choix d'`AppModel`.
struct ModelPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interactionReduceMotion) private var reduceMotion
    var kind: ModelPickerKind
    var snapshot: ProvidersSnapshot
    @Binding var keyEntry: KeyEntryHost?
    /// Ouvre les réglages avancés, où se règle le modèle local.
    var openAdvanced: () -> Void = {}
    @State private var query = ""
    /// Latence médiane de chaque modèle chez toi, lue une fois à l'ouverture.
    @State private var latencies: [String: Int]?
    @State private var expanded: Set<String> = []

    #if DEBUG
    /// Aperçus : listes dépliées sans clic, et feuille assez haute pour tout montrer.
    var previewExpanded: Set<String> = []
    var previewHeight: CGFloat?
    #endif

    private var height: CGFloat {
        #if DEBUG
        if let previewHeight { return previewHeight }
        #endif
        return kind.isCorrection ? 580 : (kind == .voice ? 470 : 400)
    }

    private var directory: TextModelDirectory { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if kind.isCorrection {
                        correctionContent
                    } else {
                        voiceContent
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 640, height: height)
        .background(Theme.canvas)
        .onAppear {
            if latencies == nil, kind.isCorrection { latencies = TextModelCatalog.medianLatencies(model.usage) }
            #if DEBUG
            if !previewExpanded.isEmpty { expanded = previewExpanded }
            #endif
        }
        .task {
            guard kind.isCorrection else { return }
            await directory.refresh(keys: model.cleanupKeys)
            // Les modèles d'un serveur local changent dès qu'on en télécharge un : relus à chaque ouverture.
            if let local = model.key(CleanupModel.localAccount) {
                await directory.refresh(keys: [CleanupModel.localAccount: local], force: true)
            }
        }
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(symbol: symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(String(localized: "Fermer"), systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(HoverButtonStyle(treatment: .icon))
                    .help(String(localized: "Fermer"))
                    .keyboardShortcut(.cancelAction)
            }
            if kind.isCorrection {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "Chercher un modèle"), text: $query, prompt: Text("Chercher un modèle"))
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button(String(localized: "Effacer"), systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
            }
        }
        .padding(20)
    }

    private var title: String {
        switch kind {
        case .voice: return String(localized: "Modèle de la voix")
        case .voiceRelay: return String(localized: "Relais de la voix")
        case .correction: return String(localized: "Modèle de correction")
        case .correctionRelay: return String(localized: "Relais de la correction")
        }
    }

    private var subtitle: String {
        switch kind {
        case .voice:
            return String(localized: "Ta voix part chez ce fournisseur, qui la transcrit pendant que tu parles.")
        case .voiceRelay:
            return String(localized: "Prend la main si \(snapshot.voice.provider.displayName) ne répond pas : la même dictée part chez lui.")
        case .correction:
            return String(localized: "Ponctuation, mots mal entendus, mise en forme. Seul le texte part, jamais l'audio.")
        case .correctionRelay:
            return snapshot.primary.map { String(localized: "Prend la main si \($0.provider) ne répond pas.") }
                ?? String(localized: "Prend la main si le premier modèle ne répond pas.")
        }
    }

    private var symbol: String {
        switch kind {
        case .voice: return "waveform"
        case .correction: return "wand.and.stars"
        case .voiceRelay, .correctionRelay: return "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch kind {
        case .voice: return Theme.brand
        case .correction: return .purple
        case .voiceRelay, .correctionRelay: return OverlayStyle.relay
        }
    }

    /// Applique le choix, puis ferme.
    private func pick(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : Theme.spring) { action() }
        dismiss()
    }

    // MARK: Voix

    @ViewBuilder private var voiceContent: some View {
        let provider = snapshot.voice.provider
        if kind == .voiceRelay {
            let off = snapshot.voiceRelay == nil
            ModelCard(symbol: "minus.circle", title: String(localized: "Aucun relais"),
                      lines: [String(localized: "Si \(provider.displayName) ne répond pas, la dictée reste dans l'historique pour la retranscrire.")],
                      selected: off, enabled: true, minHeight: 0) {
                pick { model.chooseVoiceRelay(AppSettings.voiceRelayOff) }
            }
        }
        ForEach(kind == .voice ? ProviderID.allCases : [provider.other]) { item in
            ProviderGroup(account: item.rawValue, snapshot: snapshot, keyEntry: $keyEntry, openAdvanced: openAdvanced) {
                CardGrid(items: ProviderCatalog.models(for: item)) { speech in
                    ModelCard(title: speech.displayName, badges: badges(speech), lines: lines(speech),
                              selected: isSelected(speech), enabled: snapshot.active.contains(item.rawValue)) {
                        pick {
                            if kind == .voice {
                                model.chooseVoice(item, model: speech.id)
                            } else {
                                model.chooseVoiceRelay(speech.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func isSelected(_ speech: SpeechModel) -> Bool {
        kind == .voice ? snapshot.voice == speech : snapshot.voiceRelay == speech
    }

    /// Recommandé : xAI pour la voix, le modèle d'origine de l'autre fournisseur pour son relais. Économique : 0,25 $
    /// de l'heure au plus.
    private func badges(_ speech: SpeechModel) -> [CardBadge] {
        let recommended = kind == .voice ? speech.provider == .xai && speech.recommended : speech.id == speech.provider.defaultLiveModel
        return (recommended ? [.recommended] : []) + (speech.streamingUSDPerHour <= 0.25 ? [.economical] : [])
    }

    private func lines(_ speech: SpeechModel) -> [String] {
        var lines = [String(localized: "\(MoneyFormat.price(speech.streamingUSDPerHour)) par heure de dictée")]
        if snapshot.verifyWithFile, kind == .voice {
            lines.append(String(localized: "Vérification : + \(MoneyFormat.price(speech.batchUSDPerHour))/h"))
        }
        return lines
    }

    // MARK: Correction

    private var selection: CleanupChoice {
        kind == .correction ? snapshot.cleanupChoice : snapshot.displayedCleanupRelay
    }

    /// Modèle déjà en premier : il ne se choisit pas comme relais.
    private var excluded: CleanupChoice? {
        guard kind == .correctionRelay, let primary = snapshot.primary else { return nil }
        return CleanupChoice(providerName: primary.provider, model: primary.model)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ViewBuilder private var correctionContent: some View {
        let searching = !trimmedQuery.isEmpty
        if !searching {
            if kind == .correction {
                ModelCard(symbol: "sparkles", title: String(localized: "Automatique"),
                          lines: [String(localized: "Wispad choisit selon tes clés.")]
                            + (snapshot.automatic.map { [String(localized: "Maintenant : \($0.readable)")] } ?? []),
                          selected: selection == .automatic, enabled: true, minHeight: 0) {
                    pick { model.chooseCleanup(.automatic) }
                }
            } else {
                ModelCard(symbol: "minus.circle", title: String(localized: "Aucun relais"),
                          lines: [snapshot.primary.map { String(localized: "Si \($0.provider) ne répond pas, le texte est collé sans correction.") }
                                  ?? String(localized: "Si le premier modèle ne répond pas, le texte est collé sans correction.")],
                          selected: selection == .off, enabled: true, minHeight: 0) {
                    pick { model.chooseCleanupRelay(.off) }
                }
            }
        }
        let groups = CleanupChoice.accounts.map { ModelGroup(account: $0, models: sortedModels($0)) }
        let matches = groups.map { ModelGroup(account: $0.account, models: $0.models.filter(matchesQuery)) }
        if searching, matches.allSatisfy({ $0.models.isEmpty }) {
            Text("Aucun modèle ne correspond à « \(trimmedQuery) ».")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 30)
        }
        ForEach(searching ? matches.filter { !$0.models.isEmpty } : groups) { group in
            ProviderGroup(account: group.account, snapshot: snapshot, keyEntry: $keyEntry, openAdvanced: openAdvanced) {
                if searching {
                    ModelList(models: group.models, row: row)
                } else {
                    correctionGroup(group.account, all: group.models)
                }
            }
        }
    }

    @ViewBuilder
    private func correctionGroup(_ account: String, all: [TextModel]) -> some View {
        let active = snapshot.active.contains(account)
        // Sans clé active : les modèles d'origine, grisés, pour montrer ce que la clé donnerait.
        let featured = active ? all.filter { $0.isRecommended || (account == CleanupModel.localAccount && all.count <= 6) }
            : TextModelCatalog.defaults(account: account)
        if !featured.isEmpty {
            CardGrid(items: featured) { item in card(item, enabled: active) }
        }
        if active, all.isEmpty {
            Text(String(localized: "Aucun modèle trouvé"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if active, all.count > featured.count {
            let name = ProviderName.of(account)
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(account) },
                set: { if $0 { expanded.insert(account) } else { expanded.remove(account) } }
            )) {
                ModelList(models: all, grouped: true, latencies: latencies ?? [:], row: row)
                    .padding(.top, 4)
            } label: {
                Text(String(localized: "Tous les modèles \(name) (\(all.count))"))
                    .font(.system(size: 12.5, weight: .medium))
            }
        }
    }

    private func card(_ item: TextModel, enabled: Bool) -> some View {
        let name = CleanupModelText.name(item.model)
        let isExcluded = item.choice == excluded
        return ModelCard(
            title: name,
            code: name == item.model ? nil : item.model,
            badges: badges(item),
            lines: [CleanupModelText.speed(item.model, measured: latencies?[item.model]),
                    CleanupModelText.price(item.model, account: item.account)],
            note: isExcluded ? String(localized: "Déjà en premier") : nil,
            selected: item.choice == selection,
            enabled: enabled && !isExcluded
        ) {
            choose(item.choice)
        }
    }

    private func row(_ item: TextModel) -> ModelListRow {
        let isExcluded = item.choice == excluded
        return ModelListRow(
            model: item.model,
            detail: rowDetail(item),
            note: isExcluded ? String(localized: "déjà en premier") : nil,
            selected: item.choice == selection,
            enabled: !isExcluded
        ) {
            choose(item.choice)
        }
    }

    /// Rapidité et prix. Dans la liste groupée, la rapidité devinée est déjà le titre du groupe : seule une latence
    /// mesurée chez toi s'ajoute au prix. La recherche montre une liste à plat, avec la rapidité.
    private func rowDetail(_ item: TextModel) -> String {
        let price = CleanupModelText.price(item.model, account: item.account)
        let measured = latencies?[item.model]
        if measured == nil, trimmedQuery.isEmpty { return price }
        return "\(CleanupModelText.speed(item.model, measured: measured)) · \(price)"
    }

    private func choose(_ choice: CleanupChoice) {
        pick {
            if kind == .correction {
                model.chooseCleanup(choice)
            } else {
                model.chooseCleanupRelay(choice)
            }
        }
    }

    /// Recommandé : DeepSeek pour la correction, OpenAI gpt-5.4-mini pour son relais. Économique : moins de 0,10 $
    /// pour 100 dictées, ou gratuit sur ce Mac.
    private func badges(_ item: TextModel) -> [CardBadge] {
        var badges: [CardBadge] = []
        if item.choice == (kind == .correction ? CleanupChoice.deepSeekFlash : CleanupChoice.openAIMini) {
            badges.append(.recommended)
        }
        if item.account == CleanupModel.localAccount || (TextModelCatalog.costPerHundred(item.model) ?? .infinity) < 0.1 {
            badges.append(.economical)
        }
        return badges
    }

    /// Modèles de texte d'un compte, du plus utile au moins utile ; le modèle choisi y reste même si le fournisseur
    /// ne le propose plus.
    private func sortedModels(_ account: String) -> [TextModel] {
        guard snapshot.active.contains(account) else { return [] }
        var models = directory.models(account: account)
        if selection.account == account, let chosen = selection.model, !models.contains(where: { $0.model == chosen }) {
            models.append(TextModel(account: account, model: chosen))
        }
        return TextModelCatalog.sorted(models, latencies: latencies ?? [:])
    }

    private func matchesQuery(_ item: TextModel) -> Bool {
        let needle = trimmedQuery
        guard !needle.isEmpty else { return true }
        return item.model.localizedCaseInsensitiveContains(needle) || CleanupModelText.name(item.model).localizedCaseInsensitiveContains(needle)
    }
}

// MARK: - Éléments du sélecteur

/// Modèles de texte d'un compte, dans l'ordre du sélecteur.
private struct ModelGroup: Identifiable {
    var account: String
    var models: [TextModel]

    var id: String { account }
}

/// Un fournisseur dans le sélecteur : pastille, nom, état de la clé et ce qu'il faut pour la rendre utilisable.
private struct ProviderGroup<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var account: String
    var snapshot: ProvidersSnapshot
    @Binding var keyEntry: KeyEntryHost?
    var openAdvanced: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderTile(account: account, size: 26)
                Text(ProviderName.of(account))
                    .font(.system(size: 14, weight: .semibold))
                status
                Spacer(minLength: 8)
                action
            }
            if keyEntry == .picker(account) {
                KeyEntryForm(expected: account) { keyEntry = nil }
                    .padding(12)
                    .card(radius: 12)
            }
            content
        }
    }

    private var isLocal: Bool { account == CleanupModel.localAccount }

    @ViewBuilder private var status: some View {
        if snapshot.active.contains(account) {
            StatusChip(text: isLocal ? String(localized: "Sur ce Mac") : String(localized: "Clé active"), tint: .green)
        } else if snapshot.stored.contains(account) {
            StatusChip(text: isLocal ? String(localized: "Coupé") : String(localized: "Clé coupée"), tint: .orange)
        } else {
            StatusChip(text: isLocal ? String(localized: "Pas réglé") : String(localized: "Aucune clé"), tint: .secondary)
        }
    }

    @ViewBuilder private var action: some View {
        if snapshot.active.contains(account) {
            EmptyView()
        } else if snapshot.stored.contains(account) {
            Button(String(localized: "Rallumer")) { model.setKeyEnabled(account, true) }
                .hoverFeedback()
        } else if isLocal {
            Button(String(localized: "Régler le modèle local")) {
                dismiss()
                openAdvanced()
            }
            .hoverFeedback()
        } else if snapshot.readOnlyKeys {
            Text("À ajouter dans ta source de clés")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if keyEntry != .picker(account) {
            Button(String(localized: "Ajouter la clé")) {
                model.keysMessage = nil
                keyEntry = .picker(account)
            }
            .buttonStyle(.borderedProminent)
            .hoverFeedback()
        }
    }
}

/// Deux cartes par ligne, de même hauteur.
private struct CardGrid<Item: Identifiable, Card: View>: View {
    var items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        VStack(spacing: 12) {
            ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
                HStack(alignment: .top, spacing: 12) {
                    card(items[start])
                    if start + 1 < items.count {
                        card(items[start + 1])
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Ce qui distingue un modèle, en pastille sur sa carte.
enum CardBadge: Hashable {
    case recommended
    case economical

    var text: String {
        switch self {
        case .recommended: return String(localized: "Recommandé")
        case .economical: return String(localized: "Économique")
        }
    }

    var tint: Color {
        switch self {
        case .recommended: return Theme.brand
        case .economical: return .green
        }
    }
}

/// Carte d'un modèle : nom, pastilles, rapidité et prix. Le choix en cours a le bord et la coche de la marque ; un
/// modèle indisponible est grisé.
struct ModelCard: View {
    var symbol: String?
    var title: String
    /// Identifiant chez le fournisseur, quand le nom affiché est un nom lisible.
    var code: String?
    var badges: [CardBadge] = []
    var lines: [String] = []
    var note: String?
    var selected: Bool
    var enabled: Bool
    var minHeight: CGFloat = 96
    var action: () -> Void
    @State private var hovering = false

    init(symbol: String? = nil, title: String, code: String? = nil, badges: [CardBadge] = [], lines: [String] = [],
         note: String? = nil, selected: Bool, enabled: Bool, minHeight: CGFloat = 96, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.code = code
        self.badges = badges
        self.lines = lines
        self.note = note
        self.selected = selected
        self.enabled = enabled
        self.minHeight = minHeight
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? Theme.brand : Color.secondary)
                        .frame(width: 24)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(2)
                        if let code {
                            Text(verbatim: code)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    if !badges.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(badges, id: \.self) { badge in
                                Text(badge.text)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(badge.tint)
                                    .padding(.horizontal, 7)
                                    .frame(height: 18)
                                    .background(Capsule().fill(badge.tint.opacity(0.12)))
                            }
                        }
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let note {
                        Text(verbatim: note)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Theme.brand : Color.secondary.opacity(0.35))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.07) : Theme.card)
                    .shadow(color: Theme.cardShadow, radius: 4, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(border, lineWidth: selected ? 1.6 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(verbatim: ([title] + badges.map(\.text) + lines).joined(separator: ", ")))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var border: Color {
        if selected { return Theme.brand }
        return hovering && enabled ? Theme.brand.opacity(0.4) : Theme.cardBorder
    }
}

/// Liste compacte de modèles : par rapidité si `grouped`, chacun avec sa rapidité et son prix.
private struct ModelList: View {
    var models: [TextModel]
    var grouped = false
    var latencies: [String: Int] = [:]
    var row: (TextModel) -> ModelListRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if grouped {
                ForEach(TextModel.Speed.allCases, id: \.self) { speed in
                    let group = models.filter { TextModelCatalog.speed($0.model, measuredMilliseconds: latencies[$0.model]) == speed }
                    if !group.isEmpty {
                        Text(speed.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .padding(.leading, 10)
                        ForEach(group) { row($0) }
                    }
                }
            } else {
                ForEach(models) { row($0) }
            }
        }
        .padding(6)
        .card(radius: 12)
    }
}

/// Une ligne de la liste complète : coche, identifiant du modèle, rapidité et prix.
struct ModelListRow: View {
    var model: String
    var detail: String
    var note: String?
    var selected: Bool
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.brand : Color.secondary.opacity(0.35))
                Text(verbatim: model)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                if let note {
                    Text(verbatim: note)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Theme.brand.opacity(0.08) : hovering && enabled ? Theme.subtleFill : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
