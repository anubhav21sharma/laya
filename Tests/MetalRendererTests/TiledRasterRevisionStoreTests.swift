import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Tiled raster revision store", .serialized)
struct TiledRasterRevisionStoreTests {
    @Test
    func capturesOneTwoAndFourTilesInDeterministicCoordinateOrder() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 513, height: 513)
        let layerID = tiledRevisionLayerID(1)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 16
        )
        let queue = try #require(device.makeCommandQueue())

        for coordinates in [
            [PaintTileCoordinate(x: 0, y: 0)],
            [.init(x: 1, y: 0), .init(x: 0, y: 0)],
            [
                .init(x: 1, y: 1), .init(x: 0, y: 1),
                .init(x: 1, y: 0), .init(x: 0, y: 0),
            ],
        ] {
            let regions = tiledRevisionRegions(for: coordinates, size: size)
            let pair = try store.allocatePair(
                layerID: layerID,
                generation: 7,
                pixelSize: size,
                dirtyRegions: regions,
                beforePresentCoordinates: coordinates,
                afterPresentCoordinates: coordinates
            )
            let expected = Array(Set(coordinates)).sorted()
            let expectedBytes = try expected.reduce(into: 0) {
                $0 += try tiledRevisionRetainedBytes(
                    coordinate: $1,
                    size: size,
                    device: device
                )
            }
            #expect(pair.before.tileCoordinates == expected.map(\.revisionCoordinate))
            #expect(pair.after.tileCoordinates == expected.map(\.revisionCoordinate))
            #expect(pair.before.retainedBytes == expectedBytes)
            let sources = try expected.enumerated().map { index, coordinate in
                let texture = try tiledRevisionTexture(device: device)
                tiledRevisionUpload(
                    tiledRevisionBytes(seed: UInt8(index + 1)),
                    to: texture
                )
                return TiledRasterRevisionTileSource.texture(
                    coordinate: coordinate,
                    texture: texture
                )
            }
            let capture = try #require(queue.makeCommandBuffer())
            let before = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 7,
                sources: Array(sources.reversed()),
                on: capture
            )
            let after = try store.encodeCapture(
                pair.after,
                layerID: layerID,
                generation: 7,
                sources: sources,
                on: capture
            )
            capture.commit()
            capture.waitUntilCompleted()
            try tiledRevisionRequireCompleted(capture)
            try store.finalize(before, as: .succeeded)
            try store.finalize(after, as: .succeeded)
            try store.publish(pair)

            let targets = try expected.map {
                TiledRasterRevisionTileTarget(
                    coordinate: $0,
                    texture: try tiledRevisionTexture(device: device)
                )
            }
            let restore = try #require(queue.makeCommandBuffer())
            let restoreToken = try store.encodeRestore(
                pair.before,
                layerID: layerID,
                generation: 7,
                targets: Array(targets.reversed()),
                on: restore
            )
            restore.commit()
            restore.waitUntilCompleted()
            try tiledRevisionRequireCompleted(restore)
            try store.finalize(restoreToken, as: .succeeded)
            for (index, target) in targets.enumerated() {
                let descriptor = try PaintTileDescriptor(
                    coordinate: target.coordinate,
                    logicalPixelSize: size
                )
                let actual = tiledRevisionDownload(target.texture)
                let source = tiledRevisionBytes(seed: UInt8(index + 1))
                #expect(tiledRevisionClippedBytes(
                    actual,
                    width: descriptor.logicalBounds.width,
                    height: descriptor.logicalBounds.height
                ) == tiledRevisionClippedBytes(
                    source,
                    width: descriptor.logicalBounds.width,
                    height: descriptor.logicalBounds.height
                ))
            }
            try store.release(pair.revisionIDs)
        }
    }

    @Test
    func captureRestorePreservesClippedPixelsAndExplicitClearTiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 300, height: 256)
        let layerID = tiledRevisionLayerID(2)
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        let coordinates = [first, edge]
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 4
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 11,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: coordinates, size: size),
            beforePresentCoordinates: [first],
            afterPresentCoordinates: [edge]
        )
        #expect(pair.before.retainedBytes == PaintTileDescriptor.residentByteCount)
        let edgeExpectedBytes = try tiledRevisionRetainedBytes(
            coordinate: edge,
            size: size,
            device: device
        )
        #expect(pair.after.retainedBytes == edgeExpectedBytes)

        let beforeTexture = try tiledRevisionTexture(device: device)
        let afterTexture = try tiledRevisionTexture(device: device)
        let beforeBytes = tiledRevisionBytes(seed: 17)
        let afterBytes = tiledRevisionBytes(seed: 91)
        tiledRevisionUpload(beforeBytes, to: beforeTexture)
        tiledRevisionUpload(afterBytes, to: afterTexture)
        let queue = try #require(device.makeCommandQueue())
        let capture = try #require(queue.makeCommandBuffer())
        let beforeToken = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 11,
            sources: [
                .knownClear(coordinate: edge),
                .texture(coordinate: first, texture: beforeTexture),
            ],
            on: capture
        )
        let afterToken = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 11,
            sources: [
                .texture(coordinate: edge, texture: afterTexture),
                .knownClear(coordinate: first),
            ],
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try tiledRevisionRequireCompleted(capture)
        try store.finalize(beforeToken, as: .succeeded)
        try store.finalize(afterToken, as: .succeeded)
        try store.publish(pair)

        let snapshots = try store.snapshotsForHarness()
        #expect(snapshots.count == 2)
        let beforeSnapshot = try #require(snapshots.first {
            $0.reference.id == pair.before.id
        })
        #expect(beforeSnapshot.payloads.map(\.coordinate) == [first, edge])
        #expect(beforeSnapshot.payloads[0].payload == .rgba16Float(beforeBytes))
        #expect(beforeSnapshot.payloads[1].payload == .knownClear)
        let afterSnapshot = try #require(snapshots.first {
            $0.reference.id == pair.after.id
        })
        guard case let .rgba16Float(edgePayload) = afterSnapshot.payloads[1].payload
        else {
            Issue.record("Edge tile must retain RGBA16F bytes")
            return
        }
        #expect(edgePayload.count == 44 * 256 * 8)
        #expect(edgePayload == tiledRevisionClippedBytes(afterBytes, width: 44, height: 256))

        let restoredFirst = try tiledRevisionTexture(device: device)
        let restoredEdge = try tiledRevisionTexture(device: device)
        tiledRevisionUpload(Data(repeating: 0xA7, count: PaintTileDescriptor.residentByteCount), to: restoredFirst)
        tiledRevisionUpload(Data(repeating: 0xA7, count: PaintTileDescriptor.residentByteCount), to: restoredEdge)
        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            layerID: layerID,
            generation: 11,
            targets: [
                .init(coordinate: edge, texture: restoredEdge),
                .init(coordinate: first, texture: restoredFirst),
            ],
            on: restore
        )
        restore.commit()
        restore.waitUntilCompleted()
        try tiledRevisionRequireCompleted(restore)
        try store.finalize(restoreToken, as: .succeeded)
        #expect(tiledRevisionDownload(restoredFirst) == beforeBytes)
        let restoredEdgeBytes = tiledRevisionDownload(restoredEdge)
        #expect(tiledRevisionClippedBytes(restoredEdgeBytes, width: 44, height: 256) == Data(count: 44 * 256 * 8))
        #expect(restoredEdgeBytes[(44 * 8)] == 0xA7)
    }

    @Test
    func eraseToEmptyUsesNoRetainedBufferForAfterRevision() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        let pair = try store.allocatePair(
            layerID: tiledRevisionLayerID(3),
            generation: 0,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [coordinate],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: []
        )
        #expect(pair.before.retainedBytes == PaintTileDescriptor.residentByteCount)
        #expect(pair.after.retainedBytes == 0)
        #expect(store.residentBytes == PaintTileDescriptor.residentByteCount)
    }

    @Test
    func installLeaseConsumesOnceAfterCompleteGenerationScopedGPUCopy() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 300, height: 256)
        let layerID = tiledRevisionLayerID(30)
        let first = PaintTileCoordinate(x: 0, y: 0)
        let edge = PaintTileCoordinate(x: 1, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 3
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 77,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [edge, first], size: size),
            beforePresentCoordinates: [first],
            afterPresentCoordinates: [edge]
        )
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try store.beginInstall(for: pair.after)
        }

        let source = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let before = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 77,
            sources: [
                .texture(coordinate: first, texture: source),
                .knownClear(coordinate: edge),
            ],
            on: command
        )
        let after = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 77,
            sources: [
                .knownClear(coordinate: first),
                .texture(coordinate: edge, texture: source),
            ],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try store.finalize(before, as: .succeeded)
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try store.beginInstall(for: pair.after)
        }
        try store.finalize(after, as: .succeeded)

        let lease = try store.beginInstall(for: pair.after)
        #expect(lease.reference == pair.after)
        #expect(lease.layerID == layerID)
        #expect(lease.generation == 77)
        #expect(lease.tiles.map(\.descriptor.coordinate) == [first, edge])
        #expect(lease.tiles.map(\.disposition) == [.remove, .replace])
        #expect(lease.surfaceRevisionAdvance == 1)
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            try store.publish(pair)
        }

        let replacement = try tiledRevisionTexture(device: device)
        let install = try #require(queue.makeCommandBuffer())
        let installToken = try store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 77,
            targets: [.init(coordinate: edge, texture: replacement)],
            on: install
        )
        install.commit()
        install.waitUntilCompleted()
        try tiledRevisionRequireCompleted(install)
        try store.finalize(installToken, as: .succeeded)
        #expect(throws: TiledRasterRevisionStoreError.layerMismatch(
            expected: layerID,
            actual: tiledRevisionLayerID(31)
        )) {
            try store.consumeInstall(
                lease,
                layerID: tiledRevisionLayerID(31),
                generation: 77
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.generationMismatch(
            expected: 77,
            actual: 78
        )) {
            try store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 78
            )
        }
        try store.consumeInstall(
            lease,
            layerID: layerID,
            generation: 77
        )
        #expect(throws: TiledRasterRevisionStoreError.invalidInstallLease) {
            try store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 77
            )
        }
        try store.publish(pair)
        let installed = tiledRevisionDownload(replacement)
        #expect(tiledRevisionClippedBytes(
            installed,
            width: 44,
            height: 256
        ) == tiledRevisionClippedBytes(
            tiledRevisionDownload(source),
            width: 44,
            height: 256
        ))
    }

    @Test
    func releaseDefersUntilLiveInstallLeaseIsConsumed() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(32)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 8,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [],
            afterPresentCoordinates: [coordinate]
        )
        try fixture.store.publish(fixture.pair)
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)
        try fixture.store.release([fixture.pair.after.id])
        #expect(fixture.store.containsRevision(fixture.pair.after.id))
        #expect(fixture.store.residentBytes == fixture.pair.after.retainedBytes)

        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let target = try tiledRevisionTexture(device: device)
        let operation = try fixture.store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 8,
            targets: [.init(coordinate: coordinate, texture: target)],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try fixture.store.finalize(operation, as: .succeeded)
        try fixture.store.consumeInstall(
            lease,
            layerID: layerID,
            generation: 8
        )

        #expect(!fixture.store.containsRevision(fixture.pair.after.id))
        #expect(fixture.store.residentBytes == fixture.pair.before.retainedBytes)
    }

    @Test
    func preEncodeCandidateFailureCanCancelRetryAndCompleteRelease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(33)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 9,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        try fixture.store.publish(fixture.pair)
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)

        #expect(throws: TiledRasterRevisionStoreError.layerMismatch(
            expected: layerID,
            actual: tiledRevisionLayerID(93)
        )) {
            try fixture.store.cancelInstall(
                lease,
                layerID: tiledRevisionLayerID(93),
                generation: 9
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.generationMismatch(
            expected: 9,
            actual: 10
        )) {
            try fixture.store.cancelInstall(
                lease,
                layerID: layerID,
                generation: 10
            )
        }
        // Candidate allocation failed before encodeInstall; abandon the lease.
        try fixture.store.cancelInstall(
            lease,
            layerID: layerID,
            generation: 9
        )
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)

        let retry = try fixture.store.beginInstall(for: fixture.pair.after)
        #expect(retry != lease)
        try fixture.store.release([fixture.pair.after.id])
        #expect(fixture.store.containsRevision(fixture.pair.after.id))
        try fixture.store.cancelInstall(
            retry,
            layerID: layerID,
            generation: 9
        )
        #expect(!fixture.store.containsRevision(fixture.pair.after.id))
        #expect(fixture.store.residentBytes == fixture.pair.before.retainedBytes)
        #expect(throws: TiledRasterRevisionStoreError.invalidInstallLease) {
            try fixture.store.cancelInstall(
                retry,
                layerID: layerID,
                generation: 9
            )
        }
    }

    @Test
    func cancelReadyInstallUnpinsAndAllowsImmediateRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(34)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 10,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let operation = try fixture.store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 10,
            targets: [
                .init(
                    coordinate: coordinate,
                    texture: try tiledRevisionTexture(device: device)
                ),
            ],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try fixture.store.finalize(operation, as: .succeeded)

        try fixture.store.cancelInstall(
            lease,
            layerID: layerID,
            generation: 10
        )
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)
        let retry = try fixture.store.beginInstall(for: fixture.pair.after)
        try fixture.store.cancelInstall(
            retry,
            layerID: layerID,
            generation: 10
        )
        try fixture.store.discard(fixture.pair)
    }

    @Test
    func cancelEncodingDefersUnpinUntilFinalizeAndAllowsRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(35)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 11,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let baselineBytes = fixture.store.residentBytes
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let operation = try fixture.store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 11,
            targets: [
                .init(
                    coordinate: coordinate,
                    texture: try tiledRevisionTexture(device: device)
                ),
            ],
            on: command
        )

        try fixture.store.cancelInstall(
            lease,
            layerID: layerID,
            generation: 11
        )
        let deferred = fixture.store.snapshot()
        #expect(deferred.inFlightInstallLeaseCount == 1)
        #expect(deferred.inFlightOperationCount == 1)
        #expect(deferred.residentBytes == baselineBytes)
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try fixture.store.beginInstall(for: fixture.pair.after)
        }

        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try fixture.store.finalize(operation, as: .succeeded)
        let completed = fixture.store.snapshot()
        #expect(completed.inFlightInstallLeaseCount == 0)
        #expect(completed.inFlightOperationCount == 0)
        #expect(completed.residentBytes == baselineBytes)
        #expect(throws: TiledRasterRevisionStoreError.invalidInstallLease) {
            try fixture.store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 11
            )
        }

        let retry = try fixture.store.beginInstall(for: fixture.pair.after)
        try fixture.store.cancelInstall(
            retry,
            layerID: layerID,
            generation: 11
        )
        try fixture.store.discard(fixture.pair)
    }

    @Test
    func discardWaitsForEncodingInstallBeforeReleasingAccounting() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(36)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 12,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let baselineBytes = fixture.store.residentBytes
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let target = try tiledRevisionTexture(device: device)
        let operation = try fixture.store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 12,
            targets: [.init(coordinate: coordinate, texture: target)],
            on: command
        )

        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            try fixture.store.discard(fixture.pair)
        }
        #expect(fixture.store.residentBytes == baselineBytes)
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 1)
        #expect(fixture.store.snapshot().inFlightOperationCount == 1)
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try fixture.store.finalize(operation, as: .succeeded)
        try fixture.store.discard(fixture.pair)

        #expect(fixture.store.residentBytes == 0)
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)
        #expect(fixture.store.snapshot().inFlightOperationCount == 0)
        #expect(throws: TiledRasterRevisionStoreError.invalidOperationToken) {
            try fixture.store.finalize(operation, as: .succeeded)
        }
        #expect(throws: TiledRasterRevisionStoreError.invalidInstallLease) {
            try fixture.store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 12
            )
        }
        let reusable = try fixture.store.allocatePair(
            layerID: layerID,
            generation: 13,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [coordinate],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        try fixture.store.discard(reusable)
    }

    @Test
    func failedInstallEncodingInvalidatesLeaseAndLeavesStoreReusable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(37)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 10,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let baseline = fixture.store.snapshot()
        let lease = try fixture.store.beginInstall(for: fixture.pair.after)
        let target = try tiledRevisionTexture(device: device)
        let command = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )

        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
            .commandEncoding
        )) {
            _ = try fixture.store.encodeInstall(
                lease,
                layerID: layerID,
                generation: 10,
                targets: [.init(coordinate: coordinate, texture: target)],
                on: command,
                failureInjection: .init(failingAt: .commandEncoding)
            )
        }

        let snapshot = fixture.store.snapshot()
        #expect(snapshot.inFlightInstallLeaseCount == 0)
        #expect(snapshot.inFlightOperationCount == 0)
        #expect(snapshot == baseline)
        #expect(throws: TiledRasterRevisionStoreError.invalidInstallLease) {
            try fixture.store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 10
            )
        }

        let replacement = try fixture.store.beginInstall(
            for: fixture.pair.after
        )
        #expect(replacement != lease)
        try fixture.store.discard(fixture.pair)
    }

    @Test
    func rejectsStaleForeignLayerGenerationFormatAndCoordinateWithoutMutation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 256)
        let layerID = tiledRevisionLayerID(4)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 4
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 9,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [coordinate], size: size),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let baseline = store.snapshot()
        let texture = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())

        #expect(throws: TiledRasterRevisionStoreError.layerMismatch(
            expected: layerID,
            actual: tiledRevisionLayerID(99)
        )) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: tiledRevisionLayerID(99),
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.generationMismatch(
            expected: 9,
            actual: 10
        )) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 10,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.coordinateSetMismatch) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: .init(x: 1, y: 0), texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        let wrongFormat = try tiledRevisionTexture(
            device: device,
            pixelFormat: .bgra8Unorm
        )
        #expect(throws: TiledRasterRevisionStoreError.invalidTextureFormat) {
            _ = try store.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: wrongFormat)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
        #expect(store.snapshot() == baseline)

        let foreign = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        #expect(throws: TiledRasterRevisionStoreError.missingRevision) {
            _ = try foreign.encodeCapture(
                pair.before,
                layerID: layerID,
                generation: 9,
                sources: [.texture(coordinate: coordinate, texture: texture)],
                on: try #require(queue.makeCommandBuffer())
            )
        }
    }

    @Test
    func duplicateFinalizeAndReleaseDuringRestoreAreSafe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 256, height: 256)
        let layerID = tiledRevisionLayerID(5)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount * 2
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            generation: 1,
            pixelSize: size,
            dirtyRegions: tiledRevisionRegions(for: [coordinate], size: size),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let source = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let capture = try #require(queue.makeCommandBuffer())
        let before = try store.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 1,
            sources: [.texture(coordinate: coordinate, texture: source)],
            on: capture
        )
        let after = try store.encodeCapture(
            pair.after,
            layerID: layerID,
            generation: 1,
            sources: [.texture(coordinate: coordinate, texture: source)],
            on: capture
        )
        capture.commit()
        capture.waitUntilCompleted()
        try tiledRevisionRequireCompleted(capture)
        try store.finalize(before, as: .succeeded)
        #expect(throws: TiledRasterRevisionStoreError.invalidOperationToken) {
            try store.finalize(before, as: .succeeded)
        }
        try store.finalize(after, as: .succeeded)
        try store.publish(pair)

        let target = try tiledRevisionTexture(device: device)
        let restore = try #require(queue.makeCommandBuffer())
        let restoreToken = try store.encodeRestore(
            pair.before,
            layerID: layerID,
            generation: 1,
            targets: [.init(coordinate: coordinate, texture: target)],
            on: restore
        )
        try store.release([pair.before.id])
        #expect(store.containsRevision(pair.before.id))
        restore.commit()
        restore.waitUntilCompleted()
        try tiledRevisionRequireCompleted(restore)
        try store.finalize(restoreToken, as: .succeeded)
        #expect(!store.containsRevision(pair.before.id))
        #expect(store.containsRevision(pair.after.id))
    }

    @Test
    func allocationAndPipelineFailuresPublishNothingAndLeaveStoreReusable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let bytes = PaintTileDescriptor.residentByteCount
        let size = PixelSize(width: 512, height: 256)
        let coordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            PaintTileCoordinate(x: 1, y: 0),
        ]
        let layerID = tiledRevisionLayerID(6)
        let regions = tiledRevisionRegions(for: coordinates, size: size)

        for allocationIndex in 0..<2 {
            let store = TiledRasterRevisionStore(
                device: device,
                maximumRetainedBytes: bytes * 4
            )
            #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
                .bufferAllocation(allocationIndex)
            )) {
                _ = try store.allocatePair(
                    layerID: layerID,
                    generation: 2,
                    pixelSize: size,
                    dirtyRegions: regions,
                    beforePresentCoordinates: coordinates,
                    afterPresentCoordinates: coordinates,
                    failureInjection: .init(
                        failingAt: .bufferAllocation(allocationIndex)
                    )
                )
            }
            #expect(store.snapshot() == .empty(maximumRetainedBytes: bytes * 4))
        }

        for point in [
            TiledRasterRevisionFailurePoint.tileCapture(0),
            .tileCapture(1),
            .commandEncoding,
        ] {
            let store = TiledRasterRevisionStore(
                device: device,
                maximumRetainedBytes: bytes * 4
            )
            let pair = try store.allocatePair(
                layerID: layerID,
                generation: 2,
                pixelSize: size,
                dirtyRegions: regions,
                beforePresentCoordinates: coordinates,
                afterPresentCoordinates: coordinates
            )
            let textures = try coordinates.map { coordinate in
                TiledRasterRevisionTileSource.texture(
                    coordinate: coordinate,
                    texture: try tiledRevisionTexture(device: device)
                )
            }
            let queue = try #require(device.makeCommandQueue())
            #expect(throws: TiledRasterRevisionStoreError.injectedFailure(point)) {
                _ = try store.encodeCapture(
                    pair.before,
                    layerID: layerID,
                    generation: 2,
                    sources: textures,
                    on: try #require(queue.makeCommandBuffer()),
                    failureInjection: .init(failingAt: point)
                )
            }
            #expect(store.residentBytes == 0)
            #expect(store.snapshot().publishedRevisionCount == 0)
            #expect(store.snapshot().provisionalRevisionCount == 0)
        }

        let completionStore = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: bytes * 2
        )
        let pair = try completionStore.allocatePair(
            layerID: layerID,
            generation: 2,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [.init(x: 0, y: 0)],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [.init(x: 0, y: 0)],
            afterPresentCoordinates: [.init(x: 0, y: 0)]
        )
        let texture = try tiledRevisionTexture(device: device)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let token = try completionStore.encodeCapture(
            pair.before,
            layerID: layerID,
            generation: 2,
            sources: [.texture(coordinate: .init(x: 0, y: 0), texture: texture)],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(.completion)) {
            try completionStore.finalize(
                token,
                as: .succeeded,
                failureInjection: .init(failingAt: .completion)
            )
        }
        #expect(completionStore.residentBytes == 0)
        #expect(completionStore.snapshot().provisionalRevisionCount == 0)

        let reusable = try completionStore.allocatePair(
            layerID: layerID,
            generation: 3,
            pixelSize: PixelSize(width: 256, height: 256),
            dirtyRegions: tiledRevisionRegions(
                for: [.init(x: 0, y: 0)],
                size: PixelSize(width: 256, height: 256)
            ),
            beforePresentCoordinates: [],
            afterPresentCoordinates: []
        )
        #expect(reusable.retainedBytes == 0)
        try completionStore.discard(reusable)
    }

    @Test
    func byteBudgetIsCheckedAndRepeatedDirtyRegionsCaptureTileOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 512, height: 512)
        let layerID = tiledRevisionLayerID(7)
        let tile = PaintTileCoordinate(x: 0, y: 0)
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: PaintTileDescriptor.residentByteCount
        )
        let repeated = PixelRegionSet(
            [
                PixelRect(minX: 2, minY: 2, maxX: 20, maxY: 20)!,
                PixelRect(minX: 80, minY: 80, maxX: 120, maxY: 120)!,
                PixelRect(minX: 180, minY: 180, maxX: 200, maxY: 200)!,
            ],
            clippedTo: size
        )
        let clearBefore = try store.allocatePair(
            layerID: layerID,
            generation: 0,
            pixelSize: size,
            dirtyRegions: repeated,
            beforePresentCoordinates: [],
            afterPresentCoordinates: [tile]
        )
        #expect(clearBefore.after.tileCoordinates == [tile.revisionCoordinate])
        #expect(clearBefore.retainedBytes == PaintTileDescriptor.residentByteCount)
        try store.discard(clearBefore)

        #expect(throws: TiledRasterRevisionStoreError.byteBudgetExceeded(
            requiredBytes: PaintTileDescriptor.residentByteCount * 2,
            availableBytes: PaintTileDescriptor.residentByteCount
        )) {
            _ = try store.allocatePair(
                layerID: layerID,
                generation: 0,
                pixelSize: size,
                dirtyRegions: repeated,
                beforePresentCoordinates: [tile],
                afterPresentCoordinates: [tile]
            )
        }
        #expect(store.residentBytes == 0)
    }

    @Test
    func endpointRequiresExactSortedCoordinatesAndPresentSubset() throws {
        let size = PixelSize(width: 768, height: 512)
        let first = PaintTileCoordinate(x: 0, y: 0)
        let second = PaintTileCoordinate(x: 1, y: 0)
        #expect(throws: TiledRasterRevisionStoreError.unsortedCoordinate(
            previous: second,
            current: first
        )) {
            _ = try TiledRasterRevisionEndpoint(
                generation: 1,
                pixelSize: size,
                documentPixelSize: size,
                coordinates: [second, first],
                presentCoordinates: []
            )
        }
        #expect(throws: TiledRasterRevisionStoreError
            .duplicateCoordinate(first)) {
            _ = try TiledRasterRevisionEndpoint(
                generation: 1,
                pixelSize: size,
                documentPixelSize: size,
                coordinates: [first, first],
                presentCoordinates: []
            )
        }
        #expect(throws: TiledRasterRevisionStoreError.unsortedCoordinate(
            previous: second,
            current: first
        )) {
            _ = try TiledRasterRevisionEndpoint(
                generation: 1,
                pixelSize: size,
                documentPixelSize: size,
                coordinates: [first, second],
                presentCoordinates: [second, first]
            )
        }
        #expect(throws: TiledRasterRevisionStoreError
            .presentCoordinateOutsideDirtySet(.init(x: 2, y: 0))) {
            _ = try TiledRasterRevisionEndpoint(
                generation: 1,
                pixelSize: size,
                documentPixelSize: size,
                coordinates: [first, second],
                presentCoordinates: [.init(x: 2, y: 0)]
            )
        }
        #expect(throws: TiledRasterRevisionStoreError
            .coordinateOutsidePixelSize(.init(x: 3, y: 0))) {
            _ = try TiledRasterRevisionEndpoint(
                generation: 1,
                pixelSize: size,
                documentPixelSize: size,
                coordinates: [.init(x: 3, y: 0)],
                presentCoordinates: []
            )
        }
    }

    @Test
    func distinctEndpointsPreserveSparseHolesGeometryAndExactBytes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(40)
        let beforePhysical = PixelSize(width: 512, height: 512)
        let beforeVisible = PixelSize(width: 2_048, height: 2_048)
        let afterPhysical = PixelSize(width: 257, height: 513)
        let afterVisible = PixelSize(width: 1_024, height: 768)
        let beforeCoordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            .init(x: 1, y: 0),
            .init(x: 0, y: 1),
        ]
        let afterCoordinates = [
            PaintTileCoordinate(x: 0, y: 0),
            .init(x: 0, y: 1),
            .init(x: 1, y: 1),
            .init(x: 0, y: 2),
        ]
        let beforePresent = [beforeCoordinates[0], beforeCoordinates[2]]
        let afterPresent = [afterCoordinates[1], afterCoordinates[2]]
        let before = try TiledRasterRevisionEndpoint(
            generation: 7,
            pixelSize: beforePhysical,
            documentPixelSize: beforeVisible,
            coordinates: beforeCoordinates,
            presentCoordinates: beforePresent
        )
        let after = try TiledRasterRevisionEndpoint(
            generation: 11,
            pixelSize: afterPhysical,
            documentPixelSize: afterVisible,
            coordinates: afterCoordinates,
            presentCoordinates: afterPresent
        )
        let expectedBeforeRegions = tiledRevisionRegions(
            for: beforeCoordinates,
            size: beforePhysical
        )
        let expectedAfterRegions = tiledRevisionRegions(
            for: afterCoordinates,
            size: afterPhysical
        )
        #expect(before.regions == expectedBeforeRegions)
        #expect(after.regions == expectedAfterRegions)
        // PixelRegionSet intentionally fills/coalesces touching L-shape bounds;
        // the exact tile list must remain the hole-preserving authority.
        #expect(before.regions.rectangles.count == 1)
        #expect(!beforeCoordinates.contains(.init(x: 1, y: 1)))

        let expectedBeforeBytes = try beforePresent.reduce(into: 0) {
            $0 += try tiledRevisionRetainedBytes(
                coordinate: $1,
                size: beforePhysical,
                device: device
            )
        }
        let expectedAfterBytes = try afterPresent.reduce(into: 0) {
            $0 += try tiledRevisionRetainedBytes(
                coordinate: $1,
                size: afterPhysical,
                device: device
            )
        }
        let expectedBytes = expectedBeforeBytes + expectedAfterBytes
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: expectedBytes
        )
        let pair = try store.allocatePair(
            layerID: layerID,
            before: before,
            after: after
        )

        #expect(pair.before.generation == 7)
        #expect(pair.after.generation == 11)
        #expect(pair.before.pixelSize == beforePhysical)
        #expect(pair.after.pixelSize == afterPhysical)
        #expect(pair.before.documentPixelSize == beforeVisible)
        #expect(pair.after.documentPixelSize == afterVisible)
        #expect(pair.before.tileCoordinates
            == beforeCoordinates.map(\.revisionCoordinate))
        #expect(pair.after.tileCoordinates
            == afterCoordinates.map(\.revisionCoordinate))
        #expect(pair.before.regions == expectedBeforeRegions)
        #expect(pair.after.regions == expectedAfterRegions)
        #expect(pair.retainedBytes == expectedBytes)
        #expect(store.residentBytes == expectedBytes)
        try store.discard(pair)
        #expect(store.snapshot() == .empty(maximumRetainedBytes: expectedBytes))
    }

    @Test
    func endpointPairChecksAggregateBudgetBeforeEitherBufferAllocation() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(41)
        let size = PixelSize(width: 256, height: 256)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let endpoint = try TiledRasterRevisionEndpoint(
            generation: 4,
            pixelSize: size,
            documentPixelSize: size,
            coordinates: [coordinate],
            presentCoordinates: [coordinate]
        )
        let oneEndpointBytes = try tiledRevisionRetainedBytes(
            coordinate: coordinate,
            size: size,
            device: device
        )
        let store = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: oneEndpointBytes * 2 - 1
        )
        #expect(throws: TiledRasterRevisionStoreError.byteBudgetExceeded(
            requiredBytes: oneEndpointBytes * 2,
            availableBytes: oneEndpointBytes * 2 - 1
        )) {
            _ = try store.allocatePair(
                layerID: layerID,
                before: endpoint,
                after: endpoint,
                failureInjection: .init(failingAt: .bufferAllocation(0))
            )
        }
        #expect(store.snapshot() == .empty(
            maximumRetainedBytes: oneEndpointBytes * 2 - 1
        ))

        let emptyAfter = try TiledRasterRevisionEndpoint(
            generation: 5,
            pixelSize: PixelSize(width: 128, height: 128),
            documentPixelSize: PixelSize(width: 128, height: 128),
            coordinates: [],
            presentCoordinates: []
        )
        let oneSided = TiledRasterRevisionStore(
            device: device,
            maximumRetainedBytes: oneEndpointBytes
        )
        let pair = try oneSided.allocatePair(
            layerID: layerID,
            before: endpoint,
            after: emptyAfter
        )
        #expect(pair.after.tileCoordinates.isEmpty)
        #expect(pair.after.regions.rectangles.isEmpty)
        #expect(pair.after.retainedBytes == 0)
        try oneSided.discard(pair)
    }

    @Test
    func publishedOnlyInstallRejectsProvisionalAndOwnsPublishedLifetime() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(42)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 8,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let provisional = fixture.store.snapshot()
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try fixture.store.beginPublishedInstall(
                for: fixture.pair.after
            )
        }
        #expect(fixture.store.snapshot() == provisional)

        // Compatibility callers may still stage a capture-ready provisional
        // install, but the coordinator-only entry point above must not.
        let compatibility = try fixture.store.beginInstall(
            for: fixture.pair.after
        )
        try fixture.store.cancelInstall(
            compatibility,
            layerID: layerID,
            generation: 8
        )
        try fixture.store.publish(fixture.pair)

        let lease = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 1)
        try fixture.store.release([fixture.pair.after.id])
        #expect(fixture.store.containsRevision(fixture.pair.after.id))
        try fixture.store.cancelInstall(
            lease,
            layerID: layerID,
            generation: 8
        )
        #expect(!fixture.store.containsRevision(fixture.pair.after.id))
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)
        try fixture.store.release([fixture.pair.before.id])
        #expect(fixture.store.residentBytes == 0)
    }

    @Test
    func finalPublishFailureOccursBeforeLifetimeMutationAndCanRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(43)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 9,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        let before = fixture.store.snapshot()
        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
            .publish
        )) {
            try fixture.store.publish(
                fixture.pair,
                failureInjection: .init(failingAt: .publish)
            )
        }
        #expect(fixture.store.snapshot() == before)
        #expect(throws: TiledRasterRevisionStoreError.pairNotReady) {
            _ = try fixture.store.beginPublishedInstall(
                for: fixture.pair.after
            )
        }

        try fixture.store.publish(fixture.pair)
        #expect(fixture.store.snapshot().publishedRevisionCount == 2)
        let lease = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        try fixture.store.cancelInstall(
            lease,
            layerID: layerID,
            generation: 9
        )
        try fixture.store.release(fixture.pair.revisionIDs)
    }

    @Test
    func finalConsumeFailurePreservesReadyLeaseAndCanRetry() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(44)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 10,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [coordinate],
            afterPresentCoordinates: [coordinate]
        )
        try fixture.store.publish(fixture.pair)
        let lease = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let operation = try fixture.store.encodeInstall(
            lease,
            layerID: layerID,
            generation: 10,
            targets: [
                .init(
                    coordinate: coordinate,
                    texture: try tiledRevisionTexture(device: device)
                ),
            ],
            on: command
        )
        command.commit()
        command.waitUntilCompleted()
        try tiledRevisionRequireCompleted(command)
        try fixture.store.finalize(operation, as: .succeeded)
        let ready = fixture.store.snapshot()

        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
            .consumeInstall
        )) {
            try fixture.store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 10,
                failureInjection: .init(failingAt: .consumeInstall)
            )
        }
        #expect(fixture.store.snapshot() == ready)
        #expect(throws: TiledRasterRevisionStoreError.generationMismatch(
            expected: 10,
            actual: 11
        )) {
            try fixture.store.consumeInstall(
                lease,
                layerID: layerID,
                generation: 11,
                failureInjection: .init(failingAt: .consumeInstall)
            )
        }
        #expect(fixture.store.snapshot() == ready)

        try fixture.store.consumeInstall(
            lease,
            layerID: layerID,
            generation: 10
        )
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)
        let immediateRetry = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        try fixture.store.cancelInstall(
            immediateRetry,
            layerID: layerID,
            generation: 10
        )
        try fixture.store.release(fixture.pair.revisionIDs)
    }

    @Test
    func coordinatorAbandonDistinguishesOwnedLeaseFromPostReservationFailure() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layerID = tiledRevisionLayerID(45)
        let coordinate = PaintTileCoordinate(x: 0, y: 0)
        let fixture = try tiledRevisionCapturedPair(
            device: device,
            layerID: layerID,
            generation: 12,
            pixelSize: PixelSize(width: 256, height: 256),
            beforePresentCoordinates: [],
            afterPresentCoordinates: [coordinate]
        )
        try fixture.store.publish(fixture.pair)

        let prepared = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        #expect(try fixture.store.abandonInstallForCoordinatorIfOwned(
            prepared,
            layerID: layerID,
            generation: 12
        ) == .cancelled)
        #expect(try fixture.store.abandonInstallForCoordinatorIfOwned(
            prepared,
            layerID: layerID,
            generation: 12
        ) == .alreadyTerminal)

        let encoding = try fixture.store.beginPublishedInstall(
            for: fixture.pair.after
        )
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        #expect(throws: TiledRasterRevisionStoreError.injectedFailure(
            .commandEncoding
        )) {
            _ = try fixture.store.encodeInstall(
                encoding,
                layerID: layerID,
                generation: 12,
                targets: [
                    .init(
                        coordinate: coordinate,
                        texture: try tiledRevisionTexture(device: device)
                    ),
                ],
                on: command,
                failureInjection: .init(failingAt: .commandEncoding)
            )
        }
        #expect(try fixture.store.abandonInstallForCoordinatorIfOwned(
            encoding,
            layerID: layerID,
            generation: 12
        ) == .alreadyTerminal)
        #expect(fixture.store.snapshot().inFlightInstallLeaseCount == 0)
        try fixture.store.release(fixture.pair.revisionIDs)
    }
}

