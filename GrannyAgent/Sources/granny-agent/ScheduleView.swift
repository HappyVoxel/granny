import AppKit
import SwiftUI
import GrannyCore

/// The personal day: the hours granny nudges against, and the tags that colour
/// them. The timetable is a template, not an appointment book - it names each
/// hour, and granny puts the day's tasks inside those names.
struct ScheduleView: View {
    var today: [TaskItem]
    var onSave: ([ScheduleSlot], [SlotTag]) -> Void
    var onCancel: () -> Void

    @State private var draft: [ScheduleSlot]
    @State private var tags: [SlotTag]
    /// Slots whose tag the user chose by hand: typing a name no longer
    /// re-classifies those, because a deliberate choice is not a guess.
    @State private var pinned: Set<String> = []
    @StateObject private var colourPicker = TagColourPanel()
    /// The slot whose tag menu is open.
    @State private var tagMenuSlot: String?

    init(
        initial: [ScheduleSlot],
        tags: [SlotTag],
        today: [TaskItem],
        onSave: @escaping ([ScheduleSlot], [SlotTag]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.today = today
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: initial)
        _tags = State(initialValue: tags)
    }

    private var ordered: [ScheduleSlot] { Schedule(slots: draft).sorted }

    /// A slot with an unreadable hour would silently drop out of the day; the
    /// save button says so instead.
    private var valid: Bool {
        draft.allSatisfy {
            $0.minute != nil && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var captionStyle: Color { GrannyTheme.text.opacity(0.55) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hairline
            HStack(alignment: .top, spacing: 18) {
                slots.frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(spacing: 14) {
                    todayCard
                    Spacer(minLength: 0)
                }
                .frame(width: 250)
            }
            footer
        }
        .padding(20)
        .grannyWindowBackdrop()
        .foregroundStyle(GrannyTheme.text)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 660)
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
            .frame(maxHeight: 460)

            Button {
                draft.append(ScheduleSlot(
                    time: nextTime(), label: "",
                    tag: tags.first?.id ?? SlotKind.deepWork.rawValue))
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
    }

    private func row(_ index: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(GrannyTheme.tagColor(tag(for: draft[index])))
                .frame(width: 8, height: 8)
            TextField(GrannyLines.slotTimePlaceholder, text: $draft[index].time)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(GrannyTheme.gold)
                .frame(width: 58)
            TextField(GrannyLines.slotLabelPlaceholder, text: $draft[index].label)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .serif))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: draft[index].label) { _, label in
                    classify(index, label: label)
                }
            Button {
                tagMenuSlot = draft[index].id
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(GrannyTheme.tagColor(tag(for: draft[index])))
                        .frame(width: 8, height: 8)
                    Text(tag(for: draft[index])?.displayName ?? GrannyLines.tagNamePlaceholder)
                        .font(.system(size: 12, design: .serif))
                        .foregroundStyle(GrannyTheme.text.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .frame(width: 132, alignment: .leading)
                .background(Capsule().fill(GrannyTheme.card))
                .overlay(Capsule().stroke(GrannyTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(GrannyLines.tagColourHelp)
            .pointingHandOnHover()
            .popover(
                isPresented: Binding(
                    get: { tagMenuSlot == draft[index].id },
                    set: { if !$0 { tagMenuSlot = nil } }),
                arrowEdge: .bottom
            ) {
                tagMenu(index)
            }
            Button {
                draft.removeAll { $0.id == draft[index].id }
                pinned.remove(draft[index].id)
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

    /// Typing the name picks the kind: granny reads the words and moves the
    /// tag herself, and the user overrides by choosing one in the menu.
    private func classify(_ index: Int, label: String) {
        guard draft.indices.contains(index), !label.isEmpty,
              !pinned.contains(draft[index].id) else { return }
        let kind = kindOf(TaskItem(title: label))
        guard let match = tags.first(where: { $0.kind == kind }) else { return }
        draft[index].tag = match.id
    }

    private func tag(for slot: ScheduleSlot) -> SlotTag? {
        tags.first { $0.id == slot.tag }
    }

    /// Everything about tags happens in the slot's own dropdown: pick one,
    /// recolour or rename the one in use, invent another. A separate card
    /// made the user look in two places for one decision.
    private func tagMenu(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(tags) { tag in
                Button {
                    draft[index].tag = tag.id
                    pinned.insert(draft[index].id)
                    tagMenuSlot = nil
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(GrannyTheme.tagColor(tag))
                            .frame(width: 10, height: 10)
                        Text(tag.displayName)
                            .font(.system(size: 13, design: .serif))
                            .foregroundStyle(GrannyTheme.text)
                        Spacer(minLength: 12)
                        if draft[index].tag == tag.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(GrannyTheme.gold)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandOnHover()
            }

            Rectangle().fill(GrannyTheme.hairline).frame(height: 1)

            if let tagIndex = tags.firstIndex(where: { $0.id == draft[index].tag }) {
                HStack(spacing: 10) {
                    Button {
                        colourPicker.onPick = { colour in tags[tagIndex].color = colour.hexString }
                        colourPicker.open(current: NSColor(GrannyTheme.tagColor(tags[tagIndex])))
                    } label: {
                        Circle()
                            .fill(GrannyTheme.tagColor(tags[tagIndex]))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(GrannyTheme.hairline, lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(GrannyLines.tagColourHelp)
                    .pointingHandOnHover()
                    TextField(GrannyLines.tagNamePlaceholder, text: Binding(
                        get: { tags[tagIndex].name ?? tags[tagIndex].displayName },
                        set: { tags[tagIndex].name = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if tags[tagIndex].kind == nil {
                        Button {
                            tags.removeAll { $0.id == tags[tagIndex].id }
                            draft[index].tag = tags.first?.id ?? draft[index].tag
                            tagMenuSlot = nil
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                                .foregroundStyle(GrannyTheme.text.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .help(GrannyLines.tagRemoveHelp)
                        .pointingHandOnHover()
                    }
                }
            }

            Button {
                let tag = SlotTag(
                    id: "custom-\(UUID().uuidString.prefix(8))",
                    name: "",
                    color: "#B59E87")
                tags.append(tag)
                draft[index].tag = tag.id
                pinned.insert(draft[index].id)
            } label: {
                Text("+ " + GrannyLines.tagAdd)
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(GrannyTheme.gold)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(12)
        .frame(width: 250)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(GrannyLines.scheduleToday)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .tracking(3)
                .foregroundStyle(GrannyTheme.gold)
            let pinnedSlots = ordered.compactMap { slot -> (ScheduleSlot, [TaskItem])? in
                let tasks = today.filter { $0.slotID == slot.id }
                return tasks.isEmpty ? nil : (slot, tasks)
            }
            if pinnedSlots.isEmpty {
                Text(GrannyLines.scheduleTodayEmpty)
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(captionStyle)
            } else {
                ForEach(pinnedSlots, id: \.0.id) { slot, tasks in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(slot.time)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(GrannyTheme.tagColor(tag(for: slot)))
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .grannyCard(cornerRadius: 12)
    }

    private var footer: some View {
        HStack {
            if !valid {
                Text(GrannyLines.scheduleInvalid)
                    .font(.caption2)
                    .foregroundStyle(GrannyTheme.warning.opacity(0.9))
            }
            Spacer()
            Button(GrannyLines.cancelButton) { onCancel() }
                .buttonStyle(GrannySecondaryButtonStyle())
            Button(GrannyLines.settingsSave) {
                onSave(normalised(ordered), tags)
            }
            .buttonStyle(GrannyPrimaryButtonStyle())
            .disabled(!valid)
            .keyboardShortcut(.defaultAction)
        }
    }

    /// "9:5" is a time; the file stores "09:05".
    private func normalised(_ slots: [ScheduleSlot]) -> [ScheduleSlot] {
        slots.map { slot in
            var copy = slot
            copy.time = Schedule.normalized(slot.time)
            return copy
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

/// The system colour well is a capsule that reads as a button; the tag wants a
/// dot. So the dot opens the shared colour panel and reads it back.
final class TagColourPanel: NSObject, ObservableObject {
    var onPick: ((Color) -> Void)?

    func open(current: NSColor) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = current
        panel.setTarget(self)
        panel.setAction(#selector(read(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func read(_ sender: NSColorPanel) {
        onPick?(Color(nsColor: sender.color))
    }
}
