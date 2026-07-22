import Metal
import MetalRenderer
import PatternEngine
import Testing

@Suite(.serialized)
struct RasterRevisionStoreTests {
    @Test
    func unknownAndStaleReferencesFailWithoutEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())

        let unknown = RasterRevisionReference(
            id: StoredRasterRevisionID(rawValue: 999),
            pixelSize: size,
            regions: regions,
            retainedBytes: 1
        )
        let unknownBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try store.encodeRestore(
                unknown,
                into: texture,
                on: unknownBuffer
            )
        }

        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        store.discard(pair)
        let staleBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try store.encodeRestore(
                pair.before,
                into: texture,
                on: staleBuffer
            )
        }
    }

    @Test
    func textureValidationHappensBeforeCaptureEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let queue = try #require(device.makeCommandQueue())

        let wrongSize = try makeTexture(
            device: device,
            size: PixelSize(width: 63, height: 64)
        )
        let sizeBuffer = try #require(queue.makeCommandBuffer())
        #expect(
            throws: MetalRendererError.rasterRevisionTextureSizeMismatch(
                expectedWidth: 64,
                expectedHeight: 64,
                actualWidth: 63,
                actualHeight: 64
            )
        ) {
            let _ = try store.encodeCapture(
                pair.before,
                from: wrongSize,
                on: sizeBuffer
            )
        }

        let wrongFormat = try makeTexture(
            device: device,
            size: size,
            pixelFormat: .rgba8Unorm
        )
        let formatBuffer = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.invalidRasterRevisionTextureFormat) {
            let _ = try store.encodeCapture(
                pair.before,
                from: wrongFormat,
                on: formatBuffer
            )
        }

        store.discard(pair)
    }

    @Test
    func allocationAccountsForEveryAlignedRegionAndNeverReusesIDs() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let alignment = device.minimumTextureBufferAlignment(
            for: .bgra8Unorm
        )
        let expected = regions.rectangles.reduce(into: 0) { result, rect in
            result += align(rect.width * 4, to: alignment) * rect.height
        }
        let estimated = try store.retainedBytes(
            pixelSize: size,
            regions: regions
        )
        #expect(estimated == expected)
        #expect(store.residentBytes == 0)

        let first = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        #expect(first.before.retainedBytes == expected)
        #expect(first.after.retainedBytes == expected)
        #expect(first.retainedBytes == expected * 2)
        #expect(store.residentBytes == expected * 2)
        let discardedAfterID = first.after.id.rawValue
        store.discard(first)
        #expect(store.residentBytes == 0)

        let second = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        #expect(second.before.id.rawValue > discardedAfterID)
        store.discard(second)
    }

    @Test
    func cancelledAndFailedCapturesUnwindAndRemainProvisional() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        let pairBytes = pair.retainedBytes

        let abandonedBuffer = try #require(queue.makeCommandBuffer())
        let abandoned = try store.encodeCapture(
            pair.before,
            from: texture,
            on: abandonedBuffer
        )
        try store.finalize(abandoned, as: .cancelled)
        #expect(store.residentBytes == pairBytes)
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try store.finalize(abandoned, as: .cancelled)
        }

        let failedBuffer = try #require(queue.makeCommandBuffer())
        let failed = try store.encodeCapture(
            pair.before,
            from: texture,
            on: failedBuffer
        )
        try store.finalize(failed, as: .failed)
        #expect(store.residentBytes == pairBytes)
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try store.finalize(failed, as: .failed)
        }

        store.discard(pair)
        #expect(store.residentBytes == 0)
    }

    @Test
    func operationTokensAreOpaqueAndBoundToTheirCreatingStore() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstStore = RasterRevisionStore(device: device)
        let secondStore = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let firstPair = try firstStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let secondPair = try secondStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        let firstBuffer = try #require(queue.makeCommandBuffer())
        let secondBuffer = try #require(queue.makeCommandBuffer())

        let firstToken = try firstStore.encodeCapture(
            firstPair.before,
            from: texture,
            on: firstBuffer
        )
        let secondToken = try secondStore.encodeCapture(
            secondPair.before,
            from: texture,
            on: secondBuffer
        )

        #expect(firstToken != secondToken)
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try secondStore.finalize(firstToken, as: .cancelled)
        }
        #expect(secondStore.residentBytes == secondPair.retainedBytes)

        try firstStore.finalize(firstToken, as: .cancelled)
        try secondStore.finalize(secondToken, as: .cancelled)
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try firstStore.finalize(firstToken, as: .cancelled)
        }
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try secondStore.finalize(secondToken, as: .cancelled)
        }

        firstStore.discard(firstPair)
        secondStore.discard(secondPair)
        #expect(firstStore.residentBytes == 0)
        #expect(secondStore.residentBytes == 0)
    }

    @Test
    func foreignSameLayoutReferenceCannotRestoreLocalPayload() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstStore = RasterRevisionStore(device: device)
        let secondStore = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let firstPair = try firstStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let secondPair = try secondStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        try captureAndPublish(
            firstPair,
            in: firstStore,
            from: texture,
            on: queue
        )
        try captureAndPublish(
            secondPair,
            in: secondStore,
            from: texture,
            on: queue
        )

        #expect(firstPair.before.id.rawValue == secondPair.before.id.rawValue)
        #expect((firstPair.before.id == secondPair.before.id) == false)
        #expect(firstPair.before.id != secondPair.before.id)
        #expect(firstPair.before != secondPair.before)

        let foreignRestore = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try secondStore.encodeRestore(
                firstPair.before,
                into: texture,
                on: foreignRestore
            )
        }

        firstStore.release(firstPair.revisionIDs)
        secondStore.release(secondPair.revisionIDs)
    }

    @Test
    func foreignSameLayoutIDsDoNotReleaseLocalPayload() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstStore = RasterRevisionStore(device: device)
        let secondStore = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let firstPair = try firstStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let secondPair = try secondStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        try captureAndPublish(
            firstPair,
            in: firstStore,
            from: texture,
            on: queue
        )
        try captureAndPublish(
            secondPair,
            in: secondStore,
            from: texture,
            on: queue
        )
        let secondStoreBytes = secondStore.residentBytes

        #expect(firstPair.revisionIDs != secondPair.revisionIDs)
        secondStore.release(firstPair.revisionIDs)

        #expect(secondStore.residentBytes == secondStoreBytes)
        firstStore.release(firstPair.revisionIDs)
        if secondStore.residentBytes == secondStoreBytes {
            secondStore.release(secondPair.revisionIDs)
        }
        #expect(firstStore.residentBytes == 0)
        #expect(secondStore.residentBytes == 0)
    }

    @Test
    func foreignIDDoesNotBlockValidLocalReleasesInTheSameSet() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstStore = RasterRevisionStore(device: device)
        let secondStore = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let firstPair = try firstStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let secondPair = try secondStore.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        try captureAndPublish(
            firstPair,
            in: firstStore,
            from: texture,
            on: queue
        )
        try captureAndPublish(
            secondPair,
            in: secondStore,
            from: texture,
            on: queue
        )

        secondStore.release([secondPair.before.id, firstPair.before.id])

        #expect(secondStore.residentBytes == secondPair.after.retainedBytes)
        firstStore.release(firstPair.revisionIDs)
        secondStore.release([secondPair.after.id])
        #expect(firstStore.residentBytes == 0)
        #expect(secondStore.residentBytes == 0)
    }

    @Test
    func prematureSuccessFailsTypedAndUnwindsCapture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let token = try store.encodeCapture(
            pair.before,
            from: texture,
            on: commandBuffer
        )

        #expect(
            throws: MetalRendererError.rasterRevisionOperationDidNotComplete
        ) {
            try store.finalize(token, as: .succeeded)
        }
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try store.finalize(token, as: .failed)
        }
        store.discard(pair)
        #expect(store.residentBytes == 0)
    }

    @Test
    func failedRestoreFinalizationCompletesDeferredRelease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())

        let capture = try #require(queue.makeCommandBuffer())
        let beforeCapture = try store.encodeCapture(
            pair.before,
            from: texture,
            on: capture
        )
        let afterCapture = try store.encodeCapture(
            pair.after,
            from: texture,
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try requireCompleted(capture)
        try store.finalize(beforeCapture, as: .succeeded)
        try store.finalize(afterCapture, as: .succeeded)
        store.publish(pair)

        store.release(Set([pair.after.id]))
        #expect(store.residentBytes == pair.before.retainedBytes)
        let missingAfter = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try store.encodeRestore(
                pair.after,
                into: texture,
                on: missingAfter
            )
        }

        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            into: texture,
            on: restore
        )
        store.release(Set([pair.before.id]))
        #expect(store.residentBytes == pair.before.retainedBytes)
        let logicallyReleased = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try store.encodeRestore(
                pair.before,
                into: texture,
                on: logicallyReleased
            )
        }
        try store.finalize(restoreToken, as: .failed)
        #expect(store.residentBytes == 0)
        #expect(throws: MetalRendererError.invalidRasterRevisionOperationToken) {
            try store.finalize(restoreToken, as: .failed)
        }

        let staleBefore = try #require(queue.makeCommandBuffer())
        #expect(throws: MetalRendererError.missingRasterRevision) {
            let _ = try store.encodeRestore(
                pair.before,
                into: texture,
                on: staleBefore
            )
        }
    }

    @Test
    func captureAndRestoreOnlyChangeTheSeparatedRegions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let store = RasterRevisionStore(device: device)
        let size = PixelSize(width: 64, height: 64)
        let regions = regionSet(size: size)
        let texture = try makeTexture(device: device, size: size)
        let queue = try #require(device.makeCommandQueue())
        let original = deterministicBytes(size: size)
        let overwritten = [UInt8](
            repeating: 0xA7,
            count: size.width * size.height * 4
        )
        replace(texture: texture, bytes: original, size: size)

        let pair = try store.allocatePair(
            beforePixelSize: size,
            beforeRegions: regions,
            afterPixelSize: size,
            afterRegions: regions
        )
        let capture = try #require(queue.makeCommandBuffer())
        let beforeCapture = try store.encodeCapture(
            pair.before,
            from: texture,
            on: capture
        )
        let afterCapture = try store.encodeCapture(
            pair.after,
            from: texture,
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try requireCompleted(capture)
        try store.finalize(beforeCapture, as: .succeeded)
        try store.finalize(afterCapture, as: .succeeded)
        store.publish(pair)

        replace(texture: texture, bytes: overwritten, size: size)
        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            into: texture,
            on: restore
        )
        restore.commit()
        restore.waitUntilCompleted()
        try requireCompleted(restore)
        try store.finalize(restoreToken, as: .succeeded)

        let actual = read(texture: texture, size: size)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let offset = (y * size.width + x) * 4
                let isRestored = regions.rectangles.contains {
                    x >= $0.minX && x < $0.maxX
                        && y >= $0.minY && y < $0.maxY
                }
                let expected = isRestored ? original : overwritten
                #expect(
                    Array(actual[offset..<(offset + 4)])
                        == Array(expected[offset..<(offset + 4)]),
                    "Mismatch at (\(x), \(y))"
                )
            }
        }

        store.release(Set([pair.before.id, pair.after.id]))
    }
}

