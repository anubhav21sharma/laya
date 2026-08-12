import Foundation
import Testing
@testable import PatternEngine

@Suite("Brush cursor descriptor")
struct BrushCursorDescriptorTests {
    @Test
    func inputInitializerRejectsInvalidGeometryBeforeEvaluation() {
        #expect(throws: BrushCursorDescriptorError.invalidInput) {
            _ = try BrushCursorInput(
                nominalDiameter: 0,
                pressure: nil,
                altitude: nil,
                azimuth: nil,
                roll: nil,
                tangentialPressure: nil,
                direction: 0,
                deformation: .identity,
                viewportScale: 1,
                backingScale: 1
            )
        }
        #expect(throws: BrushCursorDescriptorError.invalidInput) {
            _ = try BrushCursorInput(
                nominalDiameter: 10,
                pressure: nil,
                altitude: nil,
                azimuth: nil,
                roll: nil,
                tangentialPressure: nil,
                direction: 0,
                deformation: .identity,
                viewportScale: .infinity,
                backingScale: 1
            )
        }
    }

    @Test
    func analyticRoundUsesEvaluatedDiameterZoomAndBackingScale() throws {
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: nativeTestProgram(),
            profile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(
                nominalDiameter: 40,
                viewportScale: 3,
                backingScale: 2
            )
        )

        #expect(descriptor.isCircle)
        #expect(close(descriptor.coreBounds.width, 60))
        #expect(close(descriptor.coreBounds.height, 60))
        #expect(descriptor.containsCore(SIMD2(29, 0)))
        #expect(!descriptor.containsCore(SIMD2(31, 0)))
    }

    @Test
    func aspectAndChiselSupportProduceTruthfulBroadBounds() throws {
        let ellipse = try descriptor(
            shape: .hardRound,
            profileShape: .analyticEllipse,
            aspect: 0.25,
            diameter: 40
        )
        let chisel = try descriptor(
            shape: .chisel,
            profileShape: .analyticRectangle,
            aspect: 0.25,
            diameter: 40
        )

        #expect(close(ellipse.coreBounds.width, 40))
        #expect(close(ellipse.coreBounds.height, 10))
        #expect(close(chisel.coreBounds.width, 40))
        #expect(close(chisel.coreBounds.height, 10))
        #expect(ellipse.containsCore(SIMD2(0, 4.9)))
        #expect(!ellipse.containsCore(SIMD2(19, 4.9)))
        #expect(chisel.containsCore(SIMD2(19, 4.9)))
    }

    @Test
    func brushRotationAndReflectionComposeAfterTipEvaluation() throws {
        let base = nativeTestDefinition()
        let placement = BrushPlacementDefinition(
            baseSpacingFraction: base.components[0].placement.baseSpacingFraction,
            maximumSpacingFraction: base.components[0].placement.maximumSpacingFraction,
            baseFlow: base.components[0].placement.baseFlow,
            strokeOpacity: base.components[0].placement.strokeOpacity,
            baseScatterFraction: 0,
            baseRotation: .pi / 2,
            baseJitterFraction: 0,
            baseOffset: .zero
        )
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: nativeTestProgram(nativeTestDefinition(
                coverage: coverage(shape: .chisel, aspect: 0.25),
                placement: placement
            )),
            profile: BrushCursorTipProfile(primary: .analyticRectangle),
            input: cursorInput(
                nominalDiameter: 40,
                deformation: Affine2D(
                    xAxis: SIMD2(-1, 0),
                    yAxis: SIMD2(0, 1),
                    translation: .zero
                )
            )
        )

        #expect(close(descriptor.coreBounds.width, 10, tolerance: 0.001))
        #expect(close(descriptor.coreBounds.height, 40, tolerance: 0.001))
        #expect(
            descriptor.primaryComponent.primary
                .normalizedTipToLogicalDeterminant < 0
        )
        #expect(descriptor.containsCore(SIMD2(4.9, 19)))
        #expect(!descriptor.containsCore(SIMD2(5.1, 19)))
    }

    @Test
    func authoredLayerRotationTransformsSupportIndependently() throws {
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: nativeTestProgram(nativeTestDefinition(
                coverage: coverage(
                    shape: .chisel,
                    aspect: 0.25,
                    rotation: .pi / 4
                )
            )),
            profile: BrushCursorTipProfile(primary: .analyticRectangle),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(close(
            descriptor.coreBounds.width,
            40 * sqrt(2),
            tolerance: 0.001
        ))
        #expect(close(
            descriptor.coreBounds.height,
            10 * sqrt(2),
            tolerance: 0.001
        ))
        #expect(descriptor.containsCore(SIMD2(27, 0)))
        #expect(!descriptor.containsCore(SIMD2(29, 0)))
    }

    @Test
    func missingPressureUsesCompiledTermsDeclaredNeutral() throws {
        let size = nativeTestMapping(
            input: .pressure,
            output: 0.25...1,
            missingInputValue: 0.5
        )
        let program = nativeTestProgram(nativeTestDefinition(
            dynamics: nativeTestDynamics(size: size)
        ))
        let missing = try BrushCursorDescriptor.evaluate(
            program: program,
            profile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(nominalDiameter: 40)
        )
        let measured = try BrushCursorDescriptor.evaluate(
            program: program,
            profile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(nominalDiameter: 40, pressure: 0.2)
        )

        #expect(close(missing.coreBounds.width, 25))
        #expect(close(measured.coreBounds.width, 16))
    }

    @Test
    func tiltAndAzimuthDriveTheExistingCompiledSensorProgram() throws {
        let rotation = nativeTestMapping(
            input: .azimuth,
            output: 0...(.pi / 2),
            response: cyclicCursorResponse(),
            missingInputValue: 0
        )
        let size = nativeTestMapping(
            input: .tilt,
            output: 0.5...1,
            missingInputValue: 0
        )
        let program = nativeTestProgram(nativeTestDefinition(
            coverage: coverage(shape: .chisel, aspect: 0.25),
            dynamics: nativeTestDynamics(size: size, rotation: rotation)
        ))
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: program,
            profile: BrushCursorTipProfile(primary: .analyticRectangle),
            input: cursorInput(
                nominalDiameter: 40,
                altitude: 0,
                azimuth: .pi / 2
            )
        )

        #expect((9.5...10.5).contains(descriptor.coreBounds.width))
        #expect((39.5...40.5).contains(descriptor.coreBounds.height))
    }

    @Test
    func assetContourStaysCachedAndTransformsWithoutRemeshing() throws {
        let contour: [SIMD2<Float>] = [
            SIMD2(-1, -1),
            SIMD2(1, -1),
            SIMD2(0, 1),
        ]
        let program = nativeTestProgram(nativeTestDefinition(
            coverage: coverage(
                shape: .asset("builtin.shape.graphite-tip"),
                aspect: 0.5
            )
        ))
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: program,
            profile: BrushCursorTipProfile(primary: .contour(contour)),
            input: cursorInput(nominalDiameter: 40)
        )

        guard case let .contour(retained) = descriptor.primaryComponent
            .primary.shape
        else {
            Issue.record("asset cursor lost its cached contour")
            return
        }
        #expect(retained == contour)
        #expect(close(descriptor.coreBounds.width, 40))
        #expect(close(descriptor.coreBounds.height, 20))
        #expect(descriptor.containsCore(SIMD2(0, 9)))
        #expect(!descriptor.containsCore(SIMD2(19, 9)))
    }

    @Test
    func dualShapeOccupancyMatchesTheDeclaredCombination() throws {
        let coverage = BrushCoverageDefinition(
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .hardRound,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
                BrushShapeLayerDefinition(
                    shape: .chisel,
                    combination: .multiply,
                    scale: 0.5,
                    rotation: 0,
                    offset: .zero
                ),
            ],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0,
            antialiasing: true
        )
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: nativeTestProgram(nativeTestDefinition(coverage: coverage)),
            profile: BrushCursorTipProfile(
                primary: .analyticEllipse,
                secondary: .analyticRectangle,
                secondaryCombination: .multiply
            ),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(descriptor.containsCore(SIMD2(9, 9)))
        #expect(!descriptor.containsCore(SIMD2(11, 0)))
        #expect(!descriptor.containsCore(SIMD2(0, 11)))
        #expect(close(descriptor.coreBounds.width, 20))
        #expect(close(descriptor.coreBounds.height, 20))
    }

    @Test
    func scatterAndPlacementJitterExpandOnlyTheStableEnvelope() throws {
        let placement = BrushPlacementDefinition(
            baseSpacingFraction: 0.1,
            maximumSpacingFraction: 0.2,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0.1,
            baseRotation: 0,
            baseJitterFraction: 0.05,
            baseOffset: .zero
        )
        let randomization = BrushRandomization(
            spacing: 0,
            scatter: 1,
            rotation: 0,
            grain: 0,
            material: 0
        )
        let program = nativeTestProgram(nativeTestDefinition(
            placement: placement,
            dynamics: nativeTestDynamics(randomization: randomization)
        ))
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: program,
            profile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(close(descriptor.coreBounds.minimum.x, -20))
        #expect(close(descriptor.coreBounds.maximum.x, 20))
        #expect(close(descriptor.envelopeBounds.minimum.x, -26))
        #expect(close(descriptor.envelopeBounds.maximum.x, 26))
        #expect(close(descriptor.envelopeBounds.height, 52))
    }

    @Test
    func randomizedScatterUsesItsCompiledConservativeUpperBound() throws {
        let placement = BrushPlacementDefinition(
            baseSpacingFraction: 0.1,
            maximumSpacingFraction: 0.2,
            baseFlow: 1,
            strokeOpacity: 1,
            baseScatterFraction: 0.1,
            baseRotation: 0,
            baseJitterFraction: 0,
            baseOffset: .zero
        )
        let randomization = BrushRandomization(
            spacing: 0,
            scatter: 1,
            rotation: 0,
            grain: 0,
            material: 0
        )
        let scatter = nativeTestMapping(
            input: .random,
            output: 0...4,
            missingInputValue: 0
        )
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: nativeTestProgram(nativeTestDefinition(
                placement: placement,
                dynamics: nativeTestDynamics(
                    scatter: scatter,
                    randomization: randomization
                )
            )),
            profile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(close(descriptor.coreBounds.width, 40))
        #expect(close(descriptor.envelopeBounds.width, 72))
        #expect(close(descriptor.envelopeBounds.height, 72))
    }

    @Test
    func componentProgramsProfilesAndPlacementFormAConservativeUnion() throws {
        let primaryDefinition = nativeTestDefinition(
            coverage: coverage(shape: .hardRound, aspect: 1),
            placement: placement(offset: SIMD2(-30, 0))
        )
        let secondaryDefinition = nativeTestDefinition(
            coverage: coverage(shape: .chisel, aspect: 0.25),
            placement: placement(
                scatter: 0.1,
                jitter: 0.05,
                offset: SIMD2(30, 0)
            ),
            dynamics: nativeTestDynamics(
                size: nativeTestMapping(
                    input: .pressure,
                    output: 0.5...1,
                    missingInputValue: 1
                ),
                randomization: BrushRandomization(
                    spacing: 0,
                    scatter: 1,
                    rotation: 0,
                    grain: 0,
                    material: 0
                )
            )
        )
        let program = try compositeCursorProgram(
            primary: primaryDefinition,
            secondary: secondaryDefinition
        )

        let descriptor = try BrushCursorDescriptor.evaluate(
            program: program,
            primaryProfile: BrushCursorTipProfile(
                primary: .analyticEllipse
            ),
            secondaryProfile: BrushCursorTipProfile(
                primary: .analyticRectangle
            ),
            input: cursorInput(nominalDiameter: 40, pressure: 0)
        )

        #expect(descriptor.primaryComponent.ordinal == 0)
        #expect(descriptor.secondaryComponent?.ordinal == 1)
        #expect(close(descriptor.primaryComponent.coreBounds?.width ?? 0, 40))
        #expect(close(descriptor.secondaryComponent?.coreBounds?.width ?? 0, 20))
        #expect(close(descriptor.secondaryComponent?.coreBounds?.height ?? 0, 5))
        #expect(close(descriptor.coreBounds.minimum.x, -50))
        #expect(close(descriptor.coreBounds.maximum.x, 40))
        #expect(descriptor.containsCore(SIMD2(-45, 0)))
        #expect(descriptor.containsCore(SIMD2(39, 0)))
        #expect(!descriptor.containsCore(SIMD2(0, 0)))
        #expect(descriptor.envelopeBounds.maximum.x > 40)
        #expect(!descriptor.isCircle)
    }

    @Test
    func nestedVisibleCirclesUnionButAreNotReportedAsOneCircle() throws {
        let outer = nativeTestDefinition()
        let inner = nativeTestDefinition(dynamics: nativeTestDynamics(
            size: nativeTestMapping(
                input: .pressure,
                output: 0.5...0.5,
                missingInputValue: 0.5
            )
        ))
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: compositeCursorProgram(primary: outer, secondary: inner),
            primaryProfile: BrushCursorTipProfile(primary: .analyticEllipse),
            secondaryProfile: BrushCursorTipProfile(primary: .analyticEllipse),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(close(descriptor.coreBounds.width, 40))
        #expect(descriptor.containsCore(SIMD2(19, 0)))
        #expect(!descriptor.isCircle)
    }

    @Test
    func emptyComponentContributionDoesNotEraseVisibleCircle() throws {
        let visible = nativeTestDefinition()
        let emptyCoverage = BrushCoverageDefinition(
            shapes: [
                BrushShapeLayerDefinition(
                    shape: .hardRound,
                    combination: .replace,
                    scale: 1,
                    rotation: 0,
                    offset: .zero
                ),
                BrushShapeLayerDefinition(
                    shape: .chisel,
                    combination: .multiply,
                    scale: 0.25,
                    rotation: 0,
                    offset: SIMD2(4, 0)
                ),
            ],
            grains: [],
            baseHardness: 1,
            aspectRatio: 1,
            tipThreshold: 0,
            antialiasing: true
        )
        let empty = nativeTestDefinition(coverage: emptyCoverage)
        let descriptor = try BrushCursorDescriptor.evaluate(
            program: compositeCursorProgram(primary: visible, secondary: empty),
            primaryProfile: BrushCursorTipProfile(primary: .analyticEllipse),
            secondaryProfile: BrushCursorTipProfile(
                primary: .analyticEllipse,
                secondary: .analyticRectangle,
                secondaryCombination: .multiply
            ),
            input: cursorInput(nominalDiameter: 40)
        )

        #expect(descriptor.secondaryComponent?.coreBounds == nil)
        #expect(close(descriptor.coreBounds.width, 40))
        #expect(descriptor.containsCore(SIMD2(19, 0)))
        #expect(descriptor.isCircle)
    }
}