private func tiledRevisionCapturedPair(
    device: any MTLDevice,
    layerID: UUID,
    generation: UInt64,
    pixelSize: PixelSize,
    beforePresentCoordinates: [PaintTileCoordinate],
    afterPresentCoordinates: [PaintTileCoordinate]
) throws -> (
    store: TiledRasterRevisionStore,
    pair: PendingRasterRevisionPair
) {
    let coordinates = Array(Set(
        beforePresentCoordinates + afterPresentCoordinates
    )).sorted()
    precondition(!coordinates.isEmpty)
    let store = TiledRasterRevisionStore(
        device: device,
        maximumRetainedBytes:
            PaintTileDescriptor.residentByteCount * coordinates.count * 2
    )
    let pair = try store.allocatePair(
        layerID: layerID,
        generation: generation,
        pixelSize: pixelSize,
        dirtyRegions: tiledRevisionRegions(
            for: coordinates,
            size: pixelSize
        ),
        beforePresentCoordinates: beforePresentCoordinates,
        afterPresentCoordinates: afterPresentCoordinates
    )
    let texture = try tiledRevisionTexture(device: device)
    tiledRevisionUpload(tiledRevisionBytes(seed: 53), to: texture)
    let beforePresent = Set(beforePresentCoordinates)
    let afterPresent = Set(afterPresentCoordinates)
    let beforeSources: [TiledRasterRevisionTileSource] = coordinates.map {
        beforePresent.contains($0)
            ? .texture(coordinate: $0, texture: texture)
            : .knownClear(coordinate: $0)
    }
    let afterSources: [TiledRasterRevisionTileSource] = coordinates.map {
        afterPresent.contains($0)
            ? .texture(coordinate: $0, texture: texture)
            : .knownClear(coordinate: $0)
    }
    let queue = try #require(device.makeCommandQueue())
    let command = try #require(queue.makeCommandBuffer())
    let before = try store.encodeCapture(
        pair.before,
        layerID: layerID,
        generation: generation,
        sources: beforeSources,
        on: command
    )
    let after = try store.encodeCapture(
        pair.after,
        layerID: layerID,
        generation: generation,
        sources: afterSources,
        on: command
    )
    command.commit()
    command.waitUntilCompleted()
    try tiledRevisionRequireCompleted(command)
    try store.finalize(before, as: .succeeded)
    try store.finalize(after, as: .succeeded)
    return (store, pair)
}

