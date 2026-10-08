import AppKit
import EventKit
import SwiftUI

/// An event of the day as the Today view shows it (R78).
struct DayEvent: Identifiable, Equatable {
    let id: String
    let title: String
    /// `HH:mm`; nil for an all-day event and for one that began before today.
    let time: String?
    let color: Color
}

/// An event as the system gives it, without EventKit: the order and the time
/// of the block are decided from this alone.
struct RawEvent {
    var id: String
    var title: String
    var start: Date
    var allDay: Bool
    var color: Color
}

/// A calendar of the system, for the list in Settings.
struct EventCalendar: Identifiable, Equatable {
    let id: String
    let title: String
    /// The account the calendar belongs to: two accounts can both have a "Work".
    let source: String
    let color: Color
}

enum DayEvents {
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Events without a time first, then the timed ones by their start; the title settles a tie (R78).
    static func arrange(_ events: [RawEvent], dayStart: Date) -> [DayEvent] {
        let byTitle = { (a: RawEvent, b: RawEvent) in a.title.localizedStandardCompare(b.title) == .orderedAscending }
        let untimed = events.filter { $0.allDay || $0.start < dayStart }.sorted(by: byTitle)
        let timed = events.filter { !$0.allDay && $0.start >= dayStart }
            .sorted { $0.start == $1.start ? byTitle($0, $1) : $0.start < $1.start }
        return untimed.map { DayEvent(id: $0.id, title: $0.title, time: nil, color: $0.color) }
            + timed.map { DayEvent(id: $0.id, title: $0.title, time: timeFormat.string(from: $0.start), color: $0.color) }
    }
}

/// The calendars of the system, read only (R78).
@MainActor
final class SystemCalendars {
    static let shared = SystemCalendars()

    enum Access { case unasked, granted, denied }

    let store = EKEventStore()

    /// Reading the state asks the system nothing.
    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .unasked
        default: return .denied
        }
    }

    /// Shows the prompt of the system; it appears once, later calls answer at once.
    func ask(_ done: @escaping @MainActor () -> Void) {
        store.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    func calendars() -> [EventCalendar] {
        store.calendars(for: .event)
            .map { EventCalendar(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: Color(nsColor: $0.color)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// The events that touch today in the calendars that are not hidden.
    func today(hidden: Set<String>) -> [DayEvent] {
        let shown = store.calendars(for: .event).filter { !hidden.contains($0.calendarIdentifier) }
        let dayStart = Calendar.current.startOfDay(for: Date())
        guard !shown.isEmpty, let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        let found = store.events(matching: store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: shown))
        // The search is by overlap and takes its bounds in: an all-day event of tomorrow begins at the very end of today.
        // Every occurrence of a repeating event carries the same identifier.
        let raw = found.filter { $0.startDate < dayEnd && ($0.endDate > dayStart || $0.startDate >= dayStart) }.map {
            RawEvent(
                id: "\($0.calendarItemIdentifier)@\($0.startDate.timeIntervalSinceReferenceDate)",
                title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay, color: Color(nsColor: $0.calendar.color))
        }
        return DayEvents.arrange(raw, dayStart: dayStart)
    }

    /// Calendar has no public way to be opened on an event or on a day, so the app itself is opened.
    func openCalendar() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The events of the day above the tasks of Today (R78): muted, without a mark, because an event is not a task.
struct EventsBlock: View {
    let events: [DayEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(events) { event in
                Button {
                    SystemCalendars.shared.openCalendar()
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3)
                        if let time = event.time { Text(time).monospacedDigit() }
                        Text(event.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(AppFont.style(.callout))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
