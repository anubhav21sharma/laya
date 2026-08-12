import Foundation
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Compiled brush masks")
struct BrushMaskCacheTests {
    @Test
    func cacheKeyQuantizesEverySemanticInputDeterministically() throws {
        let first = try BrushMaskCacheKey(
            semanticTipHash: "tip-a",
            size: 12.0001,
            aspect: 0.50001,
            rotation: -.pi / 2,
            hardness: 0.75001,
            subpixelPhase: SIMD2(0.249, 0.751),
            precision: .r8Unorm
        )
        let equivalent = try BrushMaskCacheKey(
            semanticTipHash: "tip-a",
            size: 12.0002,
            aspect: 0.50002,
            rotation: 3 * .pi / 2,
            hardness: 0.75002,
            subpixelPhase: SIMD2(0.251, 0.749),
            precision: .r8Unorm
        )
        let differentPrecision = try BrushMaskCacheKey(
            semanticTipHash: "tip-a",
            size: 12.0001,
            aspect: 0.50001,
            rotation: -.pi / 2,
            hardness: 0.75001,
            subpixelPhase: SIMD2(0.249, 0.751),
            precision: .r16Unorm
        )

        #expect(first == equivalent)
        #expect(first != differentPrecision)
        #expect(first.stableIdentity == equivalent.stableIdentity)
    }

    @Test
    func cacheReportsHitsMissesAndStableLRUEviction() throws {
        var cache = BrushMaskCache<Int>(byteBudget: 20)
        let a = try key("a")
        let b = try key("b")
        let c = try key("c")
        var creationCount = 0

        #expect(try cache.resolve(a, byteCount: 10) {
            creationCount += 1
            return 1
        } == 1)
        #expect(try cache.resolve(b, byteCount: 10) {
            creationCount += 1
            return 2
        } == 2)
        #expect(try cache.resolve(a, byteCount: 10) {
            creationCount += 1
            return 9
        } == 1)
        #expect(try cache.resolve(c, byteCount: 10) {
            creationCount += 1
            return 3
        } == 3)

        #expect(creationCount == 3)
        #expect(cache.keys == [a, c])
        #expect(cache.metrics == BrushMaskCacheMetrics(
            hitCount: 1,
            missCount: 3,
            evictionCount: 1
        ))
        #expect(cache.residentByteCount == 20)
    }

    @Test
    func projectedFootprintSelectsBoundedMipLODAndPreservesHighZoomEdges()
        throws
    {
        #expect(
            try BrushTipMipSelector.levelOfDetail(
                sourceWidth: 256,
                sourceHeight: 128,
                projectedWidth: 256,
                projectedHeight: 128,
                mipLevelCount: 9
            ) == 0
        )
        #expect(
            try BrushTipMipSelector.levelOfDetail(
                sourceWidth: 256,
                sourceHeight: 128,
                projectedWidth: 64,
                projectedHeight: 32,
                mipLevelCount: 9
            ) == 2
        )
        #expect(
            try BrushTipMipSelector.levelOfDetail(
                sourceWidth: 256,
                sourceHeight: 128,
                projectedWidth: 4_096,
                projectedHeight: 2_048,
                mipLevelCount: 9
            ) == 0
        )
        #expect(
            try BrushTipMipSelector.levelOfDetail(
                sourceWidth: 256,
                sourceHeight: 128,
                projectedWidth: 0.125,
                projectedHeight: 0.0625,
                mipLevelCount: 9
            ) == 8
        )
    }

    @Test
    func alphaSupportCompilesExactBoundsStableContourAndNoUniversalPadding()
        throws
    {
        let support = try BrushTipAssetSupportCompiler.compile(
            baseLevel: Data([
                0, 0, 0, 0,
                0, 9, 7, 0,
                0, 5, 3, 0,
                0, 0, 0, 0,
            ]),
            width: 4,
            height: 4
        )

        #expect(support.bounds.minX == -0.5)
        #expect(support.bounds.maxX == 0.5)
        #expect(support.bounds.minY == -0.5)
        #expect(support.bounds.maxY == 0.5)
        #expect(support.contour == [
            SIMD2(-0.5, -0.5),
            SIMD2(0.5, -0.5),
            SIMD2(0.5, 0.5),
            SIMD2(-0.5, 0.5),
        ])
        #expect(support.padding == .zero)
    }

    @Test
    func boundedAssetContourStillContainsEveryNonzeroSupportEdge() throws {
        let dimension = 512
        let center = Float(dimension) / 2
        let radius = Float(dimension) * 0.46
        var bytes = [UInt8](
            repeating: 0,
            count: dimension * dimension
        )
        var supportEdges: [SIMD2<Float>] = []

        for y in 0..<dimension {
            let dy = Float(y) + 0.5 - center
            let squaredSpan = radius * radius - dy * dy
            guard squaredSpan > 0 else { continue }
            let halfSpan = sqrt(squaredSpan)
            let minimumX = max(
                0,
                Int(ceil(center - halfSpan - 0.5))
            )
            let maximumX = min(
                dimension - 1,
                Int(floor(center + halfSpan - 0.5))
            )
            for x in minimumX...maximumX {
                bytes[y * dimension + x] = 255
            }
            supportEdges.append(contentsOf: [
                normalizedEdge(minimumX, dimension: dimension, y: y),
                normalizedEdge(maximumX + 1, dimension: dimension, y: y),
                normalizedEdge(
                    maximumX + 1,
                    dimension: dimension,
                    y: y + 1
                ),
                normalizedEdge(minimumX, dimension: dimension, y: y + 1),
            ])
        }

        let support = try BrushTipAssetSupportCompiler.compile(
            baseLevel: Data(bytes),
            width: dimension,
            height: dimension
        )

        #expect(support.contour.count <= 128)
        #expect(supportEdges.allSatisfy {
            contour(support.contour, contains: $0)
        })
    }

    @Test
    func emptyOrMalformedAlphaSupportFailsTypedAndDoesNotInventPadding() {
        #expect(throws: BrushTipAssetSupportCompilationError.emptySupport) {
            try BrushTipAssetSupportCompiler.compile(
                baseLevel: Data(repeating: 0, count: 4),
                width: 2,
                height: 2
            )
        }
        #expect(
            throws: BrushTipAssetSupportCompilationError.byteCountMismatch(
                expected: 4,
                actual: 3
            )
        ) {
            try BrushTipAssetSupportCompiler.compile(
                baseLevel: Data(repeating: 255, count: 3),
                width: 2,
                height: 2
            )
        }
    }

    private func key(_ identity: String) throws -> BrushMaskCacheKey {
        try BrushMaskCacheKey(
            semanticTipHash: identity,
            size: 10,
            aspect: 1,
            rotation: 0,
            hardness: 1,
            subpixelPhase: .zero,
            precision: .r8Unorm
        )
    }

    private func normalizedEdge(
        _ x: Int,
        dimension: Int,
        y: Int
    ) -> SIMD2<Float> {
        SIMD2(
            Float(x) / Float(dimension) * 2 - 1,
            Float(y) / Float(dimension) * 2 - 1
        )
    }

    private func contour(
        _ contour: [SIMD2<Float>],
        contains point: SIMD2<Float>
    ) -> Bool {
        guard contour.count >= 3 else { return false }
        for index in contour.indices {
            let next = contour.index(after: index) == contour.endIndex
                ? contour.startIndex
                : contour.index(after: index)
            let edge = contour[next] - contour[index]
            let offset = point - contour[index]
            let cross = edge.x * offset.y - edge.y * offset.x
            if cross < -1e-5 {
                return false
            }
        }
        return true
    }
}
