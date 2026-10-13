import AppKit
import SwiftUI
import GrannyCore

/// Old-money stationery in both schemes: aged leather (dark) or cream paper
/// (light). Configured once at startup from the config's `appearance`.
enum GrannyTheme {
    enum Scheme { case dark, light }

    static var scheme: Scheme = .dark

    static func configure(appearance: String) {
        switch GrannyAppearance.resolve(appearance) {
        case .light:
            scheme = .light
        case .dark:
            scheme = .dark
        case .system:
            let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            scheme = match == .darkAqua ? .dark : .light
        }
    }

    // NSColor is the single source per role; the SwiftUI Color derives from
    // it, so the two can never drift.

    static var backgroundNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.106, green: 0.090, blue: 0.075, alpha: 1)
            : NSColor(calibratedRed: 0.960, green: 0.940, blue: 0.890, alpha: 1)
    }

    static var cardNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.141, green: 0.118, blue: 0.094, alpha: 1)
            : NSColor(calibratedRed: 0.990, green: 0.970, blue: 0.930, alpha: 1)
    }

    static var textNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.929, green: 0.898, blue: 0.835, alpha: 1)
            : NSColor(calibratedRed: 0.160, green: 0.140, blue: 0.120, alpha: 1)
    }

    static var goldNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.760, green: 0.631, blue: 0.361, alpha: 1)
            : NSColor(calibratedRed: 0.630, green: 0.510, blue: 0.310, alpha: 1)
    }

    static var hairlineNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.231, green: 0.196, blue: 0.161, alpha: 1)
            : NSColor(calibratedRed: 0.830, green: 0.790, blue: 0.700, alpha: 1)
    }

    static var background: Color { Color(nsColor: backgroundNS) }
    static var card: Color { Color(nsColor: cardNS) }

    /// List rows sit on a glass card on macOS 26+, on the paper card below.
    static var rowBackground: Color {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return .clear }
        #endif
        return card
    }
    static var text: Color { Color(nsColor: textNS) }
    static var gold: Color { Color(nsColor: goldNS) }
    static var hairline: Color { Color(nsColor: hairlineNS) }

    static var windowAppearance: NSAppearance? {
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    static var colorScheme: ColorScheme {
        scheme == .dark ? .dark : .light
    }

    /// Text on top of the gold primary button - dark ink in both schemes.
    static let onGold = Color(red: 0.14, green: 0.11, blue: 0.09)

    // The tomato's three stages: brick, amber and sage, kept pastel enough
    // that the dark ink on top holds its contrast in both schemes.

    static var tomatoDeepNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.840, green: 0.451, blue: 0.380, alpha: 1)
            : NSColor(calibratedRed: 0.870, green: 0.510, blue: 0.440, alpha: 1)
    }

    static var tomatoShortNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.878, green: 0.714, blue: 0.310, alpha: 1)
            : NSColor(calibratedRed: 0.894, green: 0.769, blue: 0.427, alpha: 1)
    }

    static var tomatoLongNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.490, green: 0.647, blue: 0.451, alpha: 1)
            : NSColor(calibratedRed: 0.588, green: 0.714, blue: 0.541, alpha: 1)
    }

    /// The tomato's colour is the whole label: red is deep work, amber a
    /// short break, green the long one.
    static func tomato(_ stage: PomodoroStage) -> Color {
        switch stage {
        case .deepWork: return Color(nsColor: tomatoDeepNS)
        case .shortBreak: return Color(nsColor: tomatoShortNS)
        case .longBreak: return Color(nsColor: tomatoLongNS)
        }
    }

    /// The calyx keeps one colour across the stages: a fixed olive, so it can
    /// never match the fruit it grows from. A per-stage green disappeared
    /// into the long break's own green.
    static var leafNS: NSColor {
        scheme == .dark
            ? NSColor(calibratedRed: 0.345, green: 0.396, blue: 0.263, alpha: 1)
            : NSColor(calibratedRed: 0.294, green: 0.353, blue: 0.220, alpha: 1)
    }

    static var leaf: Color { Color(nsColor: leafNS) }

    /// One shade of a stage's colour per role in the fruit's painting: a
    /// lighter mix carries the specular side, a darker one the rim and the
    /// occlusion under it. Keeping the mixing here means the tomato never
    /// hardcodes a colour of its own.
    static func tomatoShade(_ stage: PomodoroStage, towardWhite fraction: CGFloat) -> Color {
        let base: NSColor
        switch stage {
        case .deepWork: base = tomatoDeepNS
        case .shortBreak: base = tomatoShortNS
        case .longBreak: base = tomatoLongNS
        }
        let target = NSColor(calibratedWhite: fraction >= 0 ? 1 : 0, alpha: 1)
        let mixed = base.blended(withFraction: min(abs(fraction), 1), of: target) ?? base
        return Color(nsColor: mixed)
    }
}