private func regionSet(size: PixelSize) -> PixelRegionSet {
    PixelRegionSet(
        [
            PixelRect(minX: 3, minY: 5, maxX: 12, maxY: 13)!,
            PixelRect(minX: 31, minY: 27, maxX: 47, maxY: 39)!,
        ],
        clippedTo: size
    )
}

private func captureAndPublish(
    _ pair: PendingRasterRevisionPair,
    in store: RasterRevisionStore,
    from texture: any MTLTexture,
    on queue: any MTLCommandQueue
) throws {
    let commandBuffer = try #require(queue.makeCommandBuffer())
    let beforeCapture = try store.encodeCapture(
        pair.before,
        from: texture,
        on: commandBuffer
    )
    let afterCapture = try store.encodeCapture(
        pair.after,
        from: texture,
        on: commandBuffer
    )
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    try requireCompleted(commandBuffer)
    try store.finalize(beforeCapture, as: .succeeded)
    try store.finalize(afterCapture, as: .succeeded)
    store.publish(pair)
}

private func align(_ value: Int, to alignment: Int) -> Int {
    ((value + alignment - 1) / alignment) * alignment
}

private func makeTexture(
    device: any MTLDevice,
    size: PixelSize,
    pixelFormat: MTLPixelFormat = .bgra8Unorm
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: size.width,
        height: size.height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func deterministicBytes(size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    for y in 0..<size.height {
        for x in 0..<size.width {
            let offset = (y * size.width + x) * 4
            bytes[offset] = UInt8(truncatingIfNeeded: x &* 13 &+ y)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: y &* 17 &+ x)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: x ^ y)
            bytes[offset + 3] = 255
        }
    }
    return bytes
}

private func replace(
    texture: any MTLTexture,
    bytes: [UInt8],
    size: PixelSize
) {
    bytes.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, size.width, size.height),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: size.width * 4
        )
    }
}

private func read(texture: any MTLTexture, size: PixelSize) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
    bytes.withUnsafeMutableBytes {
        texture.getBytes(
            $0.baseAddress!,
            bytesPerRow: size.width * 4,
            from: MTLRegionMake2D(0, 0, size.width, size.height),
            mipmapLevel: 0
        )
    }
    return bytes
}

private func requireCompleted(_ commandBuffer: any MTLCommandBuffer) throws {
    #expect(commandBuffer.status == .completed)
    if let error = commandBuffer.error {
        Issue.record("Metal command buffer failed: \(error)")
        throw error
    }
}
