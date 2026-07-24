import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("BoundedWashSurface")
struct BoundedWashSurfaceTests {
    @Test
    @MainActor
    func allocatesExactlyTwoFixedFormatCanonicalSizedTextures() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 96, height: 64)
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: size
        )

        for texture in [surface.depositTexture, surface.scratchTexture] {
            #expect(texture.pixelFormat == .rgba16Float)
            #expect(texture.width == size.width)
            #expect(texture.height == size.height)
            #expect(texture.mipmapLevelCount == 1)
            #expect(texture.storageMode == .private)
            #expect(texture.usage.contains(.renderTarget))
            #expect(texture.usage.contains(.shaderRead))
            #expect(texture.usage.contains(.shaderWrite))
        }
        #expect(surface.depositTexture.label == "Bounded Wash Deposit")
        #expect(surface.scratchTexture.label == "Bounded Wash Scratch")
        #expect(surface.workingByteCount == 96 * 64 * 8 * 2)
    }

    @Test
    @MainActor
    func validatesTwoPassAndThirtyTwoPixelHardCaps() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let dirty = PixelRect(minX: 20, minY: 20, maxX: 24, maxY: 24)!

        let maximum = try surface.makeWorkPlan(
            dirtyRegions: [dirty],
            bleedRadius: 32,
            softenPasses: 2
        )
        #expect(maximum.haloPixels == 32)
        #expect(maximum.softenPasses == 2)

        #expect(throws: BoundedWashSurfaceError.invalidBleedRadius) {
            try surface.makeWorkPlan(
                dirtyRegions: [dirty],
                bleedRadius: 32.01,
                softenPasses: 2
            )
        }
        #expect(throws: BoundedWashSurfaceError.invalidBleedRadius) {
            try surface.makeWorkPlan(
                dirtyRegions: [dirty],
                bleedRadius: .nan,
                softenPasses: 2
            )
        }
        #expect(throws: BoundedWashSurfaceError.softenPassLimitExceeded(3)) {
            try surface.makeWorkPlan(
                dirtyRegions: [dirty],
                bleedRadius: 32,
                softenPasses: 3
            )
        }
    }

    @Test
    @MainActor
    func clipsAndWrapsDirtyRegionsAcrossBothCanonicalSeams() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 100, height: 80)
        let surface = try BoundedWashSurface(device: device, pixelSize: size)
        let crossing = PixelRect(
            minX: -5,
            minY: 70,
            maxX: 10,
            maxY: 90
        )!

        let plan = try surface.makeWorkPlan(
            dirtyRegions: [crossing],
            bleedRadius: 0,
            softenPasses: 0
        )

        #expect(plan.depositionRegions.rectangles == [
            PixelRect(minX: 0, minY: 0, maxX: 10, maxY: 10)!,
            PixelRect(minX: 95, minY: 0, maxX: 100, maxY: 10)!,
            PixelRect(minX: 0, minY: 70, maxX: 10, maxY: 80)!,
            PixelRect(minX: 95, minY: 70, maxX: 100, maxY: 80)!,
        ])
        #expect(plan.processingRegions == plan.depositionRegions)
    }

    @Test
    @MainActor
    func haloWrapsAndClampsToFullAxisWhenItSpansCanonicalExtent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 40, height: 100)
        let surface = try BoundedWashSurface(device: device, pixelSize: size)
        let dirty = PixelRect(minX: 10, minY: 2, maxX: 20, maxY: 8)!

        let plan = try surface.makeWorkPlan(
            dirtyRegions: [dirty],
            bleedRadius: 16,
            softenPasses: 1
        )

        #expect(plan.processingRegions.rectangles == [
            PixelRect(minX: 0, minY: 0, maxX: 40, maxY: 24)!,
            PixelRect(minX: 0, minY: 86, maxX: 40, maxY: 100)!,
        ])
    }

    @Test
    @MainActor
    func finiteCanvasClipsWashInsteadOfWrappingOppositeEdges() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 100, height: 80)
        let surface = try BoundedWashSurface(device: device, pixelSize: size)
        let crossing = PixelRect(
            minX: -5,
            minY: 70,
            maxX: 10,
            maxY: 90
        )!

        let plan = try surface.makeWorkPlan(
            dirtyRegions: [
                BoundedWashDirtyRegion(rectangle: crossing),
            ],
            topology: .finite,
            bleedRadius: 4,
            softenPasses: 1
        )

        #expect(plan.depositionRegions.rectangles == [
            PixelRect(minX: 0, minY: 70, maxX: 10, maxY: 80)!,
        ])
        #expect(plan.processingRegions.rectangles == [
            PixelRect(minX: 0, minY: 66, maxX: 14, maxY: 80)!,
        ])
    }

    @Test
    @MainActor
    func radialHaloCrossesLogicalPagesNotAdjacentAtlasSlots() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 700,
            sectorAngleRadians: .pi / 4
        )
        let sourceCoordinate = RadialPageCoordinate(x: 1, y: 0)
        let targetCoordinate = RadialPageCoordinate(x: 1, y: 1)
        let source = try #require(
            layout.residentPage(at: sourceCoordinate)
        )
        let target = try #require(
            layout.residentPage(at: targetCoordinate)
        )
        let side = RadialSectorLayout.pageSide
        let sourceAtlasX = source.atlasSlot % layout.atlasColumns * side
        let sourceAtlasY = source.atlasSlot / layout.atlasColumns * side
        let targetAtlasX = target.atlasSlot % layout.atlasColumns * side
        let targetAtlasY = target.atlasSlot / layout.atlasColumns * side
        #expect(targetAtlasX != sourceAtlasX)

        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: layout.atlasPixelSize
        )
        let plan = try surface.makeWorkPlan(
            dirtyRegions: [
                BoundedWashDirtyRegion(
                    rectangle: PixelRect(
                        minX: sourceAtlasX + 100,
                        minY: sourceAtlasY + 252,
                        maxX: sourceAtlasX + 104,
                        maxY: sourceAtlasY + 256
                    )!,
                    radialPage: sourceCoordinate
                ),
            ],
            topology: .radial(layout),
            bleedRadius: 8,
            softenPasses: 1
        )

        func contains(_ x: Int, _ y: Int) -> Bool {
            plan.processingRegions.rectangles.contains {
                x >= $0.minX && x < $0.maxX
                    && y >= $0.minY && y < $0.maxY
            }
        }
        #expect(contains(targetAtlasX + 101, targetAtlasY + 2))
        #expect(!contains(sourceAtlasX + 101, sourceAtlasY + side + 2))
    }

    @Test
    @MainActor
    func radialPlanningRejectsMissingPageIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let layout = try RadialSectorLayout(
            maximumRadius: 512,
            sectorAngleRadians: .pi / 2
        )
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: layout.atlasPixelSize
        )

        #expect(throws: BoundedWashSurfaceError.radialPageMetadataMissing) {
            try surface.makeWorkPlan(
                dirtyRegions: [
                    BoundedWashDirtyRegion(
                        rectangle: PixelRect(
                            minX: 10,
                            minY: 10,
                            maxX: 20,
                            maxY: 20
                        )!
                    ),
                ],
                topology: .radial(layout),
                bleedRadius: 4,
                softenPasses: 1
            )
        }
    }

    @Test
    @MainActor
    func workPlanningReusesTheSameResources() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: PixelSize(width: 64, height: 64)
        )
        let depositIdentity = ObjectIdentifier(
            surface.depositTexture as AnyObject
        )
        let scratchIdentity = ObjectIdentifier(
            surface.scratchTexture as AnyObject
        )

        for offset in 0..<1_000 {
            _ = try surface.makeWorkPlan(
                dirtyRegions: [
                    PixelRect(
                        minX: offset,
                        minY: offset,
                        maxX: offset + 2,
                        maxY: offset + 2
                    )!,
                ],
                bleedRadius: 8,
                softenPasses: 2
            )
        }

        #expect(ObjectIdentifier(surface.depositTexture as AnyObject)
            == depositIdentity)
        #expect(ObjectIdentifier(surface.scratchTexture as AnyObject)
            == scratchIdentity)
    }

    @Test
    @MainActor
    func allocationFailureCanBeInjectedAtEitherResource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 32, height: 32)

        #expect(throws: BoundedWashSurfaceError.textureAllocationFailed(
            .deposit
        )) {
            try BoundedWashSurface(
                device: device,
                pixelSize: size,
                injectedAllocationFailure: .deposit
            )
        }
        #expect(throws: BoundedWashSurfaceError.textureAllocationFailed(
            .scratch
        )) {
            try BoundedWashSurface(
                device: device,
                pixelSize: size,
                injectedAllocationFailure: .scratch
            )
        }
    }

    @Test
    @MainActor
    func processedPixelsDependOnMergedDirtyAreaAndHaloOnly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: PixelSize(width: 512, height: 512)
        )
        let newlyDirty = PixelRect(
            minX: 100,
            minY: 120,
            maxX: 110,
            maxY: 130
        )!

        let one = try surface.makeWorkPlan(
            dirtyRegions: [newlyDirty],
            bleedRadius: 4,
            softenPasses: 2
        )
        let duplicatesRepresentingLongSettledHistory = try surface.makeWorkPlan(
            dirtyRegions: Array(repeating: newlyDirty, count: 10_000),
            bleedRadius: 4,
            softenPasses: 2
        )

        #expect(one.depositionPixelCount == 100)
        #expect(one.localPassPixelCount == 18 * 18 * 2)
        #expect(one.resolvePixelCount == 18 * 18)
        #expect(one.processedPixelCount == 1_072)
        #expect(duplicatesRepresentingLongSettledHistory.processedPixelCount
            == one.processedPixelCount)
    }

    @Test
    @MainActor
    func emptyUpdateHasZeroWorkButKeepsResourcesAlive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let surface = try BoundedWashSurface(
            device: device,
            pixelSize: PixelSize(width: 32, height: 32)
        )

        let plan = try surface.makeWorkPlan(
            dirtyRegions: [],
            bleedRadius: 32,
            softenPasses: 2
        )

        #expect(plan.depositionRegions.rectangles.isEmpty)
        #expect(plan.processingRegions.rectangles.isEmpty)
        #expect(plan.processedPixelCount == 0)
        #expect(surface.workingByteCount == 32 * 32 * 8 * 2)
    }

    @Test
    @MainActor
    func excessiveRegionMetadataDegradesDeterministicallyToFullTile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let size = PixelSize(width: 128, height: 128)
        let surface = try BoundedWashSurface(device: device, pixelSize: size)
        let dirty = (0...BoundedWashSurface.maximumProcessingRegionCount).map {
            index in
            let x = (index % 33) * 3
            let y = (index / 33) * 3
            return PixelRect(
                minX: x,
                minY: y,
                maxX: x + 1,
                maxY: y + 1
            )!
        }

        let plan = try surface.makeWorkPlan(
            dirtyRegions: dirty,
            bleedRadius: 0,
            softenPasses: 2
        )

        let fullTile = PixelRect(
            minX: 0,
            minY: 0,
            maxX: size.width,
            maxY: size.height
        )!
        #expect(plan.usedFullTileRegionDegradation)
        #expect(plan.depositionRegions.rectangles == [fullTile])
        #expect(plan.processingRegions.rectangles == [fullTile])
        let metadata = try surface.prepareProcessingRegions(
            plan.processingRegions,
            slot: 0
        )
        #expect(metadata.count == 1)
    }

    @Test
    func historyAccumulatorUnionsHalosAndFallsBackAtMetadataCap() throws {
        let size = PixelSize(width: 1_024, height: 64)
        var accumulator = BoundedWashHistoryAccumulator()
        let first = PixelRect(minX: 1, minY: 1, maxX: 4, maxY: 4)!
        let second = PixelRect(minX: 20, minY: 20, maxX: 24, maxY: 24)!
        accumulator.record(
            PixelRegionSet([first], clippedTo: size),
            pixelSize: size
        )
        accumulator.record(
            PixelRegionSet([second], clippedTo: size),
            pixelSize: size
        )
        #expect(accumulator.regions(pixelSize: size).rectangles == [
            first,
            second,
        ])

        let disjoint = (0...BoundedWashHistoryAccumulator
            .maximumRetainedRectangleCount).map { index in
                PixelRect(
                    minX: index * 3,
                    minY: 40,
                    maxX: index * 3 + 1,
                    maxY: 41
                )!
            }
        accumulator.record(
            PixelRegionSet(disjoint, clippedTo: size),
            pixelSize: size
        )
        #expect(accumulator.usesFullTile)
        #expect(accumulator.regions(pixelSize: size).rectangles == [
            PixelRect(minX: 0, minY: 0, maxX: 1_024, maxY: 64)!,
        ])
    }
}
