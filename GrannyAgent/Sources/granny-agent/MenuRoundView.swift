import AppKit
import GrannyCore

/// The round, in the menu bar menu: starting a tomato should not cost opening
/// the notebook first. Drawn rather than assembled from controls - a card with
/// the stage, the clock, a progress hairline and a pill that starts or pauses.
final class MenuRoundView: NSView {
    private let stage: PomodoroStage
    private let index: Int
    private let remaining: TimeInterval
    private let total: TimeInterval
    private let running: Bool
    private let onToggle: () -> Void

    private static let height: CGFloat = 62
    private static let inset: CGFloat = 8

    init(
        width: CGFloat,
        stage: PomodoroStage,
        index: Int,
        remaining: TimeInterval,
        total: TimeInterval,
        running: Bool,
        onToggle: @escaping () -> Void
    ) {
        self.stage = stage
        self.index = index
        self.remaining = remaining
        self.total = total
        self.running = running
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 6, dy: 4)
        let background = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
        GrannyTheme.cardNS.withAlphaComponent(0.55).setFill()
        background.fill()
        GrannyTheme.hairlineNS.setStroke()
        background.lineWidth = 1
        background.stroke()

        let tint = Self.colour(for: stage)
        let dotRect = NSRect(x: card.minX + 12, y: card.minY + 13, width: 9, height: 9)
        tint.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let label = NSMutableAttributedString(
            string: "\(GrannyLines.pomodoroStage(stage).uppercased()) · \(index)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: GrannyTheme.goldNS,
                .kern: 1.4,
            ])
        label.draw(at: NSPoint(x: dotRect.maxX + 8, y: card.minY + 11))

        let clock = NSMutableAttributedString(
            string: Self.clock(remaining > 0 ? remaining : total),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: GrannyTheme.textNS,
            ])
        clock.draw(at: NSPoint(x: dotRect.maxX + 8, y: card.minY + 26))

        drawPill(in: card, tint: tint)
        drawProgress(in: card, tint: tint)
    }

    /// Start on the left of the pill, the whole card is the target: a menu is
    /// transitory, so the smallest possible gesture is the right one.
    private func drawPill(in card: NSRect, tint: NSColor) {
        let title = running ? GrannyLines.menuRoundPause : GrannyLines.menuRoundStart
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let textSize = title.size(withAttributes: [.font: font])
        let pillSize = NSSize(width: textSize.width + 22, height: 22)
        let pill = NSRect(
            x: card.maxX - pillSize.width - 12,
            y: card.midY - pillSize.height / 2,
            width: pillSize.width, height: pillSize.height)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        tint.withAlphaComponent(running ? 0.22 : 0.92).setFill()
        path.fill()
        if running {
            tint.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let ink = running ? tint : NSColor(calibratedWhite: 0.12, alpha: 1)
        title.draw(
            at: NSPoint(
                x: pill.midX - textSize.width / 2,
                y: pill.midY - textSize.height / 2),
            withAttributes: [.font: font, .foregroundColor: ink])
    }

    /// The round's fill, a hairline under the card: the same idea as the ring
    /// on the fruit, sized for a menu row.
    private func drawProgress(in card: NSRect, tint: NSColor) {
        guard total > 0 else { return }
        let track = NSRect(
            x: card.minX + 12, y: card.maxY - 9,
            width: card.width - 24, height: 2)
        GrannyTheme.hairlineNS.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        let done = min(max(1 - remaining / total, 0), 1)
        guard done > 0 else { return }
        let fill = NSRect(
            x: track.minX, y: track.minY, width: track.width * done, height: track.height)
        tint.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onToggle()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func colour(for stage: PomodoroStage) -> NSColor {
        switch stage {
        case .deepWork: return GrannyTheme.tomatoDeepNS
        case .shortBreak: return GrannyTheme.tomatoShortNS
        case .longBreak: return GrannyTheme.tomatoLongNS
        }
    }
}