private func compositeCursorProgram(
    primary: BrushDefinition,
    secondary: BrushDefinition
) throws -> BrushProgram {
    let definition = try nativeCompositeTestDefinition(
        from: primary,
        components: [
            nativeTestComponent(
                from: primary,
                identifier: "cursor-primary",
                ordinal: 0
            ),
            nativeTestComponent(
                from: secondary,
                identifier: "cursor-secondary",
                ordinal: 1
            ),
        ]
    )
    return try BrushProgramCompiler.compile(definition)
}

private func placement(
    scatter: Float = 0,
    jitter: Float = 0,
    offset: SIMD2<Float>
) -> BrushPlacementDefinition {
    BrushPlacementDefinition(
        baseSpacingFraction: 0.1,
        maximumSpacingFraction: 0.2,
        baseFlow: 1,
        strokeOpacity: 1,
        baseScatterFraction: scatter,
        baseRotation: 0,
        baseJitterFraction: jitter,
        baseOffset: offset
    )
}

private func descriptor(
    shape: BrushShapeDescriptor,
    profileShape: BrushCursorTipShape,
    aspect: Float,
    diameter: Float
) throws -> BrushCursorDescriptor {
    let definition = nativeTestDefinition(
        coverage: coverage(shape: shape, aspect: aspect)
    )
    return try BrushCursorDescriptor.evaluate(
        program: nativeTestProgram(definition),
        profile: BrushCursorTipProfile(primary: profileShape),
        input: cursorInput(nominalDiameter: diameter)
    )
}

