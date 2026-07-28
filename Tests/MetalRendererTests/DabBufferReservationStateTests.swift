@testable import MetalRenderer
import Testing

@Test
func acquiringReservesEverySlotBeforeSubmission() throws {
    var state = DabBufferReservationState(slotCount: 3)

    let firstCandidate = state.acquire(completedValue: 0)
    let secondCandidate = state.acquire(completedValue: 0)
    let thirdCandidate = state.acquire(completedValue: 0)
    let unavailable = state.acquire(completedValue: 0)
    let first = try #require(firstCandidate)
    let second = try #require(secondCandidate)
    let third = try #require(thirdCandidate)

    #expect(Set([first.slot, second.slot, third.slot]) == Set(0..<3))
    #expect(unavailable == nil)
}

@Test
func abandonReleasesReservationButStaleLeaseCannotReleaseReplacement() throws {
    var state = DabBufferReservationState(slotCount: 1)
    let staleCandidate = state.acquire(completedValue: 0)
    let stale = try #require(staleCandidate)

    let didAbandon = state.abandon(stale)
    let replacementCandidate = state.acquire(completedValue: 0)
    let replacement = try #require(replacementCandidate)
    #expect(replacement.token != stale.token)

    let didAbandonStaleLease = state.abandon(stale)
    let unavailable = state.acquire(completedValue: 0)
    #expect(didAbandon)
    #expect(!didAbandonStaleLease)
    #expect(state.isReserved(replacement))
    #expect(unavailable == nil)
}

@Test
func staleOrDoubleSubmitCannotMutateSlotState() throws {
    var state = DabBufferReservationState(slotCount: 1)
    let firstCandidate = state.acquire(completedValue: 0)
    let first = try #require(firstCandidate)

    let didSubmit = state.markSubmitted(first)
    let didSubmitTwice = state.markSubmitted(first)
    let unavailable = state.acquire(
        completedValue: first.signalValue - 1
    )

    let replacementCandidate = state.acquire(
        completedValue: first.signalValue
    )
    let replacement = try #require(replacementCandidate)
    let didSubmitStaleLease = state.markSubmitted(first)
    let stillUnavailable = state.acquire(
        completedValue: first.signalValue
    )
    #expect(didSubmit)
    #expect(!didSubmitTwice)
    #expect(unavailable == nil)
    #expect(!didSubmitStaleLease)
    #expect(state.isReserved(replacement))
    #expect(stillUnavailable == nil)
}

@Test
func terminalFailureReopensSubmittedSlotWithoutEventAdvance() throws {
    var state = DabBufferReservationState(slotCount: 1)
    let submittedCandidate = state.acquire(completedValue: 0)
    let submitted = try #require(submittedCandidate)
    let didSubmit = state.markSubmitted(submitted)

    let unavailableBeforeFailure = state.acquire(completedValue: 0)
    let didReclaim = state.reclaimTerminalFailure(submitted)
    let replacement = state.acquire(completedValue: 0)

    #expect(didSubmit)
    #expect(unavailableBeforeFailure == nil)
    #expect(didReclaim)
    #expect(replacement != nil)
}

@Test
func staleTerminalFailureCannotReleaseNewerInFlightSubmission() throws {
    var state = DabBufferReservationState(slotCount: 1)
    let staleCandidate = state.acquire(completedValue: 0)
    let stale = try #require(staleCandidate)
    let didSubmitStale = state.markSubmitted(stale)
    let didReclaimStale = state.reclaimTerminalFailure(stale)

    let replacementCandidate = state.acquire(completedValue: 0)
    let replacement = try #require(replacementCandidate)
    let didSubmitReplacement = state.markSubmitted(replacement)
    let didReclaimStaleAgain = state.reclaimTerminalFailure(stale)
    let unavailable = state.acquire(completedValue: 0)

    #expect(didSubmitStale)
    #expect(didReclaimStale)
    #expect(didSubmitReplacement)
    #expect(!didReclaimStaleAgain)
    #expect(unavailable == nil)
}

@Test
func bulkAcquireIsAllOrNoneAndPreservesExistingReservations() throws {
    var state = DabBufferReservationState(slotCount: 3)
    let heldCandidate = state.acquire(completedValue: 0)
    let held = try #require(heldCandidate)

    let unavailable = state.acquire(count: 3, completedValue: 0)
    let remainingCandidate = state.acquire(count: 2, completedValue: 0)
    let remaining = try #require(remainingCandidate)

    #expect(unavailable == nil)
    #expect(state.isReserved(held))
    #expect(remaining.map(\.slot).count == 2)
    #expect(Set([held.slot] + remaining.map(\.slot)) == Set(0..<3))
}

@Test
func zeroBulkAcquireDoesNotConsumeReservationIdentity() throws {
    var state = DabBufferReservationState(slotCount: 1)

    let empty = state.acquire(count: 0, completedValue: 0)
    let firstCandidate = state.acquire(completedValue: 0)
    let first = try #require(firstCandidate)

    #expect(empty == [])
    #expect(first.token == 1)
    #expect(first.signalValue == 1)
}

@Test
func bulkAbandonReturnsEveryReservationExactlyOnce() throws {
    var state = DabBufferReservationState(slotCount: 3)
    let reservationsCandidate = state.acquire(count: 3, completedValue: 0)
    let reservations = try #require(reservationsCandidate)

    let didAbandon = state.abandon(reservations)
    let didAbandonTwice = state.abandon(reservations)
    let unavailableAfterAbandon = state.unavailableSlotCount
    let replacements = state.acquire(count: 3, completedValue: 0)

    #expect(didAbandon)
    #expect(!didAbandonTwice)
    #expect(unavailableAfterAbandon == 0)
    #expect(replacements?.count == 3)
}

@Test
func completedInFlightSlotsAreReportedAsAvailable() throws {
    var state = DabBufferReservationState(slotCount: 1)
    let candidate = state.acquire(completedValue: 0)
    let reservation = try #require(candidate)
    let submitted = state.markSubmitted(reservation)

    #expect(submitted)
    #expect(state.unavailableSlotCount == 1)
    #expect(
        state.unavailableSlotCount(
            completedValue: reservation.signalValue - 1
        ) == 1
    )
    #expect(
        state.unavailableSlotCount(
            completedValue: reservation.signalValue
        ) == 0
    )
}