/// Pointing-hand cursor over the view's area. Cursor rects alone were losing
/// to AppKit controls (pickers, steppers, toggles) that manage their own
/// cursor, so this also installs a tracking area that answers `cursorUpdate`.
/// Rendered as an overlay, transparent to clicks.
struct PointingHandCursor: NSViewRepresentable {
    var isActive: Bool = true

    func makeNSView(context: Context) -> NSView { CursorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CursorView, view.isActive != isActive else { return }
        view.isActive = isActive
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var isActive = true

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil))
        }

        override func resetCursorRects() {
            if isActive { addCursorRect(bounds, cursor: .pointingHand) }
        }

        override func cursorUpdate(with event: NSEvent) {
            guard isActive else { return super.cursorUpdate(with: event) }
            NSCursor.pointingHand.set()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isActive else { return }
            NSCursor.pointingHand.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }

        /// Transparent to clicks: the control underneath keeps working.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Pointing-hand cursor while hovering (buttons, check circles, pickers).
    func pointingHandOnHover() -> some View {
        overlay(PointingHandCursor())
    }

    /// Liquid Glass card on macOS 26+, the aged-paper card below it.
    @ViewBuilder
    func grannyCard(cornerRadius: CGFloat = 8) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // The glass edge alone can vanish mid-scroll; the hairline keeps
            // the card's outline stable.
            self
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(GrannyTheme.hairline))
        } else {
            self.grannyPaperCard(cornerRadius: cornerRadius)
        }
        #else
        self.grannyPaperCard(cornerRadius: cornerRadius)
        #endif
    }

    /// Translucent window backdrop on macOS 26+, the parchment below it.
    /// `ignoresSafeArea` lets it cover the titlebar area too, so the whole
    /// window - top bar included - sits on one balanced glass tint.
    @ViewBuilder
    func grannyWindowBackdrop() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.background {
                ZStack {
                    Rectangle().fill(.thinMaterial)
                    GrannyTheme.background.opacity(0.55)
                }
                .ignoresSafeArea()
            }
        } else {
            self.background(GrannyTheme.background.ignoresSafeArea())
        }
        #else
        self.background(GrannyTheme.background.ignoresSafeArea())
        #endif
    }

    func grannyPaperCard(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(GrannyTheme.card))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(GrannyTheme.hairline))
    }

    /// The tomato's backdrop: a Liquid Glass puck cut to the fruit's own
    /// silhouette on macOS 26+, the paper disc below it. It has to be the
    /// fruit's shape - a circle sat proud of the dial's shoulders and the
    /// whole ring read as off-centre.
    @ViewBuilder
    func grannyGlassPlate<S: Shape>(_ shape: S, diameter: CGFloat) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            self.grannyPaperPlate(shape, diameter: diameter)
        }
        #else
        self.grannyPaperPlate(shape, diameter: diameter)
        #endif
    }

    func grannyPaperPlate<S: Shape>(_ shape: S, diameter: CGFloat) -> some View {
        self
            .frame(width: diameter, height: diameter)
            .background(shape.fill(GrannyTheme.card))
            .overlay(shape.stroke(GrannyTheme.hairline, lineWidth: 1))
    }
}

/// Granny's primary button, drawn by hand: the system's bordered-prominent
/// control washes out when the window loses focus, this one does not.
/// Hover lifts it gently, press springs it down - Apple-ish, in granny's gold.
struct GrannyPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var lifted: Bool { hovering && isEnabled }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(isEnabled ? GrannyTheme.onGold : GrannyTheme.onGold.opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GrannyTheme.gold.opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(lifted ? 0.30 : 0.18), .clear],
                                        startPoint: .top,
                                        endPoint: .bottom))))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.black.opacity(isEnabled ? 0.10 : 0.06)))
                .shadow(
                    color: .black.opacity(lifted ? 0.30 : (isEnabled ? 0.16 : 0)),
                    radius: lifted ? 8 : 3,
                    y: lifted ? 3 : 1.5)
                .scaleEffect(configuration.isPressed ? 0.97 : (lifted ? 1.02 : 1))
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(PointingHandCursor(isActive: isEnabled))
                .onHover { hovering = $0 }
        }
    }
}

