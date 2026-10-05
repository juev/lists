import Foundation

/// Dates travel through the core as `yyyy-MM-dd` or `yyyy-MM-dd'T'HH:mm`
/// without a time zone: "tomorrow at nine" stays nine wherever the device is.
enum Moment {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    /// Dates are written in the language the interface is shown in, not the system one.
    static let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    private static let dayFormat = formatter("yyyy-MM-dd")
    private static let fullFormat = formatter("yyyy-MM-dd'T'HH:mm")

    static func hasTime(_ value: String) -> Bool { value.count > 10 }

    static func date(_ value: String) -> Date? {
        hasTime(value) ? fullFormat.date(from: value) : dayFormat.date(from: value)
    }

    static func string(_ date: Date, withTime: Bool) -> String {
        withTime ? fullFormat.string(from: date) : dayFormat.string(from: date)
    }

    static func today() -> String { dayFormat.string(from: Date()) }

    static func day(_ value: String) -> String { String(value.prefix(10)) }

    static func isOverdue(_ value: String) -> Bool {
        guard let date = date(value) else { return false }
        return hasTime(value) ? date < Date() : day(value) < today()
    }

    /// "Сегодня", "Завтра, 18:30", "пт, 9 окт".
    static func label(_ value: String) -> String {
        guard let date = date(value) else { return value }
        let days = daysBetween(from: today(), to: day(value)) ?? 0
        var text: String
        switch days {
        case 0: text = L("Today")
        case 1: text = L("Tomorrow")
        case -1: text = L("Yesterday")
        default:
            let f = DateFormatter()
            f.locale = Moment.locale
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
            f.setLocalizedDateFormatFromTemplate(sameYear ? "EEE d MMM" : "d MMM yyyy")
            text = f.string(from: date)
        }
        if hasTime(value) {
            text += ", " + String(value.suffix(5))
        }
        return text
    }

    /// Section title for a day in the Upcoming view.
    static func heading(_ day: String) -> String {
        guard let date = date(day) else { return day }
        let f = DateFormatter()
        f.locale = Moment.locale
        f.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let text = f.string(from: date)
        let days = daysBetween(from: today(), to: day) ?? 0
        return days == 1 ? L("Tomorrow · %@", "\(text)") : text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension Repeat {
    static func every(_ freq: Freq, interval: UInt32 = 1, weekdays: [UInt32] = []) -> Repeat {
        Repeat(freq: freq, interval: interval, weekdays: weekdays, monthday: nil, nth: nil,
               nthWeekday: nil, fromDone: false, count: nil, until: nil)
    }

    static let presets: [(String, Repeat)] = [
        (L("Every day"), .every(.daily)),
        (L("On weekdays"), .every(.weekly, weekdays: [1, 2, 3, 4, 5])),
        (L("Every week"), .every(.weekly)),
        (L("Every two weeks"), .every(.weekly, interval: 2)),
        (L("Every month"), .every(.monthly)),
        (L("Every quarter"), .every(.monthly, interval: 3)),
        (L("Every year"), .every(.yearly)),
    ]

    static let weekdayNames = [L("Mon"), L("Tue"), L("Wed"), L("Thu"), L("Fri"), L("Sat"), L("Sun")]

    /// The rule without the parts that change as the series goes on.
    private var shape: Repeat {
        var r = self
        r.monthday = nil
        r.count = nil
        r.until = nil
        return r
    }

    var presetName: String? {
        guard nth == nil, !fromDone, count == nil, until == nil else { return nil }
        return Repeat.presets.first { $0.1 == shape }?.0
    }

    var summary: String {
        if let name = presetName { return name }
        var text: String
        let n = interval
        switch freq {
        case .daily: text = n == 1 ? L("Every day") : L("Every %@ days", "\(n)")
        case .weekly:
            text = n == 1 ? L("Every week") : L("Every %@ weeks", "\(n)")
            if !weekdays.isEmpty {
                text += ": " + weekdays.sorted().compactMap { d in
                    (1...7).contains(Int(d)) ? Repeat.weekdayNames[Int(d) - 1] : nil
                }.joined(separator: ", ")
            }
        case .monthly:
            text = n == 1 ? L("Every month") : L("Every %@ months", "\(n)")
            if let nth, let wd = nthWeekday, (1...7).contains(Int(wd)) {
                let which = nth < 0 ? L("last") : ordinal(Int(nth))
                text += ", \(which) \(Repeat.weekdayNames[Int(wd) - 1])"
            } else if let monthday {
                text += L(", on day %@", "\(monthday)")
            }
        case .yearly: text = n == 1 ? L("Every year") : L("Every %@ years", "\(n)")
        }
        if fromDone { text += L(" after completion") }
        if let count { text += L(", %@ left", "\(count)") }
        if let until { text += L(", until %@", "\(Moment.label(until).lowercased())") }
        return text
    }
}

extension Priority {
    static let all: [Priority] = [.none, .low, .medium, .high]

    var title: String {
        switch self {
        case .none: return L("No priority")
        case .low: return L("Low")
        case .medium: return L("Medium")
        case .high: return L("High")
        }
    }

    var marks: String {
        switch self {
        case .none: return ""
        case .low: return "!"
        case .medium: return "!!"
        case .high: return "!!!"
        }
    }
}
