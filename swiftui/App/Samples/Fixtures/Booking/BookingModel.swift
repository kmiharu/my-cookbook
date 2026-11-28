import Foundation

struct BookingSlot: Codable, Equatable, Identifiable, Sendable {
    let start: Date
    var id: Date { start }
}

enum BookingSchedule {
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        return result
    }

    static func days(from now: Date) -> ClosedRange<Date> {
        let first = calendar.startOfDay(for: now)
        let last = calendar.date(byAdding: .day, value: 13, to: first) ?? first
        return first...last
    }

    static func slots(on day: Date, now: Date) -> [BookingSlot] {
        guard days(from: now).contains(calendar.startOfDay(for: day)) else { return [] }
        let hours = calendar.isDateInWeekend(day) ? [10, 16] : [10, 13, 16]
        return hours.compactMap { hour in
            guard let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), start > now else { return nil }
            return BookingSlot(start: start)
        }
    }
}

struct BookingCommand: Codable, Equatable, Sendable {
    enum Operation: Codable, Equatable, Sendable {
        case reserve(BookingSlot)
        case move(BookingSlot, expectedRevision: UUID)
        case cancel(expectedRevision: UUID)
    }

    let id: UUID
    let operation: Operation
}

struct FixtureBooking: Codable, Equatable, Sendable {
    let id: UUID
    var revision: UUID
    var slot: BookingSlot
}

struct BookingState: Codable, Equatable, Sendable {
    enum Rejection: Error, Equatable {
        case conflict, invalidSlot, conflictingRetry
    }

    var booking: FixtureBooking?
    private(set) var receipts: [BookingCommand] = []

    mutating func apply(_ command: BookingCommand, now: Date) throws {
        if let previous = receipts.first(where: { $0.id == command.id }) {
            guard previous == command else { throw Rejection.conflictingRetry }
            return
        }
        switch command.operation {
        case .reserve(let slot):
            guard booking == nil else { throw Rejection.conflict }
            try validate(slot, now: now)
            booking = FixtureBooking(id: command.id, revision: command.id, slot: slot)
        case .move(let slot, let revision):
            guard var current = booking, current.revision == revision else { throw Rejection.conflict }
            guard current.slot != slot else { throw Rejection.invalidSlot }
            try validate(slot, now: now)
            current.revision = command.id
            current.slot = slot
            booking = current
        case .cancel(let revision):
            guard booking?.revision == revision else { throw Rejection.conflict }
            booking = nil
        }
        receipts.append(command)
        receipts = Array(receipts.suffix(24))
    }

    private func validate(_ slot: BookingSlot, now: Date) throws {
        guard BookingSchedule.slots(on: slot.start, now: now).contains(slot) else { throw Rejection.invalidSlot }
    }
}