/// Quiet secondary button, liquid on hover: a soft gold wash, a hairline
/// that brightens, a small lift, and the pointing hand. Settings' Cancel /
/// Add actions use it so every clickable looks clickable.
struct GrannySecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        private var lit: Bool { hovering && isEnabled }

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold, design: .serif))
                .foregroundStyle(GrannyTheme.gold.opacity(isEnabled ? 1 : 0.4))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(GrannyTheme.gold.opacity(lit ? 0.16 : 0.05)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(GrannyTheme.gold.opacity(lit ? 0.5 : 0.18)))
                .scaleEffect(configuration.isPressed ? 0.97 : (lit ? 1.02 : 1))
                .animation(.spring(response: 0.25, dampingFraction: 0.72), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovering)
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .background(PointingHandCursor(isActive: isEnabled))
                .onHover { hovering = $0 }
        }
    }
}

final class GrannyViewModel: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var phase: Phase = .awaitingTasks
    @Published var dayOff = false
    @Published var streak = 0
    @Published var pomodoroStage: PomodoroStage = .deepWork
    /// Which instance of the current stage today: round 2, the 3rd short
    /// break. Shown outside the tomato.
    @Published var pomodoroIndex = 1
    @Published var pomodoroRemaining: TimeInterval = 0
    /// Full length of the running stage, so the fruit can show how much of
    /// the round is behind it.
    @Published var pomodoroTotal: TimeInterval = 0
    @Published var pomodoroRunning = false

    func refresh(from context: GrannyContext) {
        tasks = context.store.state.tasks
        phase = context.phase()
        dayOff = context.store.state.dayOff
        streak = displayStreak(state: context.store.state)
    }
}

/// The tomato in the notebook's corner: the Pomodoro timer drawn as the
/// fruit it is named after. The colour is the stage, the countdown sits on
/// the fruit, and the number outside counts today's instances of that stage
/// - so no digit needs a legend.
/// The tomato's silhouette: a squashed circle with the shallow dimple the
/// calyx grows out of, so it reads as fruit and not as a dot.
private struct TomatoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let dimple = h * 0.07
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + dimple))
        // Right shoulder, right cheek, base.
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control1: CGPoint(x: rect.minX + w * 0.72, y: rect.minY + h * 0.02),
            control2: CGPoint(x: rect.maxX, y: rect.minY + h * 0.26))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.84),
            control2: CGPoint(x: rect.minX + w * 0.78, y: rect.maxY))
        // Left half, mirrored.
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control1: CGPoint(x: rect.minX + w * 0.22, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.minY + h * 0.84))
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + dimple),
            control1: CGPoint(x: rect.minX, y: rect.minY + h * 0.26),
            control2: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.02))
        path.closeSubpath()
        return path
    }
}

/// Leaves and a short stalk radiating from the fruit's top centre.
/// Canvas, because this is one rotation around one point - nested
/// `.offset`/`.rotationEffect` pairs rotate around the wrong origin and the
/// calyx ends up smeared across the shoulder.
private struct TomatoCalyx: View {
    let shade: Color

    /// Five leaves, the outer pair lying almost flat on the shoulder: a
    /// tomato's calyx, not a crown.
    private static let angles: [Double] = [-100, -50, 0, 50, 100]
    private static let reach: CGFloat = 4

    /// A leaf: pointed tip, two curves for the sides. Ellipses read as blobs
    /// at this size - a leaf silhouette stays a leaf.
    private static func leaf(length: CGFloat, width: CGFloat) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addQuadCurve(
            to: CGPoint(x: 0, y: -length),
            control: CGPoint(x: width, y: -length * 0.42))
        path.addQuadCurve(
            to: .zero,
            control: CGPoint(x: -width, y: -length * 0.42))
        path.closeSubpath()
        return path
    }

    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width / 2, y: size.height)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [shade.opacity(1), shade.opacity(0.62)]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height))

            /// A leaf turned where it is, then moved into place. Turning
            /// after moving would swing it around the canvas corner.
            func placed(_ leaf: Path, toward angle: Double) -> Path {
                // CGFloat, not Double: both `_math` and CoreGraphics offer
                // `sin`, and an unconverted argument leaves the call ambiguous
                // on toolchains this repo is not built with locally.
                let radians = CGFloat(angle) * .pi / 180
                let centre = CGPoint(
                    x: origin.x + sin(radians) * Self.reach,
                    y: origin.y - cos(radians) * Self.reach)
                return leaf
                    .applying(CGAffineTransform(rotationAngle: radians))
                    .applying(CGAffineTransform(translationX: centre.x, y: centre.y))
            }

            let sepal = Self.leaf(length: 8.6, width: 3.1)
            for angle in Self.angles {
                let placed = placed(sepal, toward: angle)
                context.fill(placed, with: shading)
                // A gold hairline around every leaf: the engraver's line, and
                // what keeps the calyx legible over any fruit.
                context.stroke(
                    placed,
                    with: .color(GrannyTheme.gold.opacity(0.45)),
                    lineWidth: 0.5)
            }

            // The stalk, a shade darker again so it reads as the stem under
            // the leaves.
            var stalk = Path()
            stalk.move(to: CGPoint(x: origin.x - 1.1, y: origin.y))
            stalk.addCurve(
                to: CGPoint(x: origin.x + 0.3, y: origin.y - 6.4),
                control1: CGPoint(x: origin.x - 1.8, y: origin.y - 2.4),
                control2: CGPoint(x: origin.x - 1, y: origin.y - 4.8))
            stalk.addCurve(
                to: CGPoint(x: origin.x + 1.1, y: origin.y),
                control1: CGPoint(x: origin.x + 0.9, y: origin.y - 4.8),
                control2: CGPoint(x: origin.x + 1.1, y: origin.y - 1.4))
            stalk.closeSubpath()
            context.fill(stalk, with: .color(shade.opacity(0.9)))

            // A cap where the leaves meet, so the middle is not hollow.
            let cap = Path(ellipseIn: CGRect(
                x: origin.x - 2.2, y: origin.y - 4.2, width: 4.4, height: 4.4))
            context.fill(cap, with: .color(shade.opacity(0.85)))
        }
        .frame(width: 26, height: 15)
    }
}

