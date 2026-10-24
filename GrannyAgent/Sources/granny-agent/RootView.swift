import AppKit
import SwiftUI
import GrannyCore

/// The three surfaces of the one window. Settings is a tab, not a window: it
/// is still the same day being tuned, and a second window meant leaving the
/// notebook behind every time a key was pasted.
enum GrannyTab: String, CaseIterable {
    case notebook
    case timetable
    case settings

    /// Settings is a gear, not a word: it is the one tab that is a tool
    /// rather than a surface of the day.
    var title: String? {
        switch self {
        case .notebook: return GrannyLines.tabTasks
        case .timetable: return GrannyLines.tabTimetable
        case .settings: return nil
        }
    }
}

/// Which tab the window is on. Owned outside the view so the menu can open
/// the window straight onto a tab.
final class GrannyTabs: ObservableObject {
    @Published var current: GrannyTab = .notebook
}

struct GrannyRootView: View {
    let context: GrannyContext
    @ObservedObject var tabs: GrannyTabs
    @ObservedObject var viewModel: GrannyViewModel
    var onScheduleSave: ([ScheduleSlot], [SlotTag]) -> Void
    var onSettingsSave: (GrannyConfig) -> Void

    /// A tab is built the first time it is opened and then stays mounted,
    /// hidden: both editors keep their edits in `@State`, and a one-click tab
    /// switch must not throw away a timetable half-typed.
    @State private var visited: Set<GrannyTab> = [.notebook]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                notebookTab
                    .opacity(tabs.current == .notebook ? 1 : 0)
                    .allowsHitTesting(tabs.current == .notebook)
                if visited.contains(.timetable) {
                    timetableTab
                        .opacity(tabs.current == .timetable ? 1 : 0)
                        .allowsHitTesting(tabs.current == .timetable)
                }
                if visited.contains(.settings) {
                    settingsTab
                        .opacity(tabs.current == .settings ? 1 : 0)
                        .allowsHitTesting(tabs.current == .settings)
                }
            }
        }
        .grannyWindowBackdrop()
        .foregroundStyle(GrannyTheme.text)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 660)
        .onChange(of: tabs.current) { _, tab in visited.insert(tab) }
    }

    /// A capsule of tabs, the way a utility app wears them: the mark at the
    /// head, the live tab a cream pill, the rest quiet.
    private var tabBar: some View {
        HStack(spacing: 4) {
            mark
                .frame(width: 30, height: 30)
                .padding(.leading, 6)
            ForEach(GrannyTab.allCases, id: \.self) { tab in
                Button {
                    tabs.current = tab
                } label: {
                    tabLabel(tab)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(
                                tabs.current == tab
                                    ? GrannyTheme.text.opacity(0.92)
                                    : Color.clear))
                        .foregroundStyle(
                            tabs.current == tab ? GrannyTheme.background : GrannyTheme.text.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help(tab.title ?? GrannyLines.settingsTitle)
                .pointingHandOnHover()
            }
        }
        .padding(4)
        .background(
            Capsule()
                .fill(GrannyTheme.card.opacity(0.9))
                .overlay(Capsule().stroke(GrannyTheme.hairline, lineWidth: 1)))
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var mark: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .clipShape(Circle())
    }

    @ViewBuilder
    private func tabLabel(_ tab: GrannyTab) -> some View {
        if let title = tab.title {
            Text(title)
                .font(.system(size: 12, weight: tabs.current == tab ? .semibold : .regular,
                              design: .serif))
                .lineLimit(1)
        } else {
            Image(systemName: "gearshape")
                .font(.system(size: 12, weight: tabs.current == tab ? .semibold : .regular))
        }
    }

    @ViewBuilder
    private var notebookTab: some View {
        TaskListView(
            viewModel: viewModel,
            onToggle: { [weak context] id in context?.toggle(taskID: id) },
            onMarkAllDone: { [weak context] in context?.markAllDone() },
            onAdd: { [weak context] text, detail in context?.addTask(text, detail: detail) },
            onUpdateTask: { [weak context] id, title, purpose, detail, surfaces in
                context?.updateTask(
                    taskID: id, title: title, purpose: purpose, detail: detail,
                    surfaces: surfaces)
            },
            onElaborate: { [weak context] title, purpose in
                await context?.elaboratePurpose(title: title, purpose: purpose) ?? nil
            },
            onRemove: { [weak context] id in context?.removeTask(taskID: id) },
            onAssignSlot: { [weak context] id, slot in
                context?.assignSlot(taskID: id, slotID: slot)
            },
            onResumeWork: { [weak context] in context?.clearDayOff() },
            onTogglePomodoro: { [weak context] in context?.togglePomodoro() })
    }

    @ViewBuilder
    private var timetableTab: some View {
        ScheduleView(
            initial: context.schedule.slots,
            tags: context.tags,
            today: context.store.state.tasks,
            onSave: { slots, tags in onScheduleSave(slots, tags) },
            onCancel: { tabs.current = .notebook })
    }

    @ViewBuilder
    private var settingsTab: some View {
        SettingsView(
            config: context.config,
            onSave: onSettingsSave,
            onCancel: { tabs.current = .notebook })
    }

}
