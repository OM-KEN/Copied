import Foundation

/// Builds the date/time detail shown in the toast.
///
/// Date-bearing inputs use calendar-day semantics so their description does not
/// change with the arbitrary time that NSDataDetector assigns to a date-only value.
enum RelativeDateDescription {
    static func string(
        for date: Date,
        subtype: String?,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let relativeFormatter = RelativeDateTimeFormatter()
        relativeFormatter.calendar = calendar
        relativeFormatter.locale = locale
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .named

        switch subtype {
        case "date":
            return calendarDayDescription(
                for: date,
                relativeTo: referenceDate,
                calendar: calendar,
                formatter: relativeFormatter
            )

        case "dateTime":
            let day = calendarDayDescription(
                for: date,
                relativeTo: referenceDate,
                calendar: calendar,
                formatter: relativeFormatter
            )
            let timeFormatter = DateFormatter()
            timeFormatter.calendar = calendar
            timeFormatter.timeZone = calendar.timeZone
            timeFormatter.locale = locale
            timeFormatter.dateStyle = .none
            timeFormatter.timeStyle = .short
            return "\(day) \(timeFormatter.string(from: date))"

        default:
            // Time-only detections and legacy values without subtype metadata keep
            // elapsed-time semantics.
            return relativeFormatter.localizedString(for: date, relativeTo: referenceDate)
        }
    }

    private static func calendarDayDescription(
        for date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar,
        formatter: RelativeDateTimeFormatter
    ) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: calendar.startOfDay(for: referenceDate),
            to: calendar.startOfDay(for: date)
        )
        return formatter.localizedString(from: components)
    }
}