/// The dial: the fruit's outline cut into its marks, holding only the ones
/// asked for. A `Shape` on purpose - a raw `Path` view is laid out by its own
/// absolute coordinates, so inside a larger frame the ring drifts up and left.
private struct TomatoDial: Shape {
    let remaining: TimeInterval
    let total: TimeInterval
    /// True for the marks still holding fruit, false for the finished ones.
    let lit: Bool

    func path(in rect: CGRect) -> Path {
        let outline = TomatoShape().path(in: rect)
        var path = Path()
        for mark in pomodoroRingPieces(remaining: remaining, total: total) where mark.lit == lit {
            path.addPath(outline.trimmedPath(from: mark.from, to: mark.to))
        }
        return path
    }
}

/// The tomato in the notebook's corner, built the way a watch is: a glass
/// puck, a dial that drains as the round runs, and a fine tip where the
/// draining has reached - the hand. Time passing is visible every step of the
/// dial, and the clock itself stays in the hole in the middle.
struct PomodoroTomatoView: View {
    let stage: PomodoroStage
    let index: Int
    let remaining: TimeInterval
    let total: TimeInterval
    let running: Bool
    var action: () -> Void

    @State private var hovering = false

    /// The ring is the fruit's outline: the shape is stroked, so the tomato
    /// is `diameter + ringWidth` across and the clock sits in the hole. The
    /// plate is larger again, so the fruit sits *on* something.
    private static let diameter: CGFloat = 46
    private static let ringWidth: CGFloat = 4.5
    private static var outer: CGFloat { diameter + ringWidth }
    /// The plate is the fruit's own silhouette, a hair larger than the dial,
    /// so the glass reads as the tomato's rim instead of a coaster under it.
    private static var plateDiameter: CGFloat { outer + 2 }

    /// Rounded up: a fresh 25-minute round paints 25:00, and the last second
    /// paints 0:01 - it reaches 0:00 only when the stage is over.
    private var clock: String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// What is left of the round. The ring drains from twelve o'clock, so the
    /// fruit is eaten clockwise and what remains always ends at the top.
    private var remainingFraction: Double {
        guard total > 0 else { return 1 }
        return min(max(remaining / total, 0), 1)
    }

    /// Where the hand is, in clock degrees from twelve.
    private var tip: CGPoint {
        // Same CGFloat note as the calyx: keep `sin`/`cos` unambiguous.
        let radians = CGFloat(1 - remainingFraction) * 2 * .pi
        let radius = Self.diameter / 2
        return CGPoint(x: sin(radians) * radius, y: -cos(radians) * radius)
    }

    /// A breath once a second: the hand glows as each second lands, so a
    /// glance says the round is running even when the second hand itself is
    /// only a fraction of a degree further on.
    private var pulse: Double {
        let fraction = remaining - remaining.rounded(.down)
        return 0.5 + 0.5 * (1 - fraction)
    }

    private var fruit: Color { GrannyTheme.tomato(stage) }

