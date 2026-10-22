import AppKit
import SwiftUI
import GrannyCore

/// The personal day: the hours granny nudges against. The timetable is a
/// template, not an appointment book - it names each hour, and granny puts the
/// day's tasks inside those names.
struct ScheduleView: View {
    var today: [TaskItem]
    var onSave: ([ScheduleSlot]) -> Void
    var onCancel: () -> Void

    @State private var draft: [ScheduleSlot]

    init(
        initial: [ScheduleSlot],
        today: [TaskItem],
        onSave: @escaping ([ScheduleSlot]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.today = today
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initial)
    }

    private var ordered: [ScheduleSlot] {
        draft.filter { $0.minute != nil }.sorted { ($0.minute ?? 0) < ($1.minute ?? 0) }
    }

    /// A slot with an unreadable hour would silently drop out of the day; the
    /// save button says so instead.
    private var valid: Bool {
        draft.allSatisfy { $0.minute != nil && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var captionStyle: Color { GrannyTheme.text.opacity(0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hairline
            HStack(alignment: .top, spacing: 18) {
                slots
                todayCard
            }
            footer
        }
        .padding(20)
        .grannyWindowBackdrop()
        .foregroundStyle(GrannyTheme.text)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(GrannyLines.scheduleTitle)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(GrannyTheme.gold)
            Text(GrannyLines.scheduleSubtitle)
                .font(.system(size: 22, weight: .semibold, design: .serif))
            Text(GrannyLines.scheduleHint)
                .font(.caption)
                .foregroundStyle(captionStyle)
        }
    }

    private var hairline: some View {
        Rectangle().fill(GrannyTheme.hairline).frame(height: 1)
    }

    private var slots: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(draft.enumerated()), id: \.element.id) { index, _ in
                        row(index)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 360)

            Button {
                draft.append(
                    ScheduleSlot(time: nextTime(), label: "", kind: .deepWork))
            } label: {
                Text("+ " + GrannyLines.scheduleAdd)
                    .font(.system(size: 13, design: .serif))
                    .foregroundStyle(GrannyTheme.gold)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()

            if draft.isEmpty {
                Text(GrannyLines.scheduleEmpty)
                    .font(.system(size: 13, design: .serif))
                    .italic()
                    .foregroundStyle(captionStyle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 10) {
            TextField(GrannyLines.slotTimePlaceholder, text: $draft[index].time)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(GrannyTheme.gold)
                .frame(width: 58)
            TextField(GrannyLines.slotLabelPlaceholder, text: $draft[index].label)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .serif))
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("", selection: $draft[index].kind) {
                ForEach(SlotKind.allCases, id: \.self) { kind in
                    Text(GrannyLines.slotKindName(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button {
                draft.removeAll { $0.id == draft[index].id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(GrannyTheme.text.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(GrannyLines.slotRemoveHelp)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .grannyCard(cornerRadius: 8)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GrannyLines.scheduleToday)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(GrannyTheme.gold)
            let pinned = ordered.compactMap { slot -> (ScheduleSlot, [TaskItem])? in
                let tasks = today.filter { $0.slotID == slot.id }
                return tasks.isEmpty ? nil : (slot, tasks)
            }
            if pinned.isEmpty {
                Text(GrannyLines.scheduleTodayEmpty)
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(captionStyle)
            } else {
                ForEach(pinned, id: \.0.id) { slot, tasks in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.time)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(GrannyTheme.gold)
                        ForEach(tasks) { task in
                            Text(task.title)
                                .font(.system(size: 13, design: .serif))
                                .foregroundStyle(task.done ? captionStyle : GrannyTheme.text)
                                .strikethrough(task.done, color: captionStyle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(14)
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .grannyCard(cornerRadius: 12)
    }

    private var footer: some View {
        HStack {
            if !valid {
                Text(GrannyLines.scheduleInvalid)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.8))
            }
            Spacer()
            Button(GrannyLines.cancelButton) { onCancel() }
                .buttonStyle(GrannySecondaryButtonStyle())
            Button(GrannyLines.settingsSave) {
                onSave(ordered.map { slot in
                    var copy = slot
                    copy.time = Schedule.normalized(slot.time)
                    return copy
                })
            }
                .buttonStyle(GrannyPrimaryButtonStyle())
                .disabled(!valid)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// A new slot lands an hour after the last one, and the clock wraps at
    /// midnight - a day has no 25:00.
    private func nextTime() -> String {
        let last = (ordered.last?.minute ?? Self.defaultStartHour * minutesPerHour) + minutesPerHour
        return String(format: "%02d:00", (last / minutesPerHour) % Self.hoursPerDay)
    }

    /// The first slot a fresh timetable offers: the morning, where a day
    /// usually begins.
    private static let defaultStartHour = 8
    private static let hoursPerDay = 24
}
