import Foundation

let formatter = ISO8601DateFormatter()
let now = formatter.date(from: "2026-11-30T00:00:00Z")!
let slots = BookingSchedule.slots(on: now, now: now)
precondition(slots.count == 3)
precondition(BookingSchedule.slots(on: now, now: now.addingTimeInterval(8 * 3_600)).isEmpty)

var state = BookingState()
let create = BookingCommand(id: UUID(), operation: .reserve(slots[0]))
try state.apply(create, now: now)
let committed = state
// Simulate losing a response after the first commit. A retry may occur after the slot starts.
try state.apply(create, now: now.addingTimeInterval(3_600))
precondition(state == committed)

let wrongPayload = BookingCommand(id: create.id, operation: .reserve(slots[1]))
expectRejection(.conflictingRetry) { try state.apply(wrongPayload, now: now) }
precondition(state == committed)

let duplicate = BookingCommand(id: UUID(), operation: .reserve(slots[0]))
expectRejection(.conflict) { try state.apply(duplicate, now: now) }
precondition(state == committed)

let invalidSlot = BookingSlot(start: slots[0].start.addingTimeInterval(60))
let invalidMove = BookingCommand(id: UUID(), operation: .move(invalidSlot, expectedRevision: create.id))
expectRejection(.invalidSlot) { try state.apply(invalidMove, now: now) }
precondition(state == committed)

let move = BookingCommand(id: UUID(), operation: .move(slots[1], expectedRevision: create.id))
try state.apply(move, now: now)
precondition(state.booking?.slot == slots[1])
precondition(state.booking?.id == create.id)
precondition(state.booking?.revision == move.id)
let updated = state

let staleCancel = BookingCommand(id: UUID(), operation: .cancel(expectedRevision: create.id))
expectRejection(.conflict) { try state.apply(staleCancel, now: now) }
precondition(state == updated)

let cancel = BookingCommand(id: UUID(), operation: .cancel(expectedRevision: move.id))
try state.apply(cancel, now: now)
try state.apply(cancel, now: now)
precondition(state.booking == nil)
precondition(state.receipts.count == 3)
let saved = try JSONEncoder().encode(state)
let restored = try JSONDecoder().decode(BookingState.self, from: saved)
precondition(restored == state)
print("Booking checks passed: slot validation, idempotent retry, revision conflict, cancellation and JSON round-trip.")

func expectRejection(_ expected: BookingState.Rejection, operation: () throws -> Void) {
    do {
        try operation()
        preconditionFailure("Expected booking rejection: \(expected)")
    } catch let actual as BookingState.Rejection {
        precondition(expected == actual, "Unexpected booking rejection: \(actual)")
    } catch {
        preconditionFailure("Unexpected error: \(error)")
    }
}

let directory = FileManager.default.temporaryDirectory.appending(path: "fixture-check-\(UUID())", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: directory) }
let disk = FixtureDisk("booking.json", initial: BookingState(), directory: directory)
let initial = try await disk.read()
precondition(initial.booking == nil)
let savedBooking = try await disk.update { value in try value.apply(create, now: now) }
let diskValue = try await disk.read()
precondition(savedBooking == diskValue && savedBooking == committed)
let boundedDisk = FixtureDisk("cap.json", initial: "", byteLimit: 20, directory: directory)
try await boundedDisk.update { $0 = "前の値" }
do {
    try await boundedDisk.update { $0 = String(repeating: "あ", count: 20) }
    preconditionFailure("The store accepted a record larger than its cap")
} catch FixtureDisk<String>.StorageError.fileTooLarge {
    let oldValue = try await boundedDisk.read()
    precondition(oldValue == "前の値")
}
print("Fixture storage checks passed: first read, atomic booking write and bounded-size failure recovery.")
