import CShaderTypes
import Metal

struct DabBufferSubmissionIdentity: Equatable, Sendable {
    fileprivate let reservation: DabBufferReservationState.Reservation
}

struct DabInstanceBufferPoolDiagnosticSnapshot: Equatable, Sendable {
    let currentLeaseCount: Int
    let strokeLeaseHighWater: Int
    let lifetimeLeaseHighWater: Int
}

@MainActor
public final class DabInstanceBufferPool {
    public struct Lease {
        public let slot: Int
        public let buffer: any MTLBuffer
        public let capacity: Int
        public let signalValue: UInt64

        fileprivate let reservation: DabBufferReservationState.Reservation
    }

    private struct Entry {
        let buffer: any MTLBuffer
    }

    public let event: any MTLSharedEvent
    public let capacity: Int

    private let entries: [Entry]
    private var reservationState: DabBufferReservationState
    private var strokeLeaseHighWater = 0
    private var lifetimeLeaseHighWater = 0

    var diagnosticSnapshot: DabInstanceBufferPoolDiagnosticSnapshot {
        DabInstanceBufferPoolDiagnosticSnapshot(
            currentLeaseCount: unavailableSlotCount,
            strokeLeaseHighWater: strokeLeaseHighWater,
            lifetimeLeaseHighWater: lifetimeLeaseHighWater
        )
    }

    func beginStrokeDiagnostics() {
        strokeLeaseHighWater = unavailableSlotCount
    }

    public init(
        device: any MTLDevice,
        capacity: Int = GridCanvasContract.instanceCapacity
    ) throws {
        precondition(capacity > 0)

        guard let event = device.makeSharedEvent() else {
            throw MetalRendererError.sharedEventUnavailable
        }
        self.event = event
        self.capacity = capacity

        var entries: [Entry] = []
        entries.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        let (length, overflow) = capacity.multipliedReportingOverflow(
            by: MemoryLayout<PatternDepositionStampInstance>.stride
        )
        guard !overflow, length > 0 else {
            throw MetalRendererError.instanceBufferAllocationFailed
        }

        for index in 0..<GridCanvasContract.inFlightBufferCount {
            guard let buffer = device.makeBuffer(
                length: length,
                options: .storageModeShared
            ) else {
                throw MetalRendererError.instanceBufferAllocationFailed
            }
            buffer.label = "Deposition Stamp Instances \(index)"
            entries.append(Entry(buffer: buffer))
        }

        self.entries = entries
        reservationState = DabBufferReservationState(
            slotCount: GridCanvasContract.inFlightBufferCount
        )
    }

    public func acquire() -> Lease? {
        guard let reservation = reservationState.acquire(
            completedValue: event.signaledValue
        ) else {
            return nil
        }
        recordLeaseHighWater()

        let buffer = entries[reservation.slot].buffer
        return Lease(
            slot: reservation.slot,
            buffer: buffer,
            capacity: buffer.length
                / MemoryLayout<PatternDepositionStampInstance>.stride,
            signalValue: reservation.signalValue,
            reservation: reservation
        )
    }

    /// Atomically reserves an exact number of upload buffers.
    ///
    /// Replay replacement uses this to ensure that both the settled-prefix
    /// promotion and the complete replacement tail can be encoded before the
    /// old replay texture is cleared. A partial reservation is abandoned when
    /// the full request cannot be satisfied.
    func acquire(count: Int) -> [Lease]? {
        precondition(
            (0...GridCanvasContract.inFlightBufferCount).contains(count)
        )
        guard let reservations = reservationState.acquire(
            count: count,
            completedValue: event.signaledValue
        ) else {
            return nil
        }
        recordLeaseHighWater()
        return reservations.map { reservation in
            let buffer = entries[reservation.slot].buffer
            return Lease(
                slot: reservation.slot,
                buffer: buffer,
                capacity: buffer.length
                    / MemoryLayout<PatternDepositionStampInstance>.stride,
                signalValue: reservation.signalValue,
                reservation: reservation
            )
        }
    }

    var unavailableSlotCount: Int {
        reservationState.unavailableSlotCount(
            completedValue: event.signaledValue
        )
    }

    var maximumLeaseCount: Int {
        entries.count
    }

    public func write(
        _ instances: ArraySlice<IdentifiedDab>,
        into lease: Lease
    ) {
        guard reservationState.isReserved(lease.reservation) else {
            fatalError("Dab buffer lease is no longer reserved")
        }
        precondition(instances.count <= lease.capacity)

        let destination = lease.buffer.contents()
            .bindMemory(
                to: PatternDepositionStampInstance.self,
                capacity: lease.capacity
            )
        for (offset, dab) in instances.enumerated() {
            destination[offset] = dab.instance
        }
    }

    func write(
        _ records: ArraySlice<ProjectedDepositionRecord>,
        into lease: Lease
    ) {
        guard reservationState.isReserved(lease.reservation) else {
            fatalError("Dab buffer lease is no longer reserved")
        }
        precondition(records.count <= lease.capacity)

        let destination = lease.buffer.contents()
            .bindMemory(
                to: PatternDepositionStampInstance.self,
                capacity: lease.capacity
            )
        for (offset, record) in records.enumerated() {
            destination[offset] = record.instance
        }
    }

    public func markSubmitted(
        _ lease: Lease,
        on commandBuffer: any MTLCommandBuffer
    ) {
        _ = submit(lease, on: commandBuffer)
    }

    func submit(
        _ lease: Lease,
        on commandBuffer: any MTLCommandBuffer
    ) -> DabBufferSubmissionIdentity {
        guard reservationState.markSubmitted(lease.reservation) else {
            fatalError("Dab buffer lease is no longer reserved")
        }
        commandBuffer.encodeSignalEvent(event, value: lease.signalValue)
        return DabBufferSubmissionIdentity(
            reservation: lease.reservation
        )
    }

    public func abandon(_ lease: Lease) {
        guard reservationState.abandon(lease.reservation) else {
            fatalError("Dab buffer lease is no longer reserved")
        }
    }

    private func recordLeaseHighWater() {
        let current = unavailableSlotCount
        strokeLeaseHighWater = max(strokeLeaseHighWater, current)
        lifetimeLeaseHighWater = max(lifetimeLeaseHighWater, current)
    }

    func reclaimTerminalFailure(
        _ submissions: [DabBufferSubmissionIdentity]
    ) {
        for submission in submissions {
            _ = reservationState.reclaimTerminalFailure(
                submission.reservation
            )
        }
    }
}
