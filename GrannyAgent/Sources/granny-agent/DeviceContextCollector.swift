import AppKit
import EventKit
import Foundation
import GrannyCore

/// Collects the native macOS read-only context behind `device.context`:
/// frontmost application (`NSWorkspace`), open browser tabs (`BrowserJanitor`),
/// and today's authorized Calendar events (`EventKit`), with a deterministic
/// `GRANNY_DEVICE_CONTEXT` seam for the e2e suites.
enum DeviceContextCollector {
    static func snapshot(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> EngineDeviceContext {
        if let raw = ProcessInfo.processInfo.environment[GrannyEnv.deviceContext], !raw.isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let data: Data?
            if trimmed.hasPrefix("{") {
                data = Data(trimmed.utf8)
            } else {
                data = try? Data(contentsOf: URL(fileURLWithPath: raw))
            }
            if let data, let decoded = try? JSONDecoder().decode(EngineDeviceContext.self, from: data) {
                return decoded
            }
            return .empty
        }

        let frontmost: EngineDeviceContext.FrontmostApp? = onMain {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let bundleID = app.bundleIdentifier
            else { return nil }
            let name = app.localizedName ?? bundleID
            return EngineDeviceContext.FrontmostApp(name: name, bundleID: bundleID)
        }
        let tabs = BrowserJanitor.snapshotOpenTabs()
        let events = todayCalendarEvents(now: now, calendar: calendar)
        return EngineDeviceContext(
            frontmostApp: frontmost,
            openTabs: tabs,
            calendarEvents: events)
    }

    private static func todayCalendarEvents(
        now: Date,
        calendar: Calendar
    ) -> [EngineDeviceContext.CalendarEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            return []
        }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                EngineDeviceContext.CalendarEvent(
                    title: event.title ?? "",
                    startAt: formatter.string(from: event.startDate),
                    endAt: formatter.string(from: event.endDate),
                    allDay: event.isAllDay)
            }
    }
}
