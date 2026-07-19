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
