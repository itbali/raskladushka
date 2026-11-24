import Foundation

/// Двойное нажатие одной клавиши-модификатора (например, Shift, Shift) как сочетание.
/// Удобно тем, кому трудно зажимать несколько клавиш сразу. Чистая логика: времена приходят снаружи.
public struct DoubleTapDetector: Sendable {
    /// Сколько секунд может пройти между двумя нажатиями.
    public var interval: TimeInterval

    private var last: (flags: UInt, time: TimeInterval)?

    public init(interval: TimeInterval = 0.4) {
        self.interval = interval
    }

    /// Модификатор нажали и отпустили, не тронув больше ничего. `true` — это второе такое нажатие подряд.
    public mutating func soloTap(_ flags: UInt, at time: TimeInterval) -> Bool {
        if let last, last.flags == flags, time - last.time <= interval, time >= last.time {
            self.last = nil
            return true
        }
        last = (flags, time)
        return false
    }

    /// Между нажатиями вмешалась другая клавиша или мышь — счёт начинается заново.
    public mutating func interrupted() {
        last = nil
    }
}