private func tiledRevisionLayerID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "10000000-0000-0000-0000-%012d",
        value
    ))!
}

private func tiledRevisionRegions(
    for coordinates: [PaintTileCoordinate],
    size: PixelSize
) -> PixelRegionSet {
    PixelRegionSet(
        coordinates.map {
            try! PaintTileDescriptor(
                coordinate: $0,
                logicalPixelSize: size
            ).logicalBounds
        },
        clippedTo: size
    )
}

private func tiledRevisionRetainedBytes(
    coordinate: PaintTileCoordinate,
    size: PixelSize,
    device: any MTLDevice
) throws -> Int {
    let descriptor = try PaintTileDescriptor(
        coordinate: coordinate,
        logicalPixelSize: size
    )
    let alignment = device.minimumTextureBufferAlignment(for: .rgba16Float)
    let raw = descriptor.logicalBounds.width * 8
    let row = ((raw + alignment - 1) / alignment) * alignment
    return row * descriptor.logicalBounds.height
}

private func tiledRevisionTexture(
    device: any MTLDevice,
    pixelFormat: MTLPixelFormat = .rgba16Float
) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: PaintTileDescriptor.side,
        height: PaintTileDescriptor.side,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    return try #require(device.makeTexture(descriptor: descriptor))
}

private func tiledRevisionBytes(seed: UInt8) -> Data {
    Data((0..<PaintTileDescriptor.residentByteCount).map {
        UInt8(truncatingIfNeeded: $0 &* 29 &+ Int(seed))
    })
}

