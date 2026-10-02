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

    func refresh(from context: GrannyContext) {
        tasks = context.store.state.tasks
        phase = context.phase()
        dayOff = context.store.state.dayOff
    }
}

/// The intake "notebook": a bulleted list editor. Every new line gets a
/// bullet automatically, and the first line starts with one.
struct GreetingView: View {
    var needsSetup: Bool
    var carried: [String] = []
    var onOpenSettings: () -> Void
    var onSave: (String) -> Void
    var onDayOff: () -> Void
    @State private var text = TaskParser.bullet

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                        Text(GrannyLines.carryOver(tasks: carried.joined(separator: ", ")))
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
    var onUpdateSurfaces: (String, [String]) -> Void
    var onRemove: (String) -> Void
    var onOpenSettings: () -> Void

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
                }
                Spacer()
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
                    .help(GrannyLines.surfacesEditHelp)
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
                SurfaceEditorView(
                    task: task,
                    onSave: { surfaces in
                        onUpdateSurfaces(task.id, surfaces)
                        editing = nil
                    },
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

            HStack {
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

/// Editor for one task's allowed surfaces: the URL patterns the rules let
/// through before consulting the block lists. Machine-generated surfaces are
/// sometimes wrong (a moved domain, a missed path) and this is the fix
/// without re-adding the task.
struct SurfaceEditorView: View {
    let task: TaskItem
    var onSave: ([String]) -> Void
    var onCancel: () -> Void

    @State private var surfaces: [String]
    @State private var newSurface = ""

    init(task: TaskItem, onSave: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.onSave = onSave
        self.onCancel = onCancel
        _surfaces = State(initialValue: task.allowedSurfaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GrannyLines.surfacesEditTitle)
                    .font(.system(size: 11, weight: .semibold, design: .serif))
                    .tracking(3)
                    .foregroundStyle(GrannyTheme.gold)
                Text(task.title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundStyle(GrannyTheme.text)
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
                Button(GrannyLines.settingsSave) { onSave(surfaces) }
                    .buttonStyle(GrannyPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .grannyWindowBackdrop()
        .preferredColorScheme(GrannyTheme.colorScheme)
    }

    private func commit() {
        guard let surface = TaskParser.normalizeSurface(newSurface) else { return }
        newSurface = ""
        if !surfaces.contains(surface) {
            surfaces.append(surface)
        }
    }
}
