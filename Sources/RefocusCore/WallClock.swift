import Foundation

public struct WallClock: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = WallClock.dhakaCalendar()) {
        self.calendar = calendar
    }

    public static func dhakaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka") ?? .current
        return calendar
    }

    public func snapshot(at date: Date) -> ClockSnapshot {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        let slotMinute = minute < 30 ? 0 : 30
        var cycleComponents = components
        cycleComponents.minute = slotMinute
        cycleComponents.second = 0
        let cycleStart = calendar.date(from: cycleComponents) ?? date
        let offset = (minute - slotMinute) * 60 + second

        if offset < 25 * 60 {
            let end = calendar.date(byAdding: .minute, value: 25, to: cycleStart) ?? date
            return ClockSnapshot(
                phase: .focus,
                phaseStart: cycleStart,
                phaseEnd: end,
                cycleStart: cycleStart,
                secondsRemaining: max(0, 25 * 60 - offset)
            )
        }

        let start = calendar.date(byAdding: .minute, value: 25, to: cycleStart) ?? date
        let end = calendar.date(byAdding: .minute, value: 30, to: cycleStart) ?? date
        return ClockSnapshot(
            phase: .screenBreak,
            phaseStart: start,
            phaseEnd: end,
            cycleStart: cycleStart,
            secondsRemaining: max(0, 30 * 60 - offset)
        )
    }

    public func minuteOfDay(for date: Date) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    public func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }
}