private func coverage(
    shape: BrushShapeDescriptor,
    aspect: Float,
    rotation: Float = 0
) -> BrushCoverageDefinition {
    BrushCoverageDefinition(
        shapes: [BrushShapeLayerDefinition(
            shape: shape,
            combination: .replace,
            scale: 1,
            rotation: rotation,
            offset: .zero
        )],
        grains: [],
        baseHardness: 1,
        aspectRatio: aspect,
        tipThreshold: 0,
        antialiasing: true
    )
}

private func cursorInput(
    nominalDiameter: Float,
    pressure: Float? = nil,
    altitude: Float? = nil,
    azimuth: Float? = nil,
    roll: Float? = nil,
    tangentialPressure: Float? = nil,
    direction: Float = 0,
    deformation: Affine2D = .identity,
    viewportScale: Float = 1,
    backingScale: Float = 1
) throws -> BrushCursorInput {
    try BrushCursorInput(
        nominalDiameter: nominalDiameter,
        pressure: pressure,
        altitude: altitude,
        azimuth: azimuth,
        roll: roll,
        tangentialPressure: tangentialPressure,
        direction: direction,
        deformation: deformation,
        viewportScale: viewportScale,
        backingScale: backingScale
    )
}

private func cyclicCursorResponse() -> BrushResponseDefinition {
    .curve(BrushCurveDefinition(points: [
        BrushCurvePoint(x: 0, y: 0),
        BrushCurvePoint(x: 0.25, y: 0.25),
        BrushCurvePoint(x: 0.5, y: 0.5),
        BrushCurvePoint(x: 0.75, y: 1),
        BrushCurvePoint(x: 1, y: 0),
    ]))
}

private func close(
    _ lhs: Float,
    _ rhs: Float,
    tolerance: Float = 0.000_1
) -> Bool {
    abs(lhs - rhs) <= tolerance
}
