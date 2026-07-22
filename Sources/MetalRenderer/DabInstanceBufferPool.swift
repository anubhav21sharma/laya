import CShaderTypes
import Metal

struct DabBufferSubmissionIdentity: Equatable, Sendable {
    fileprivate let reservation: DabBufferReservationState.Reservation
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

    private let entries: [Entry]
    private var reservationState: DabBufferReservationState

    public init(
        device: any MTLDevice,
        capacity: Int = GridCanvasContract.instanceCapacity
    ) throws {
        precondition(capacity > 0)

        guard let event = device.makeSharedEvent() else {
            throw MetalRendererError.sharedEventUnavailable
        }
        self.event = event

        var entries: [Entry] = []
        entries.reserveCapacity(GridCanvasContract.inFlightBufferCount)
        let length = capacity
            * MemoryLayout<PatternProjectedStampInstance>.stride

        for index in 0..<GridCanvasContract.inFlightBufferCount {
            guard let buffer = device.makeBuffer(
                length: length,
                options: .storageModeShared
            ) else {
                throw MetalRendererError.instanceBufferAllocationFailed
            }
            buffer.label = "Projected Stamp Instances \(index)"
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

        let buffer = entries[reservation.slot].buffer
        return Lease(
            slot: reservation.slot,
            buffer: buffer,
            capacity: buffer.length
                / MemoryLayout<PatternProjectedStampInstance>.stride,
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
        guard count > 0 else { return [] }

        var leases: [Lease] = []
        leases.reserveCapacity(count)
        for _ in 0..<count {
            guard let lease = acquire() else {
                for lease in leases {
                    abandon(lease)
                }
                return nil
            }
            leases.append(lease)
        }
        return leases
    }

    var unavailableSlotCount: Int {
        reservationState.unavailableSlotCount
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
                to: PatternProjectedStampInstance.self,
                capacity: lease.capacity
            )
        for (offset, dab) in instances.enumerated() {
            destination[offset] = dab.instance
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
