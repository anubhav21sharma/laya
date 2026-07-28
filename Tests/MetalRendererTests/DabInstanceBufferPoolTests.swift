import CShaderTypes
import Metal
@testable import MetalRenderer
import Testing

@Suite("Dab instance buffer pool", .serialized)
@MainActor
struct DabInstanceBufferPoolTests {
    @Test
    func buffersUseTheFrozenDepositionStride() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = try DabInstanceBufferPool(device: device, capacity: 2)
        let lease = try #require(pool.acquire())

        #expect(MemoryLayout<PatternDepositionStampInstance>.stride == 256)
        #expect(lease.buffer.length == 512)
        #expect(lease.capacity == 2)

        pool.abandon(lease)
    }

    @Test
    func capacityMultiplicationOverflowThrowsBeforeAllocation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }

        #expect(throws: MetalRendererError.instanceBufferAllocationFailed) {
            _ = try DabInstanceBufferPool(
                device: device,
                capacity: Int.max
            )
        }
    }

    @Test
    func bulkAcquireReturnsAllRequestedLeasesOrNone() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = try DabInstanceBufferPool(device: device, capacity: 1)
        let held = try #require(pool.acquire(count: 2))

        #expect(pool.acquire(count: 2) == nil)
        #expect(pool.unavailableSlotCount == 2)

        for lease in held {
            pool.abandon(lease)
        }
        #expect(pool.unavailableSlotCount == 0)
        #expect(pool.acquire(count: 3)?.count == 3)
    }
}
