import CoreGraphics
import Foundation
import Testing
@testable import WispadCore

/// La bulle face aux écrans (`OverlayScreen`, `OverlayGeometry.screen`, `bottomCenter`, `isLost`) : écran externe
/// branché ou débranché, autre résolution ou échelle, autre écran principal, Dock et barre des menus masqués, aucun
/// écran, rectangles abîmés ou démesurés. Géométrie pure : les mêmes règles servent à `OverlayController`.
struct OverlayScreenTests {
    /// Tailles réelles de la bulle (`OverlayLayout.contentSize`) : spectre, mains libres, message, carte Copier / Coller,
    /// mot appris.
    static let sizes = [CGSize(width: 86, height: 30), CGSize(width: 162, height: 30), CGSize(width: 470, height: 30),
                        CGSize(width: 420, height: 122), CGSize(width: 470, height: 112)]

    /// Écran de test : cadre, puis zone utile sans la barre des menus (en haut) ni le Dock (en bas).
    static func screen(_ id: UInt32, _ frame: CGRect, menuBar: CGFloat = 0, dock: CGFloat = 0) throws -> OverlayScreen {
        let visible = CGRect(x: frame.minX, y: frame.minY + dock, width: frame.width, height: frame.height - dock - menuBar)
        return try #require(OverlayScreen(id: id, frame: frame, visible: visible))
    }

    /// MacBook (barre des menus de 33 points, Dock de 72) et écran externe à sa droite.
    static func desk() throws -> (builtIn: OverlayScreen, external: OverlayScreen) {
        (try screen(1, CGRect(x: 0, y: 0, width: 1512, height: 982), menuBar: 33, dock: 72),
         try screen(2, CGRect(x: 1512, y: 0, width: 1920, height: 1080), menuBar: 25))
    }

    static func bubble(_ point: CGPoint, _ size: CGSize) -> CGRect {
        OverlayGeometry.bubble(bottomCenter: point, contentSize: size)
    }

    /// Entière sur l'écran, au demi-point près (la fenêtre de la bulle est posée sur des points entiers).
    static func isWhole(_ bubble: CGRect, on screen: OverlayScreen) -> Bool {
        screen.frame.insetBy(dx: -0.5, dy: -0.5).contains(bubble)
    }

    // MARK: Scénarios

