import Foundation
import PatternEngine
import simd
import Testing

@Suite("Portable brush tip support")
struct BrushTipSupportTests {
    @Test("ellipse support follows its transformed axes")
    func ellipseSupportFollowsTransformedAxes() throws {
        let layer = try BrushTipSupportLayer(
            definition: .analyticEllipse,
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 1),
            offset: .zero
        )

        let horizontal = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(1, 0)
        )
        let diagonal = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(
                Float(1 / sqrt(2.0)),
                Float(1 / sqrt(2.0))
            )
        )
        let vertical = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(0, 1)
        )

        expectClose(horizontal.minimumProjection, -2)
        expectClose(horizontal.maximumProjection, 2)
        expectClose(horizontal.width, 4)
        expectClose(diagonal.width, Float(sqrt(10.0)))
        expectClose(vertical.width, 2)
    }

    @Test("rectangle support uses the transformed corner extrema")
    func rectangleSupportUsesTransformedCornerExtrema() throws {
        let layer = try BrushTipSupportLayer(
            definition: .analyticRectangle,
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 1),
            offset: .zero
        )
        let diagonalComponent = Float(1 / sqrt(2.0))

        let horizontal = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(1, 0)
        )
        let diagonal = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(repeating: diagonalComponent)
        )
        let vertical = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(0, 1)
        )

        expectClose(horizontal.width, 4)
        expectClose(diagonal.width, 3 * Float(sqrt(2.0)))
        expectClose(vertical.width, 2)
    }

    @Test("translated asymmetric bounds preserve their directional interval")
    func translatedAsymmetricBoundsPreserveDirectionalInterval() throws {
        let bounds = try BrushTipSupportDefinition.normalizedBounds(
            minX: -0.25,
            maxX: 0.75,
            minY: -1,
            maxY: 0.5
        )
        let layer = try BrushTipSupportLayer(
            definition: bounds,
            xAxis: SIMD2(3, 1),
            yAxis: SIMD2(-1, 2),
            offset: SIMD2(4, -2)
        )
        let diagonalComponent = Float(1 / sqrt(2.0))

        let interval = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(repeating: diagonalComponent)
        )

        expectClose(interval.minimumProjection, 0)
        expectClose(
            interval.maximumProjection,
            5.5 * diagonalComponent
        )
        expectClose(interval.width, 5.5 * diagonalComponent)
    }

    @Test("offset shape layers union their actual extrema")
    func offsetShapeLayersUnionTheirActualExtrema() throws {
        let ellipse = try BrushTipSupportLayer(
            definition: .analyticEllipse,
            xAxis: SIMD2(2, 0),
            yAxis: SIMD2(0, 1),
            offset: SIMD2(-3, 1)
        )
        let rectangle = try BrushTipSupportLayer(
            definition: .analyticRectangle,
            xAxis: SIMD2(0.5, 0),
            yAxis: SIMD2(0, 1),
            offset: SIMD2(4, -2)
        )

        let interval = try BrushTipSupport.projectionInterval(
            layers: [ellipse, rectangle],
            tangent: SIMD2(1, 0)
        )

        expectClose(interval.minimumProjection, -5)
        expectClose(interval.maximumProjection, 4.5)
        expectClose(interval.width, 9.5)
    }

    @Test("complete affine frame carries size aspect and rotation")
    func completeAffineFrameCarriesSizeAspectAndRotation() throws {
        let diagonalComponent = Float(1 / sqrt(2.0))
        let layer = try BrushTipSupportLayer(
            definition: .analyticEllipse,
            xAxis: SIMD2(
                3 * diagonalComponent,
                3 * diagonalComponent
            ),
            yAxis: SIMD2(-diagonalComponent, diagonalComponent),
            offset: SIMD2(2, -1)
        )

        let horizontal = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(1, 0)
        )
        let alongMajorAxis = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(repeating: diagonalComponent)
        )

        expectClose(horizontal.minimumProjection, 2 - Float(sqrt(5.0)))
        expectClose(horizontal.maximumProjection, 2 + Float(sqrt(5.0)))
        expectClose(horizontal.width, 2 * Float(sqrt(5.0)))
        expectClose(alongMajorAxis.width, 6)
    }

    @Test("turn and reversal use only the current world tangent")
    func turnAndReversalUseOnlyCurrentWorldTangent() throws {
        let layer = try BrushTipSupportLayer(
            definition: .analyticRectangle,
            xAxis: SIMD2(3, 0),
            yAxis: SIMD2(0, 0.5),
            offset: SIMD2(2, -4)
        )

        let forward = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(1, 0)
        )
        let turned = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(0, 1)
        )
        let reversed = try BrushTipSupport.projectionInterval(
            layers: [layer],
            tangent: SIMD2(-1, 0)
        )

        expectClose(forward.minimumProjection, -1)
        expectClose(forward.maximumProjection, 5)
        expectClose(turned.width, 1)
        expectClose(reversed.minimumProjection, -5)
        expectClose(reversed.maximumProjection, 1)
        expectClose(reversed.width, forward.width)
    }

    @Test("normalized bounds reject every malformed boundary")
    func normalizedBoundsRejectMalformedBoundaries() {
        let nonfiniteCases: [(Float, Float, Float, Float)] = [
            (.nan, 1, -1, 1),
            (-1, .infinity, -1, 1),
            (-1, 1, -.infinity, 1),
            (-1, 1, -1, .nan),
        ]
        for (minX, maxX, minY, maxY) in nonfiniteCases {
            #expect(throws: BrushTipSupportError.nonfiniteBounds) {
                try BrushTipSupportDefinition.normalizedBounds(
                    minX: minX,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY
                )
            }
        }
        #expect(throws: BrushTipSupportError.unorderedBounds) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: 0.5,
                maxX: -0.5,
                minY: -1,
                maxY: 1
            )
        }
        #expect(throws: BrushTipSupportError.unorderedBounds) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1,
                minY: 0.5,
                maxY: -0.5
            )
        }
        #expect(throws: BrushTipSupportError.emptyBounds) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: 0,
                maxX: 0,
                minY: -1,
                maxY: 1
            )
        }
        #expect(throws: BrushTipSupportError.emptyBounds) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1,
                minY: 0,
                maxY: 0
            )
        }
        #expect(throws: BrushTipSupportError.boundsOutOfRange) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1.001,
                maxX: 1,
                minY: -1,
                maxY: 1
            )
        }
        #expect(throws: BrushTipSupportError.boundsOutOfRange) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1.001,
                minY: -1,
                maxY: 1
            )
        }
        #expect(throws: BrushTipSupportError.boundsOutOfRange) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1,
                minY: -1.001,
                maxY: 1
            )
        }
        #expect(throws: BrushTipSupportError.boundsOutOfRange) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1,
                minY: -1,
                maxY: 1.001
            )
        }

        #expect(throws: Never.self) {
            try BrushTipSupportDefinition.normalizedBounds(
                minX: -1,
                maxX: 1,
                minY: -1,
                maxY: 1
            )
        }
    }

    @Test("layer and tangent boundaries fail with typed errors")
    func layerAndTangentBoundariesFailWithTypedErrors() throws {
        #expect(throws: BrushTipSupportError.nonfiniteLayerTransform) {
            try BrushTipSupportLayer(
                definition: .analyticEllipse,
                xAxis: SIMD2<Float>(.nan, 0),
                yAxis: SIMD2(0, 1),
                offset: .zero
            )
        }
        #expect(throws: BrushTipSupportError.nonfiniteLayerTransform) {
            try BrushTipSupportLayer(
                definition: .analyticEllipse,
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2(0, 1),
                offset: SIMD2<Float>(0, .infinity)
            )
        }
        #expect(throws: BrushTipSupportError.nonfiniteLayerTransform) {
            try BrushTipSupportLayer(
                definition: .analyticEllipse,
                xAxis: SIMD2<Float>(1, .infinity),
                yAxis: SIMD2(0, 1),
                offset: .zero
            )
        }
        #expect(throws: BrushTipSupportError.nonfiniteLayerTransform) {
            try BrushTipSupportLayer(
                definition: .analyticEllipse,
                xAxis: SIMD2(1, 0),
                yAxis: SIMD2<Float>(.nan, 1),
                offset: .zero
            )
        }

        let layer = try BrushTipSupportLayer(
            definition: .analyticEllipse,
            xAxis: SIMD2(1, 0),
            yAxis: SIMD2(0, 1),
            offset: .zero
        )
        #expect(throws: BrushTipSupportError.emptyLayers) {
            try BrushTipSupport.projectionInterval(
                layers: [BrushTipSupportLayer](),
                tangent: SIMD2(1, 0)
            )
        }
        #expect(throws: BrushTipSupportError.nonfiniteTangent) {
            try BrushTipSupport.projectionInterval(
                layers: [layer],
                tangent: SIMD2<Float>(.nan, 0)
            )
        }
        #expect(throws: BrushTipSupportError.nonfiniteTangent) {
            try BrushTipSupport.projectionInterval(
                layers: [layer],
                tangent: SIMD2<Float>(0, .infinity)
            )
        }
        #expect(throws: BrushTipSupportError.nonunitTangent) {
            try BrushTipSupport.projectionInterval(
                layers: [layer],
                tangent: .zero
            )
        }
        #expect(throws: BrushTipSupportError.nonunitTangent) {
            try BrushTipSupport.projectionInterval(
                layers: [layer],
                tangent: SIMD2(2, 0)
            )
        }
    }

    @Test("degenerate and overflowing support fail without a partial interval")
    func degenerateAndOverflowingSupportFailAtomically() throws {
        let degenerate = try BrushTipSupportLayer(
            definition: .analyticEllipse,
            xAxis: .zero,
            yAxis: .zero,
            offset: .zero
        )
        #expect(throws: BrushTipSupportError.invalidSupportWidth) {
            try BrushTipSupport.projectionInterval(
                layers: [degenerate],
                tangent: SIMD2(1, 0)
            )
        }

        let huge = try BrushTipSupportLayer(
            definition: .analyticRectangle,
            xAxis: SIMD2<Float>(.greatestFiniteMagnitude, 0),
            yAxis: SIMD2<Float>(.greatestFiniteMagnitude, 0),
            offset: .zero
        )
        #expect(throws: BrushTipSupportError.arithmeticOverflow) {
            try BrushTipSupport.projectionInterval(
                layers: [huge],
                tangent: SIMD2(1, 0)
            )
        }
    }
}

private func expectClose(
    _ actual: Float,
    _ expected: Float,
    tolerance: Float = 0.000_01,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        abs(actual - expected) <= tolerance,
        "Expected \(actual) to be within \(tolerance) of \(expected)",
        sourceLocation: sourceLocation
    )
}