private func tiledRevisionUpload(
    _ bytes: Data,
    to texture: any MTLTexture
) {
    bytes.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(
                0,
                0,
                PaintTileDescriptor.side,
                PaintTileDescriptor.side
            ),
            mipmapLevel: 0,
            withBytes: $0.baseAddress!,
            bytesPerRow: PaintTileDescriptor.side * 8
        )
    }
}

private func tiledRevisionDownload(_ texture: any MTLTexture) -> Data {
    var bytes = Data(count: PaintTileDescriptor.residentByteCount)
    bytes.withUnsafeMutableBytes {
        texture.getBytes(
            $0.baseAddress!,
            bytesPerRow: PaintTileDescriptor.side * 8,
            from: MTLRegionMake2D(
                0,
                0,
                PaintTileDescriptor.side,
                PaintTileDescriptor.side
            ),
            mipmapLevel: 0
        )
    }
    return bytes
}

private func tiledRevisionClippedBytes(
    _ bytes: Data,
    width: Int,
    height: Int
) -> Data {
    var result = Data()
    result.reserveCapacity(width * height * 8)
    for y in 0..<height {
        let start = y * PaintTileDescriptor.side * 8
        result.append(bytes[start..<(start + width * 8)])
    }
    return result
}

private func tiledRevisionRequireCompleted(
    _ commandBuffer: any MTLCommandBuffer
) throws {
    #expect(commandBuffer.status == .completed)
    if let error = commandBuffer.error { throw error }
}

private extension PaintTileCoordinate {
    var revisionCoordinate: RasterRevisionTileCoordinate {
        RasterRevisionTileCoordinate(x: x, y: y)
    }
}