    var body: some View {
        Button(action: action) {
            ZStack {
                // The dial itself, so the face keeps its marks even when the
                // round has nothing left in it.
                TomatoDial(remaining: remaining, total: total, lit: false)
                    .stroke(fruit.opacity(0.12), lineWidth: Self.ringWidth)
                    .frame(width: Self.diameter, height: Self.diameter)

                TomatoDial(remaining: remaining, total: total, lit: true)
                    .stroke(
                        // A sheen along the ring, so the fruit reads as a
                        // surface rather than a flat stroke.
                        LinearGradient(
                            colors: [
                                GrannyTheme.tomatoShade(stage, towardWhite: 0.22),
                                fruit,
                                GrannyTheme.tomatoShade(stage, towardWhite: -0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing)
                            .opacity(running ? 1 : 0.65),
                        style: StrokeStyle(lineWidth: Self.ringWidth))
                    .frame(width: Self.diameter, height: Self.diameter)

                // The outer edge of the fruit, so the silhouette stays crisp
                // against the glass. (The inner edge is the stroke's own; a
                // second hairline there only added noise.)
                TomatoShape()
                    .stroke(GrannyTheme.hairline, lineWidth: 0.7)
                    .frame(width: Self.outer, height: Self.outer)

                if running {
                    // The wet edge: a soft glow under the hand, so the second
                    // just eaten reads as fresh.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    GrannyTheme.tomatoShade(stage, towardWhite: 0.5).opacity(0.42),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: 8))
                        .frame(width: 16, height: 16)
                        .offset(x: tip.x, y: tip.y)
                        .blendMode(.plusLighter)
                        .animation(.linear(duration: 0.25), value: remainingFraction)
                }

                // The hand: where the round has got to.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                GrannyTheme.tomatoShade(stage, towardWhite: 0.55),
                                fruit,
                            ],
                            startPoint: .top,
                            endPoint: .bottom))
                    .frame(width: 4, height: 4)
                    .shadow(color: fruit.opacity(running ? 0.65 * pulse : 0), radius: 3.5)
                    .offset(x: tip.x, y: tip.y)
                    .animation(.linear(duration: 0.25), value: remainingFraction)

                TomatoCalyx(shade: GrannyTheme.leaf)
                    .offset(y: -Self.outer / 2 + Self.ringWidth / 2 + 1)

                Text(clock)
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .monospacedDigit()
                    .tracking(0.6)
                    .foregroundStyle(GrannyTheme.gold.opacity(running ? 0.95 : 0.75))
                    .offset(y: 1)
            }
            .grannyGlassPlate(TomatoShape(), diameter: Self.plateDiameter)
            .overlay(alignment: .topTrailing) {
                // The round counter: a hairline tag on the shoulder, small
                // enough to read as a mark rather than a second button.
                Text("\(index)")
                    .font(.system(size: 9, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(GrannyTheme.gold)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(GrannyTheme.background))
                    .overlay(Circle().strokeBorder(GrannyTheme.gold.opacity(0.45), lineWidth: 0.8))
                    .offset(x: -6, y: 8)
            }
            .overlay(alignment: .bottom) {
                // What a click does, only while the hand is there, and tucked
                // under the ring so it never sits on the clock.
                if hovering {
                    ZStack {
                        Circle().fill(Color.black.opacity(0.45))
                        Image(systemName: running ? "pause.fill" : "play.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white.opacity(0.95))
                    }
                    .frame(width: 16, height: 16)
                    .offset(y: 5)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.72), value: hovering)
            .animation(.easeOut(duration: 0.25), value: stage)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .onHover { hovering = $0 }
        .pointingHandOnHover()
        .help(GrannyLines.pomodoroHelp)
        .accessibilityLabel(GrannyLines.pomodoroHelp)
        .accessibilityValue(
            GrannyLines.pomodoroState(
                stage: GrannyLines.pomodoroStage(stage), index: index, clock: clock))
        .accessibilityHint(running ? GrannyLines.pomodoroClickToPause : GrannyLines.pomodoroClickToRun)
    }
}

/// The flame that turns a habit into a game: consecutive clean days, shown
/// from two days on.
struct StreakBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("🔥").font(.system(size: 13))
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(GrannyTheme.gold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(GrannyTheme.gold.opacity(0.12)))
        .overlay(Capsule().strokeBorder(GrannyTheme.gold.opacity(0.35)))
        .help(GrannyLines.streakHelp)
    }
}