    /// Écran externe débranché pendant une dictée, puis rebranché : jamais l'écran disparu, la bulle entière sur celui
    /// qui reste, et la place choisie retrouvée telle quelle avec son écran.
    @Test func anUnpluggedScreenIsNeverAimedAtAndItsPlaceComesBack() throws {
        let (builtIn, external) = try Self.desk()
        let anchor = OverlayAnchor(x: 0.5, y: 0.9)
        let size = CGSize(width: 470, height: 30)
        let pointer = CGPoint(x: 2_400, y: 500)
        let shownOn = try #require(OverlayGeometry.screen(among: [builtIn, external], zone: nil, shownOn: nil, shownAt: nil,
                                                          pointer: pointer, main: 1))
        #expect(shownOn == external)
        let first = OverlayGeometry.bottomCenter(on: external, anchor: anchor, contentSize: size, dockShown: false, zone: nil)
        #expect(Self.isWhole(Self.bubble(first, size), on: external))

        // Débranché : ni son numéro, ni la place de la bulle, ni le pointeur resté à ses coordonnées, ni l'ancien écran
        // principal ne le visent.
        let after = try #require(OverlayGeometry.screen(among: [builtIn], zone: nil, shownOn: 2, shownAt: first,
                                                        pointer: pointer, main: 2))
        #expect(after == builtIn)
        let moved = OverlayGeometry.bottomCenter(on: builtIn, anchor: anchor, contentSize: size, dockShown: true, zone: nil)
        #expect(Self.isWhole(Self.bubble(moved, size), on: builtIn))

        // Rebranché pendant la même dictée : la bulle reste sur l'écran où elle est.
        let during = OverlayGeometry.screen(among: [builtIn, external], zone: nil, shownOn: 1, shownAt: moved,
                                            pointer: pointer, main: 1)
        #expect(during == builtIn)
        // Bulle suivante, pointeur sur l'écran revenu : même place qu'avant le débranchement.
        let back = try #require(OverlayGeometry.screen(among: [builtIn, external], zone: nil, shownOn: nil, shownAt: nil,
                                                       pointer: pointer, main: 1))
        #expect(back == external)
        #expect(OverlayGeometry.bottomCenter(on: back, anchor: anchor, contentSize: size, dockShown: false, zone: nil) == first)
    }

    /// L'écran externe devient l'écran principal : toutes les coordonnées changent. La bulle reste sur son écran,
    /// retrouvé par son numéro, à la même place sur lui, alors que son ancienne position ne tombe plus sur lui.
    @Test func aNewMainScreenKeepsTheBubbleOnItsScreen() throws {
        let (builtIn, external) = try Self.desk()
        let size = CGSize(width: 86, height: 30)
        let before = OverlayGeometry.bottomCenter(on: external, anchor: nil, contentSize: size, dockShown: false, zone: nil)
        let externalMain = try Self.screen(2, CGRect(x: 0, y: 0, width: 1920, height: 1080), menuBar: 25)
        let builtInLeft = try Self.screen(1, CGRect(x: -1512, y: 0, width: 1512, height: 982), menuBar: 33, dock: 72)
        let screens = [externalMain, builtInLeft]
        let underOldPlace = screens.first { $0.frame.contains(before) }
        #expect(underOldPlace != externalMain)
        let chosen = OverlayGeometry.screen(among: screens, zone: nil, shownOn: 2, shownAt: before,
                                            pointer: CGPoint(x: -700, y: 400), main: 1)
        #expect(chosen == externalMain)
        let after = OverlayGeometry.bottomCenter(on: externalMain, anchor: nil, contentSize: size, dockShown: false, zone: nil)
        #expect(after.x - externalMain.frame.minX == before.x - external.frame.minX)
        #expect(after.y - externalMain.frame.minY == before.y - external.frame.minY)
    }

    /// Autre résolution ou autre échelle : même écran, autres dimensions. La place choisie reste la même fraction de la
    /// zone utile, la place par défaut reste au centre au-dessus du Dock, la bulle entière.
    @Test func aResolutionOrScaleChangeKeepsTheChosenPlace() throws {
        let anchor = OverlayAnchor(x: 0.25, y: 0.75)
        let size = CGSize(width: 420, height: 122)
        for frame in [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 0, width: 1800, height: 1169),
                      CGRect(x: 0, y: 0, width: 1024, height: 665), CGRect(x: 0, y: 0, width: 3024, height: 1964)] {
            let screen = try Self.screen(1, frame, menuBar: 33, dock: 72)
            let chosen = OverlayGeometry.bottomCenter(on: screen, anchor: anchor, contentSize: size, dockShown: true, zone: nil)
            #expect(Self.isWhole(Self.bubble(chosen, size), on: screen))
            let span = screen.visible.width - 2 * OverlayGeometry.edgeGap - size.width
            #expect(abs((chosen.x - screen.visible.minX - OverlayGeometry.edgeGap - size.width / 2) / span - 0.25) < 0.01)
            let standard = OverlayGeometry.bottomCenter(on: screen, anchor: nil, contentSize: size, dockShown: true, zone: nil)
            #expect(standard == CGPoint(x: frame.midX, y: 72 + OverlayGeometry.dockGap))
        }
    }

    /// Barre des menus et Dock masqués : la zone utile est l'écran entier. En haut comme en bas, la bulle garde sa marge.
    @Test func hiddenMenuBarAndDockKeepTheBubbleInside() throws {
        let screen = try Self.screen(1, CGRect(x: 0, y: 0, width: 1512, height: 982))
        for size in Self.sizes {
            let top = OverlayGeometry.bottomCenter(on: screen, anchor: OverlayAnchor(x: 0.5, y: 1), contentSize: size,
                                                   dockShown: false, zone: nil)
            #expect(top.y + size.height == 982 - OverlayGeometry.edgeGap)
            let standard = OverlayGeometry.bottomCenter(on: screen, anchor: nil, contentSize: size, dockShown: false, zone: nil)
            #expect(standard.y == OverlayGeometry.screenGap)
            #expect(Self.isWhole(Self.bubble(top, size), on: screen) && Self.isWhole(Self.bubble(standard, size), on: screen))
        }
    }

    /// Sans écran (Mac sans moniteur, reconfiguration en cours) : rien à viser, et la bulle n'est pas « perdue », pour
    /// ne pas la replacer en boucle.
    @Test func withoutAnyScreenNothingIsAimedAt() {
        #expect(OverlayGeometry.screen(among: [], zone: CGRect(x: 0, y: 0, width: 600, height: 80), shownOn: 1,
                                       shownAt: .zero, pointer: .zero, main: 1) == nil)
        #expect(!OverlayGeometry.isLost(CGRect(x: 50_000, y: 0, width: 470, height: 30), among: []))
    }

    /// Une bulle sortie de tous les écrans est perdue ; à moitié sur un écran, elle ne l'est pas.
    @Test func aBubbleOutsideEveryScreenIsLost() throws {
        let (builtIn, external) = try Self.desk()
        #expect(OverlayGeometry.isLost(CGRect(x: 4_000, y: 100, width: 470, height: 30), among: [builtIn, external]))
        #expect(OverlayGeometry.isLost(CGRect(x: 1_600, y: 100, width: 470, height: 30), among: [builtIn]))
        #expect(!OverlayGeometry.isLost(CGRect(x: 1_300, y: 100, width: 470, height: 30), among: [builtIn]))
        #expect(OverlayGeometry.isLost(CGRect(x: CGFloat.nan, y: 100, width: 470, height: 30), among: [builtIn]))
        #expect(OverlayGeometry.isLost(.null, among: [builtIn]))
    }

    /// Cadre vide, nul, infini, NaN ou démesuré : pas un écran. Zone utile abîmée ou hors du cadre : l'écran entier, ou
    /// sa partie dans le cadre.
    @Test func damagedRectanglesAreNotScreens() throws {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        for damaged in [CGRect.null, .infinite, .zero, CGRect(x: 0, y: 0, width: 0.5, height: 982),
                        CGRect(x: CGFloat.nan, y: 0, width: 1512, height: 982), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 982),
                        CGRect(x: 1e300, y: 1e300, width: 1e300, height: 1e300), CGRect(x: 0, y: 0, width: 2e6, height: 982),
                        CGRect(x: -2e6, y: 0, width: 1512, height: 982)] {
            #expect(OverlayScreen(id: 1, frame: damaged, visible: frame) == nil)
            #expect(OverlayScreen(id: 1, frame: frame, visible: damaged)?.visible == frame)
        }
        let flipped = try #require(OverlayScreen(id: 1, frame: CGRect(x: 1512, y: 982, width: -1512, height: -982), visible: .zero))
        #expect(flipped.frame == frame && flipped.visible == frame)
        let overflowing = try #require(OverlayScreen(id: 1, frame: frame, visible: CGRect(x: -100, y: 72, width: 2_000, height: 2_000)))
        #expect(overflowing.visible == CGRect(x: 0, y: 72, width: 1512, height: 910))
        let ordinary = CGRect(x: 0.5, y: 72.5, width: 1511.5, height: 876.25)
        #expect(OverlayScreen(id: 1, frame: frame, visible: ordinary)?.visible == ordinary)
    }

    /// Dock ou barre des menus changés : mêmes écrans. Écran déplacé, redimensionné, renuméroté, ajouté ou retiré : autres
    /// écrans.
    @Test func sameDisplaysIgnoresTheDockAndTheMenuBar() throws {
        let (builtIn, external) = try Self.desk()
        let dockHidden = try Self.screen(1, builtIn.frame, menuBar: 33)
        #expect(OverlayScreen.sameDisplays([builtIn, external], [dockHidden, external]))
        #expect(!OverlayScreen.sameDisplays([builtIn, external], [builtIn]))
        #expect(!OverlayScreen.sameDisplays([builtIn, external], [external, builtIn]))
        #expect(!OverlayScreen.sameDisplays([builtIn], [try Self.screen(1, CGRect(x: 0, y: 0, width: 1800, height: 1169))]))
        #expect(!OverlayScreen.sameDisplays([builtIn], [try Self.screen(3, builtIn.frame, menuBar: 33, dock: 72)]))
        #expect(OverlayScreen.sameDisplays([], []))
    }

    /// Zone de saisie lue d'une autre app, abîmée (NaN, infinie, démesurée) : ignorée, la bulle reste à sa place.
    @Test func aDamagedInputZoneLeavesTheBubbleInPlace() throws {
        let (builtIn, _) = try Self.desk()
        let size = CGSize(width: 470, height: 30)
        let standard = OverlayGeometry.bottomCenter(on: builtIn, anchor: nil, contentSize: size, dockShown: true, zone: nil)
        for zone in [CGRect.null, .infinite, CGRect(x: CGFloat.nan, y: 80, width: 600, height: 60),
                     CGRect(x: 456, y: -CGFloat.infinity, width: 600, height: 60), CGRect(x: 0, y: 70, width: CGFloat.infinity, height: 60),
                     CGRect(x: -1e300, y: 70, width: 1e301, height: 60)] {
            #expect(OverlayGeometry.bottomCenter(on: builtIn, anchor: nil, contentSize: size, dockShown: true, zone: zone) == standard)
            #expect(OverlayGeometry.screen(among: [builtIn], zone: zone, shownOn: nil, shownAt: nil, pointer: nil, main: nil) == builtIn)
        }
    }

    // MARK: Propriétés

    /// Écrans côte à côte, de gauche à droite et décalés en hauteur, comme macOS les range : jamais superposés.
    /// Barre des menus parfois masquée, Dock en bas, à gauche, à droite ou masqué ; tailles réelles, écran fantôme compris.
    static func arrangement(_ g: inout SeededGenerator, count: Int, firstID: UInt32 = 1) -> [OverlayScreen] {
        let sizes = [(1280, 800), (1440, 900), (1470, 956), (1512, 982), (1728, 1117), (1920, 1080), (2560, 1440),
                     (3008, 1692), (3840, 2160), (1024, 768), (640, 480), (1080, 1920), (1800, 1169)]
        var x = CGFloat(g.int(-4_000...0))
        var screens: [OverlayScreen] = []
        for index in 0..<count {
            let size = g.pick(sizes)
            let frame = CGRect(x: x, y: CGFloat(g.int(-size.1 / 2...size.1 / 2)), width: CGFloat(size.0), height: CGFloat(size.1))
            x += frame.width
            let menuBar = CGFloat(g.pick([0, 24, 25, 33, 37, 43]))
            let dock = CGFloat(g.pick([0, 0, 4, 48, 72, 128]))
            var visible = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - menuBar)
            switch g.int(0...2) {
            case 0: visible = CGRect(x: visible.minX, y: visible.minY + dock, width: visible.width, height: visible.height - dock)
            case 1: visible = CGRect(x: visible.minX + dock, y: visible.minY, width: visible.width - dock, height: visible.height)
            default: visible = CGRect(x: visible.minX, y: visible.minY, width: visible.width - dock, height: visible.height)
            }
            if let screen = OverlayScreen(id: firstID + UInt32(index), frame: frame, visible: visible) { screens.append(screen) }
        }
        return screens
    }

    /// Rectangle quelconque : ordinaire, retourné, vide, nul, infini, NaN ou démesuré.
    static func anyRect(_ g: inout SeededGenerator) -> CGRect {
        let specials: [CGFloat] = [.nan, .infinity, -.infinity, 0, -0.0, 0.4, 1e300, -1e300, .greatestFiniteMagnitude, 2e6, -2e6]
        func value(_ g: inout SeededGenerator, _ range: ClosedRange<Int>) -> CGFloat {
            g.chance(20) ? g.pick(specials) : CGFloat(g.int(range))
        }
        switch g.int(0...11) {
        case 0: return .null
        case 1: return .infinite
        case 2: return .zero
        default:
            return CGRect(x: value(&g, -6_000...6_000), y: value(&g, -3_000...3_000),
                          width: value(&g, -4_000...4_000), height: value(&g, -2_500...2_500))
        }
    }

    static func anyPoint(_ g: inout SeededGenerator) -> CGPoint? {
        switch g.int(0...9) {
        case 0: return nil
        case 1: return CGPoint(x: CGFloat.nan, y: 0)
        case 2: return CGPoint(x: CGFloat.infinity, y: -1e300)
        default: return CGPoint(x: CGFloat(g.int(-8_000...8_000)), y: CGFloat(g.int(-3_000...3_000)))
        }
    }

    static func point(in screen: OverlayScreen, _ g: inout SeededGenerator) -> CGPoint {
        CGPoint(x: screen.frame.minX + CGFloat(g.int(0...Int(screen.frame.width) - 1)),
                y: screen.frame.minY + CGFloat(g.int(0...Int(screen.frame.height) - 1)))
    }

    /// Zone de saisie : aucune, champ ordinaire près du bas de l'écran choisi, n'importe où, ou abîmée.
    static func zone(_ g: inout SeededGenerator, near screen: OverlayScreen?) -> CGRect? {
        switch g.int(0...3) {
        case 0: return nil
        case 1:
            guard let screen else { return nil }
            return CGRect(x: screen.frame.minX + CGFloat(g.int(0...600)), y: screen.frame.minY + CGFloat(g.int(0...300)),
                          width: CGFloat(g.int(2...900)), height: CGFloat(g.int(2...240)))
        default: return anyRect(&g)
        }
    }

    /// Jamais un écran débranché : parmi des écrans branchés, débranchés ou abîmés, avec une bulle, un pointeur, une
    /// saisie et un écran principal qui visent n'importe lequel, l'écran choisi est toujours l'un des écrans présents
    /// (nil seulement s'il n'y en a aucun).
    @Test func neverAimsAtAVanishedScreen() {
        forAll(5_000, seed: 0x4F56_5331, { g -> (present: [OverlayScreen], all: [OverlayScreen], zone: CGRect?, shownOn: UInt32?,
                                                 shownAt: CGPoint?, pointer: CGPoint?, main: UInt32?) in
            var all = Self.arrangement(&g, count: g.int(0...4))
            for _ in 0..<g.int(0...2) {
                if let damaged = OverlayScreen(id: UInt32(g.int(10...20)), frame: Self.anyRect(&g), visible: Self.anyRect(&g)) {
                    all.append(damaged)
                }
            }
            let present = all.filter { _ in g.chance(60) }
            let target = all.isEmpty ? nil : g.pick(all)
            let shownAt: CGPoint? = target.map { Self.point(in: $0, &g) } ?? Self.anyPoint(&g)
            let pointer: CGPoint? = g.chance(50) ? Self.anyPoint(&g) : target.map { Self.point(in: $0, &g) }
            return (present, all, Self.zone(&g, near: target), g.chance(70) ? target?.id : UInt32(g.int(0...30)), shownAt,
                    pointer, g.chance(50) ? target?.id : UInt32(g.int(0...30)))
        }) { sample in
            let chosen = OverlayGeometry.screen(among: sample.present, zone: sample.zone, shownOn: sample.shownOn,
                                                shownAt: sample.shownAt, pointer: sample.pointer, main: sample.main)
            guard let chosen else { return sample.present.isEmpty ? nil : "aucun écran choisi parmi \(sample.present.count)" }
            return sample.present.contains(chosen) ? nil : "écran \(chosen.id) absent de \(sample.present.map(\.id))"
        }
    }

    /// Toujours entière à l'écran : sur l'écran choisi, la bulle (spectre, message, carte, mot appris, ou toute taille
    /// qui tient dans sa zone utile), à sa place par défaut ou choisie, décalée ou non hors de la saisie, Dock affiché
    /// ou non, reste dans le cadre de cet écran, même posée sur des points entiers.
    @Test func theBubbleIsAlwaysWholeOnItsScreen() {
        forAll(5_000, seed: 0x4F56_5332, { g -> (screen: OverlayScreen, size: CGSize, anchor: OverlayAnchor?, dock: Bool, zone: CGRect?)? in
            let screens = Self.arrangement(&g, count: g.int(1...3))
            guard !screens.isEmpty else { return nil }
            let screen = g.pick(screens)
            let size = g.chance(50) ? g.pick(Self.sizes) : CGSize(width: CGFloat(g.int(1...900)), height: CGFloat(g.int(1...300)))
            return (screen, size, g.chance(30) ? nil : OverlayGeometryPropertyTests.anchor(&g), g.chance(50), Self.zone(&g, near: screen))
        }) { sample in
            guard let sample else { return nil }
            let gap = OverlayGeometry.edgeGap
            guard sample.size.width + 2 * gap <= sample.screen.visible.width,
                  sample.size.height + 2 * gap <= sample.screen.visible.height else { return nil }
            let point = OverlayGeometry.bottomCenter(on: sample.screen, anchor: sample.anchor, contentSize: sample.size,
                                                     dockShown: sample.dock, zone: sample.zone)
            // La fenêtre de la bulle est posée sur des points entiers (`OverlayLayout.panelFrame`).
            let posed = CGPoint(x: point.x.rounded(), y: point.y.rounded())
            for bubble in [Self.bubble(point, sample.size), Self.bubble(posed, sample.size)] where !Self.isWhole(bubble, on: sample.screen) {
                return "\(bubble) hors de \(sample.screen.frame) (zone utile \(sample.screen.visible))"
            }
            return nil
        }
    }

    /// Rien ne plante ni ne s'échappe : avec des écrans, des positions, une saisie, un pointeur quelconques (nuls,
    /// infinis, NaN, démesurés), la place rendue est toujours finie et dans les limites des coordonnées de macOS.
    @Test func damagedInputsNeverEscape() {
        forAll(5_000, seed: 0x4F56_5333, { g -> (screens: [OverlayScreen], zone: CGRect?, shownAt: CGPoint?, pointer: CGPoint?,
                                                 anchor: OverlayAnchor?, size: CGSize, dock: Bool) in
            var screens: [OverlayScreen] = []
            for index in 0..<g.int(0...4) {
                if let screen = OverlayScreen(id: UInt32(index), frame: Self.anyRect(&g), visible: Self.anyRect(&g)) {
                    screens.append(screen)
                }
            }
            return (screens, g.chance(80) ? Self.anyRect(&g) : nil, Self.anyPoint(&g), Self.anyPoint(&g),
                    g.chance(30) ? nil : OverlayGeometryPropertyTests.anchor(&g), g.pick(Self.sizes), g.chance(50))
        }) { sample in
            let limit = OverlayGeometry.coordinateLimit
            for screen in sample.screens {
                for rect in [screen.frame, screen.visible] where !(rect.minX >= -limit && rect.maxX <= limit && rect.minY >= -limit
                                                                   && rect.maxY <= limit && rect.width >= 1 && rect.height >= 1) {
                    return "écran \(screen.id) gardé avec \(rect)"
                }
                if !screen.frame.contains(screen.visible) { return "zone utile \(screen.visible) hors de \(screen.frame)" }
            }
            guard let chosen = OverlayGeometry.screen(among: sample.screens, zone: sample.zone, shownOn: nil, shownAt: sample.shownAt,
                                                      pointer: sample.pointer, main: nil) else {
                return sample.screens.isEmpty ? nil : "aucun écran choisi"
            }
            let point = OverlayGeometry.bottomCenter(on: chosen, anchor: sample.anchor, contentSize: sample.size,
                                                     dockShown: sample.dock, zone: sample.zone)
            guard point.x.isFinite, point.y.isFinite, abs(point.x) <= limit + 1_000, abs(point.y) <= limit + 1_000 else {
                return "point \(point) sur \(chosen.frame)"
            }
            _ = OverlayGeometry.isLost(Self.bubble(point, sample.size), among: sample.screens)
            return nil
        }
    }

    /// La place choisie revient avec son écran : sur un écran, la bulle est au même endroit avant qu'il soit débranché
    /// et après son retour, quels que soient les autres écrans branchés ou débranchés entre-temps, et l'écran disparu
    /// n'est jamais visé pendant son absence.
    @Test func aChosenPlaceComesBackWithItsScreen() {
        forAll(3_000, seed: 0x4F56_5334, { g -> (screens: [OverlayScreen], later: [OverlayScreen], index: Int, pointer: CGPoint,
                                                 anchor: OverlayAnchor?, size: CGSize, dock: Bool, zone: CGRect?)? in
            let screens = Self.arrangement(&g, count: g.int(1...4))
            guard !screens.isEmpty else { return nil }
            let index = g.int(0...(screens.count - 1))
            // Pendant l'absence, les autres écrans changent aussi (débranchés, autres résolutions, numéros nouveaux).
            let later = Self.arrangement(&g, count: g.int(0...3), firstID: 100).filter { _ in g.chance(70) }
            let pointer = Self.point(in: screens[index], &g)
            return (screens, later, index, pointer, g.chance(30) ? nil : OverlayGeometryPropertyTests.anchor(&g),
                    g.pick(Self.sizes), g.chance(50), Self.zone(&g, near: screens[index]))
        }) { sample in
            guard let sample else { return nil }
            let own = sample.screens[sample.index]
            func place(_ screens: [OverlayScreen]) -> (OverlayScreen, CGPoint)? {
                guard let screen = OverlayGeometry.screen(among: screens, zone: nil, shownOn: nil, shownAt: nil,
                                                          pointer: sample.pointer, main: screens.first?.id) else { return nil }
                return (screen, OverlayGeometry.bottomCenter(on: screen, anchor: sample.anchor, contentSize: sample.size,
                                                             dockShown: sample.dock, zone: sample.zone))
            }
            guard let before = place(sample.screens), before.0 == own else { return "pointeur sur \(own.id), bulle ailleurs" }
            if let during = place(sample.later.filter { !OverlayGeometry.intersects($0.frame, own.frame) }), during.0.id == own.id {
                return "écran \(own.id) visé pendant son absence"
            }
            let others = sample.later.filter { !OverlayGeometry.intersects($0.frame, own.frame) }
            guard let after = place(others + [own]), after.0 == own else { return "écran \(own.id) revenu, bulle ailleurs" }
            return after.1 == before.1 ? nil : "\(before.1) avant, \(after.1) au retour"
        }
    }

    /// `OverlayController.targetFrame` avant le suivi des écrans, recopié tel quel : écran de la saisie, sinon celui de
    /// la bulle affichée, sinon celui du pointeur, sinon l'écran principal ; puis place choisie ou par défaut, puis hors
    /// de la saisie.
    static func legacy(screens: [OverlayScreen], main: Int, zone: CGRect?, shown: CGPoint?, pointer: CGPoint,
                       anchor: OverlayAnchor?, size: CGSize, dockShown: Bool) -> (screen: OverlayScreen, point: CGPoint) {
        func screen(containing point: CGPoint) -> OverlayScreen? { screens.first { $0.frame.contains(point) } }
        let screen = zone.flatMap { screen(containing: CGPoint(x: $0.midX, y: $0.midY)) }
            ?? shown.flatMap(screen(containing:))
            ?? screen(containing: pointer) ?? screens[main]
        let visible = screen.visible
        var bottomCenter: CGPoint
        if let anchor {
            bottomCenter = OverlayGeometry.point(for: anchor, visible: visible, contentSize: size)
        } else {
            bottomCenter = CGPoint(x: visible.midX, y: dockShown && visible.minY > screen.frame.minY + 0.5 ? visible.minY + 6 : screen.frame.minY + 10)
        }
        if let zone {
            bottomCenter = OverlayGeometry.avoiding(zone, bottomCenter: bottomCenter, contentSize: size, visible: visible)
        }
        return (screen, bottomCenter)
    }

    /// Rien ne change sur des écrans ordinaires : même écran et même place, au point près, qu'avant le suivi des écrans,
    /// pour chaque bulle, place, saisie, pointeur et bulle déjà affichée.
    @Test func ordinaryScreensKeepTheirPlacement() {
        forAll(5_000, seed: 0x4F56_5335, { g -> (screens: [OverlayScreen], main: Int, zone: CGRect?, shown: Int?, shownAt: CGPoint?,
                                                 pointer: CGPoint, anchor: OverlayAnchor?, size: CGSize, dock: Bool)? in
            let screens = Self.arrangement(&g, count: g.int(1...3))
            guard !screens.isEmpty else { return nil }
            let shown: Int? = g.chance(50) ? g.int(0...(screens.count - 1)) : nil
            let zoneScreen = g.pick(screens)
            let zone: CGRect? = g.chance(50) ? nil : CGRect(x: zoneScreen.frame.minX + CGFloat(g.int(0...800)),
                                                            y: zoneScreen.frame.minY + CGFloat(g.int(0...400)),
                                                            width: CGFloat(g.int(2...900)), height: CGFloat(g.int(2...240)))
            let pointerScreen = g.pick(screens)
            let anchor: OverlayAnchor? = g.chance(40) ? nil : OverlayAnchor(x: g.double(0...1), y: g.double(0...1))
            return (screens, g.int(0...(screens.count - 1)), zone, shown, shown.map { Self.point(in: screens[$0], &g) },
                    Self.point(in: pointerScreen, &g), anchor, g.pick(Self.sizes), g.chance(50))
        }) { sample in
            guard let sample else { return nil }
            let old = Self.legacy(screens: sample.screens, main: sample.main, zone: sample.zone, shown: sample.shownAt,
                                  pointer: sample.pointer, anchor: sample.anchor, size: sample.size, dockShown: sample.dock)
            guard let screen = OverlayGeometry.screen(among: sample.screens, zone: sample.zone,
                                                      shownOn: sample.shown.map { sample.screens[$0].id }, shownAt: sample.shownAt,
                                                      pointer: sample.pointer, main: sample.screens[sample.main].id) else {
                return "aucun écran"
            }
            let point = OverlayGeometry.bottomCenter(on: screen, anchor: sample.anchor, contentSize: sample.size,
                                                     dockShown: sample.dock, zone: sample.zone)
            return screen == old.screen && point == old.point ? nil : "écran \(screen.id) \(point), avant \(old.screen.id) \(old.point)"
        }
    }

    /// Perdue seulement quand aucun écran n'en montre une partie ; jamais sans écran.
    @Test func lostOnlyWhenNoScreenShowsIt() {
        forAll(5_000, seed: 0x4F56_5336, { g -> (screens: [OverlayScreen], bubble: CGRect) in
            let screens = Self.arrangement(&g, count: g.int(0...3))
            // Bords à un quart de point : jamais sur un bord d'écran, où « se toucher » n'est pas « se recouvrir ».
            let bubble = CGRect(x: CGFloat(g.int(-9_000...9_000)) + 0.25, y: CGFloat(g.int(-3_000...3_000)) + 0.25,
                                width: CGFloat(g.int(1...600)), height: CGFloat(g.int(1...150)))
            return (screens, bubble)
        }) { sample in
            let shown = sample.screens.contains { $0.frame.intersects(sample.bubble) }
            let lost = OverlayGeometry.isLost(sample.bubble, among: sample.screens)
            return lost == (!sample.screens.isEmpty && !shown) ? nil : "\(sample.bubble) perdue=\(lost) sur \(sample.screens.map(\.frame))"
        }
    }
}
