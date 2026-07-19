import CShaderTypes
import Metal

@MainActor
public final class DabInstanceBufferPool {
    public struct Lease {
        public let slot: Int
        public let buffer: any MTLBuffer
        public let capacity: Int
        public let signalValue: UInt64
    }

    private struct Entry {
        let buffer: any MTLBuffer
        var reusableAfterValue: UInt64
    }

    public let event: any MTLSharedEvent

    private var entries: [Entry]
    private var nextSignalValue: UInt64 = 1
    private var searchStart = 0

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
        let length = capacity * MemoryLayout<PatternDabInstance>.stride

        for index in 0..<GridCanvasContract.inFlightBufferCount {
            guard let buffer = device.makeBuffer(
                length: length,
                options: .storageModeShared
            ) else {
                throw MetalRendererError.instanceBufferAllocationFailed
            }
            buffer.label = "Dab Instances \(index)"
            entries.append(Entry(buffer: buffer, reusableAfterValue: 0))
        }

        self.entries = entries
    }

    public func acquire() -> Lease? {
        for offset in entries.indices {
            let index = (searchStart + offset) % entries.count
            guard event.signaledValue >= entries[index].reusableAfterValue else {
                continue
            }

            let signal = nextSignalValue
            nextSignalValue &+= 1
            searchStart = (index + 1) % entries.count

            return Lease(
                slot: index,
                buffer: entries[index].buffer,
                capacity: entries[index].buffer.length
                    / MemoryLayout<PatternDabInstance>.stride,
                signalValue: signal
            )
        }

        return nil
    }

    public func write(
        _ instances: ArraySlice<IdentifiedDab>,
        into lease: Lease
    ) {
        precondition(instances.count <= lease.capacity)

        let destination = lease.buffer.contents()
            .bindMemory(
                to: PatternDabInstance.self,
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
        entries[lease.slot].reusableAfterValue = lease.signalValue
        commandBuffer.encodeSignalEvent(event, value: lease.signalValue)
    }
}