/// The intake "notebook": a bulleted list editor. Every new line gets a
/// bullet automatically, and the first line starts with one.
struct GreetingView: View {
    var needsSetup: Bool
    var needsHelper: Bool = false
    var carried: [String] = []
    var streak: Int = 0
    var onOpenSettings: () -> Void
    var onInstallHelper: () -> Void = {}
    var onSave: (String) -> Void
    var onDayOff: () -> Void
    @State private var text = TaskParser.bullet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GrannyLines.notebookLabel)
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .tracking(3)
                        .foregroundStyle(GrannyTheme.gold)
                    Text(GrannyLines.greeting)
                        .font(.system(size: 25, weight: .semibold, design: .serif))
                        .foregroundStyle(GrannyTheme.text)
                    Text(GrannyLines.greetHint)
                        .font(.system(size: 12, design: .serif))
                        .italic()
                        .foregroundStyle(GrannyTheme.text.opacity(0.55))
                    if !carried.isEmpty {
                        HStack(alignment: .top, spacing: 7) {
                            Text("🐸").font(.system(size: 14))
                            Text(GrannyLines.carryOver(tasks: carried))
                                .font(.system(size: 12, design: .serif))
                                .foregroundStyle(GrannyTheme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                    Rectangle()
                        .fill(GrannyTheme.gold.opacity(0.45))
                        .frame(height: 1)
                        .padding(.top, 4)
                }
                Spacer()
                if streak >= 2 {
                    StreakBadge(count: streak)
                        .padding(.top, 2)
                }
            }

            if needsSetup {
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 13))
                        .foregroundStyle(GrannyTheme.gold)
                    Text(GrannyLines.setupHint)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(GrannyTheme.text.opacity(0.8))
                    Spacer()
                    Button(GrannyLines.openSettingsButton) { onOpenSettings() }
                        .buttonStyle(.bordered)
                        .tint(GrannyTheme.gold)
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .pointingHandOnHover()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 4).fill(GrannyTheme.gold.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(GrannyTheme.gold.opacity(0.35)))
            }

            if needsHelper {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 13))
                        .foregroundStyle(GrannyTheme.gold)
                    Text(GrannyLines.helperHint)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(GrannyTheme.text.opacity(0.8))
                    Spacer()
                    Button(GrannyLines.installHelperButton) { onInstallHelper() }
                        .buttonStyle(.bordered)
                        .tint(GrannyTheme.gold)
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .pointingHandOnHover()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 4).fill(GrannyTheme.gold.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(GrannyTheme.gold.opacity(0.35)))
            }

            TextEditor(text: $text)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(GrannyTheme.text)
                .tint(GrannyTheme.gold)
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .padding(14)
                .grannyCard(cornerRadius: 4)
                .frame(minHeight: 220, maxHeight: .infinity)
                .onChange(of: text) { oldValue, newValue in
                    if newValue.count > oldValue.count, newValue.hasSuffix("\n") {
                        // Enter was just typed: start the next bullet.
                        text = newValue + TaskParser.bullet
                    } else if newValue.isEmpty {
                        // The first line always keeps its bullet.
                        text = TaskParser.bullet
                    } else if newValue.count > oldValue.count {
                        // "- " typed at the start of a line becomes the
                        // drawn bullet, the way Notion does it.
                        let bulleted = TaskParser.bulleted(afterTypingLineMarker: newValue)
                        if bulleted != newValue { text = bulleted }
                    }
                }

            HStack(spacing: 18) {
                quietButton(GrannyLines.dayOffButton, action: onDayOff)
                Spacer()
                Button(GrannyLines.saveButton) { onSave(text) }
                    .buttonStyle(GrannyPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(clean(text).isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(26)
        .frame(minWidth: 520, minHeight: 420)
        .grannyWindowBackdrop()
        .preferredColorScheme(GrannyTheme.colorScheme)
    }

    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13, design: .serif))
            .foregroundStyle(GrannyTheme.text.opacity(0.7))
            .pointingHandOnHover()
    }

    private func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "•", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct TaskListView: View {
    @ObservedObject var viewModel: GrannyViewModel
    var onToggle: (String) -> Void
    var onMarkAllDone: () -> Void
    var onAdd: (String) -> Void
    var onUpdateTask: (String, String, String?, [String]) -> Void
    var onElaborate: (String, String?) async -> String?
    var onRemove: (String) -> Void
    var onResumeWork: () -> Void
    var onOpenSettings: () -> Void
    var onTogglePomodoro: () -> Void

    @State private var adding = false
    @State private var newTask = ""
    @State private var editing: TaskItem?
    @State private var settingsHover = false
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(GrannyLines.tasksNotebookLabel)
                        .font(.system(size: 11, weight: .semibold, design: .serif))
                        .tracking(3)
                        .foregroundStyle(GrannyTheme.gold)
                    Text(status)
                        .font(.system(size: 21, weight: .semibold, design: .serif))
                        .foregroundStyle(GrannyTheme.text)
                    if viewModel.dayOff {
                        Button(GrannyLines.resumeWorkButton) { onResumeWork() }
                            .buttonStyle(.bordered)
                            .tint(GrannyTheme.gold)
                            .font(.system(size: 12, weight: .semibold, design: .serif))
                            .pointingHandOnHover()
                            .padding(.top, 2)
                    }
                }
                Spacer()
                if viewModel.streak >= 2 {
                    StreakBadge(count: viewModel.streak)
                }
                settingsButton
            }

            Rectangle()
                .fill(GrannyTheme.gold.opacity(0.45))
                .frame(height: 1)
                .padding(.top, 4)

            List(viewModel.tasks) { task in
                HStack(alignment: .top, spacing: 10) {
                    Button {
                        onToggle(task.id)
                    } label: {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(GrannyTheme.gold)
                    }
                    .buttonStyle(.plain)
                    .pointingHandOnHover()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if task.carriedOver {
                                Text("🐸")
                                    .font(.system(size: 13))
                                    .help(GrannyLines.carriedBadge)
                            }
                            Text(task.title)
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(GrannyTheme.text)
                                .strikethrough(task.done)
                        }
                        if let purpose = task.purpose, !purpose.isEmpty {
                            Text(purpose)
                                .font(.system(size: 11, design: .serif))
                                .italic()
                                .foregroundStyle(GrannyTheme.text.opacity(0.55))
                        }
                        if !task.allowedSurfaces.isEmpty {
                            Text(task.allowedSurfaces.joined(separator: "  "))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(GrannyTheme.text.opacity(0.4))
                        }
                    }
                    Spacer()
                    Button {
                        editing = task
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(GrannyTheme.text.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help(GrannyLines.taskEditHelp)
                    .pointingHandOnHover()
                    Button {
                        onRemove(task.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(GrannyTheme.text.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help(GrannyLines.dropTaskHelp)
                    .pointingHandOnHover()
                }
                .padding(.vertical, 3)
                .listRowBackground(GrannyTheme.rowBackground)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .grannyCard(cornerRadius: 4)
            .sheet(item: $editing) { task in
                TaskEditorView(
                    task: task,
                    onSave: { title, purpose, surfaces in
                        onUpdateTask(task.id, title, purpose, surfaces)
                        editing = nil
                    },
                    onElaborate: onElaborate,
                    onCancel: { editing = nil })
            }

            if viewModel.tasks.isEmpty {
                Text(GrannyLines.tasksEmpty)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(GrannyTheme.text.opacity(0.55))
            }

            if adding {
                HStack(spacing: 8) {
                    TextField(GrannyLines.addTaskPlaceholder, text: $newTask)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(GrannyTheme.text)
                        .tint(GrannyTheme.gold)
                        .focused($addFocused)
                        .padding(8)
                        .grannyCard(cornerRadius: 4)
                        .onSubmit { commitAdd() }
                    Button(GrannyLines.addTaskConfirm) { commitAdd() }
                        .buttonStyle(.bordered)
                        .tint(GrannyTheme.gold)
                        .font(.system(size: 12, weight: .semibold, design: .serif))
                        .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty)
                        .pointingHandOnHover()
                    Button(GrannyLines.cancelButton) {
                        newTask = ""
                        adding = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(GrannyTheme.text.opacity(0.7))
                    .keyboardShortcut(.cancelAction)
                    .pointingHandOnHover()
                }
            } else {
                Button {
                    adding = true
                    addFocused = true
                } label: {
                    Text("+ " + GrannyLines.addTaskButton)
                        .font(.system(size: 13, design: .serif))
                        .foregroundStyle(GrannyTheme.gold)
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            HStack(alignment: .bottom) {
                PomodoroTomatoView(
                    stage: viewModel.pomodoroStage,
                    index: viewModel.pomodoroIndex,
                    remaining: viewModel.pomodoroRemaining,
                    total: viewModel.pomodoroTotal,
                    running: viewModel.pomodoroRunning,
                    action: onTogglePomodoro)
                Spacer()
                Button(GrannyLines.markAllDoneButton) { onMarkAllDone() }
                    .buttonStyle(GrannyPrimaryButtonStyle())
                    .disabled(viewModel.tasks.isEmpty || viewModel.tasks.allSatisfy { $0.done })
            }
        }
        .padding(26)
        .frame(minWidth: 520, minHeight: 420)
        .grannyWindowBackdrop()
        .preferredColorScheme(GrannyTheme.colorScheme)
    }

    /// Quiet gear in the notebook's corner: granny's Settings, one click away.
    private var settingsButton: some View {
        Button(action: onOpenSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 15))
                .foregroundStyle(GrannyTheme.gold.opacity(settingsHover ? 1 : 0.55))
                .padding(6)
                .background(Circle().fill(GrannyTheme.gold.opacity(settingsHover ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(GrannyLines.menuSettings)
        .onHover { settingsHover = $0 }
        .pointingHandOnHover()
        .animation(.easeOut(duration: 0.15), value: settingsHover)
    }

    private func commitAdd() {
        let text = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onAdd(text)
        newTask = ""
        adding = false
    }

    private var status: String {
        switch viewModel.phase {
        case .awaitingTasks: return GrannyLines.statusAwaiting
        case .working: return GrannyLines.statusWorking
        case .rewarded: return GrannyLines.statusRewarded
        case .dayOff: return GrannyLines.statusDayOff
        case .night: return GrannyLines.statusNight
        }
    }
}

/// Editor for one task: its words (title, purpose) and the URL patterns the
/// rules let through before the block lists. Saving re-runs granny's intake
/// on the new words, so the purpose and the sites the task needs are
/// re-derived - and a hand-written purpose or surfaces list is left alone.
struct TaskEditorView: View {
    let task: TaskItem
    var onSave: (String, String?, [String]) -> Void
    var onElaborate: (String, String?) async -> String?
    var onCancel: () -> Void

    @State private var title: String
    @State private var purpose: String
    @State private var surfaces: [String]
    @State private var newSurface = ""
    @State private var elaborating = false

    init(
        task: TaskItem,
        onSave: @escaping (String, String?, [String]) -> Void,
        onElaborate: @escaping (String, String?) async -> String?,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.onSave = onSave
        self.onElaborate = onElaborate
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _purpose = State(initialValue: task.purpose ?? "")
        _surfaces = State(initialValue: task.allowedSurfaces)
    }

    private var titleIsEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GrannyLines.taskEditEyebrow)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .tracking(3)
                    .foregroundStyle(GrannyTheme.gold)
                Text(GrannyLines.taskEditCaption)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(GrannyTheme.text.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            labeledField(GrannyLines.taskEditTitleLabel, $title)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(GrannyLines.taskEditPurposeLabel)
                        .font(.system(size: 11, design: .serif))
                        .foregroundStyle(GrannyTheme.text.opacity(0.55))
                    Spacer()
                    Button {
                        askGranny()
                    } label: {
                        Text(GrannyLines.taskEditAskGranny)
                            .font(.system(size: 11, weight: .semibold, design: .serif))
                            .foregroundStyle(GrannyTheme.gold)
                    }
                    .buttonStyle(.plain)
                    .disabled(elaborating || titleIsEmpty)
                    .help(GrannyLines.taskEditAskGrannyHelp)
                    .pointingHandOnHover()
                }
                TextField("", text: $purpose)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(GrannyTheme.text)
                    .tint(GrannyTheme.gold)
                    .padding(7)
                    .grannyCard(cornerRadius: 4)
                    .overlay(alignment: .trailing) {
                        if elaborating {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 8)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(GrannyLines.surfacesEditTitle)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .tracking(3)
                    .foregroundStyle(GrannyTheme.gold)
                Text(GrannyLines.surfacesCaption)
                    .font(.system(size: 11, design: .serif))
                    .foregroundStyle(GrannyTheme.text.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                ForEach(surfaces, id: \.self) { surface in
                    HStack {
                        Text(surface)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(GrannyTheme.text)
                        Spacer()
                        Button {
                            surfaces.removeAll { $0 == surface }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(GrannyTheme.text.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .help(GrannyLines.settingsRemoveEntry)
                    }
                    .listRowBackground(GrannyTheme.rowBackground)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .grannyCard(cornerRadius: 4)

            HStack(spacing: 8) {
                TextField(GrannyLines.surfacesPlaceholder, text: $newSurface)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(GrannyTheme.text)
                    .tint(GrannyTheme.gold)
                    .padding(7)
                    .grannyCard(cornerRadius: 4)
                    .onSubmit { commit() }
                Button(GrannyLines.settingsAddSite) { commit() }
                    .buttonStyle(.bordered)
                    .tint(GrannyTheme.gold)
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .disabled(newSurface.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button(GrannyLines.cancelButton) { onCancel() }
                Button(GrannyLines.settingsSave) {
                    onSave(title.trimmingCharacters(in: .whitespacesAndNewlines),
                           purpose, surfaces)
                }
                .buttonStyle(GrannyPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(titleIsEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 500)
        .grannyWindowBackdrop()
        .preferredColorScheme(GrannyTheme.colorScheme)
    }

    @ViewBuilder
    private func labeledField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(GrannyTheme.text.opacity(0.55))
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .serif))
                .foregroundStyle(GrannyTheme.text)
                .tint(GrannyTheme.gold)
                .padding(7)
                .grannyCard(cornerRadius: 4)
        }
    }

    private func commit() {
        guard let surface = TaskParser.normalizeSurface(newSurface) else { return }
        newSurface = ""
        if !surfaces.contains(surface) {
            surfaces.append(surface)
        }
    }

    /// "Ask granny": the engine re-reads the task and writes its one-line
    /// purpose into the field, where the user can keep editing it.
    private func askGranny() {
        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !titleText.isEmpty, !elaborating else { return }
        elaborating = true
        Task {
            let elaborated = await onElaborate(titleText, purpose.isEmpty ? nil : purpose)
            await MainActor.run {
                if let elaborated { purpose = elaborated }
                elaborating = false
            }
        }
    }
}
