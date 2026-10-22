import AppKit
import SwiftUI
import GrannyCore

/// The four surfaces of the one window. Settings is a tab, not a window: it
/// is still the same day being tuned, and a second window meant leaving the
/// notebook behind every time a key was pasted.
enum GrannyTab: String, CaseIterable {
    case notebook
    case timetable
    case rhythm
    case settings

    var title: String {
        switch self {
        case .notebook: return GrannyLines.tasksTitle
        case .timetable: return GrannyLines.scheduleTitle
        case .rhythm: return GrannyLines.rhythmTitle
        case .settings: return GrannyLines.settingsTitle
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
    var onSettingsSave: (GrannyConfig) -> Void
    var onSettingsCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            content
        }
        .grannyWindowBackdrop()
        .foregroundStyle(GrannyTheme.text)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 660)
    }

    /// A capsule of tabs, the way a utility app wears them: the mark at the
    /// head, the live tab a cream pill, the rest quiet.
    private var tabBar: some View {
        HStack(spacing: 4) {
            mark
                .frame(width: 34, height: 34)
                .padding(.leading, 6)
            ForEach(GrannyTab.allCases, id: \.self) { tab in
                Button {
                    tabs.current = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 12, weight: tabs.current == tab ? .semibold : .regular,
                                      design: .serif))
                        .lineLimit(1)
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
    private var content: some View {
        switch tabs.current {
        case .notebook:
            TaskListView(
                viewModel: viewModel,
                onToggle: { [weak context] id in context?.toggle(taskID: id) },
                onMarkAllDone: { [weak context] in context?.markAllDone() },
                onAdd: { [weak context] text in context?.addTask(text) },
                onUpdateTask: { [weak context] id, title, purpose, surfaces in
                    context?.updateTask(taskID: id, title: title, purpose: purpose, surfaces: surfaces)
                },
                onElaborate: { [weak context] title, purpose in
                    await context?.elaboratePurpose(title: title, purpose: purpose) ?? nil
                },
                onRemove: { [weak context] id in context?.removeTask(taskID: id) },
                onAssignSlot: { [weak context] id, slot in
                    context?.assignSlot(taskID: id, slotID: slot)
                },
                onResumeWork: { [weak context] in context?.clearDayOff() },
                onOpenSettings: { tabs.current = .settings },
                onTogglePomodoro: { [weak context] in context?.togglePomodoro() })
        case .timetable:
            ScheduleView(
                initial: context.schedule.slots,
                today: context.store.state.tasks,
                onSave: { [weak context] slots in
                    context?.saveSchedule(slots)
                    tabs.current = .notebook
                },
                onCancel: { tabs.current = .notebook })
        case .rhythm:
            RhythmView(viewModel: viewModel)
        case .settings:
            SettingsView(
                config: context.config,
                onSave: onSettingsSave,
                onCancel: {
                    tabs.current = .notebook
                    onSettingsCancel()
                })
        }
    }
}

/// The week's numbers, given a page of their own: the line under the list was
/// one sentence, and a pattern needs a picture.
struct RhythmView: View {
    @ObservedObject var viewModel: GrannyViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(GrannyLines.rhythmTitle)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(GrannyTheme.gold)
            Text(GrannyLines.rhythmSubtitle)
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Rectangle().fill(GrannyTheme.gold.opacity(0.45)).frame(height: 1)

            if let rhythm = viewModel.rhythm {
                Text(GrannyLines.rhythmLine(
                    days: rhythm.days,
                    started: rhythm.started,
                    spread: rhythm.spreadMinutes.map(clockSpread)))
                    .font(.system(size: 15, design: .serif))
                bars(rhythm)
            } else {
                Text(GrannyLines.rhythmEmpty)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(GrannyTheme.text.opacity(0.55))
            }
            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// One bar per day of the window, newest last. Height is the clock: an
    /// early first round is a short bar, because the point is how low it sits,
    /// not how much was done.
    private func bars(_ rhythm: RhythmReport) -> some View {
        let readings = rhythm.firstRounds
        let closingMinute = minutesPerHour * 23
        return HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(readings.enumerated()), id: \.offset) { index, minute in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(index == readings.count - 1
                              ? GrannyTheme.gold
                              : GrannyTheme.text.opacity(0.28))
                        .frame(
                            width: 18,
                            height: minute.map { CGFloat($0) / CGFloat(closingMinute) * 120 + 6 } ?? 4)
                    Text(clockSpread(minute ?? 0))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(GrannyTheme.text.opacity(minute == nil ? 0.25 : 0.5))
                }
            }
        }
        .frame(height: 160, alignment: .bottom)
        .padding(.top, 8)
    }
}
