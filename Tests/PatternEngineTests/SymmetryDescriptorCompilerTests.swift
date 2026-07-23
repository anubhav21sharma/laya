import Foundation
@testable import PatternEngine
import simd
import Testing

@Suite("Symmetry descriptor compiler")
struct SymmetryDescriptorCompilerTests {
    @Test
    func stableSelectorsAreAppendOnlyAndLegacyCompatible() throws {
        #expect(SymmetryDocumentDomainID.periodic.rawValue == 0)
        #expect(SymmetryDocumentDomainID.finite.rawValue == 1)
        #expect(SymmetryKernelFamily.rectangular.rawValue == 0)
        #expect(SymmetryKernelFamily.triangular.rawValue == 1)
        #expect(SymmetryKernelFamily.radial.rawValue == 2)
        #expect(SymmetryPresetID.allCases.map(\.rawValue) == Array(0...6))
        #expect(TilingKind.rotational.rawValue == 6)

        let encoded = try JSONEncoder().encode(SymmetryPresetID.mirrorXY)
        #expect(String(decoding: encoded, as: UTF8.self) == "5")
        #expect(
            try JSONDecoder().decode(
                SymmetryPresetID.self,
                from: Data("5".utf8)
            ) == .mirrorXY
        )
    }

    @Test(arguments: SymmetryPresetID.allCases)
    func everyLegacyPresetCompilesClosedRectangularData(
        _ presetID: SymmetryPresetID
    ) throws {
        let compiled = try SymmetryDescriptorCompiler.compile(
            presetID: presetID,
            tileSize: PatternSize(width: 128, height: 192)
        )

        #expect(compiled.presetID == presetID)
        #expect(compiled.domain.periodic != nil)
        #expect(compiled.family == .rectangular)
        #expect(compiled.ownership == .rectangularHalfOpen)
        #expect(compiled.rasterMetric == .identity)
        #expect(compiled.exportCapability == .rectangularRepeat)
        #expect(compiled.displayProgram.family == .rectangular)
        #expect(compiled.displayProgram.presetWireID == presetID.rawValue)
        #expect(compiled.cost.maximumImagesPerCell == compiled.images.count)
        #expect(!compiled.images.isEmpty)
        #expect(
            compiled.domain.periodic?.translationBasis
                == PeriodicTranslationBasis(
                    origin: .zero,
                    u: SIMD2(128, 0),
                    v: SIMD2(0, 192)
                )
        )
    }

    @Test
    func legacyPhaseReflectionAndRotationProgramsAreExact() throws {
        let size = PatternSize(width: 128, height: 192)
        let grid = try SymmetryDescriptorCompiler.compile(presetID: .grid, tileSize: size)
        let halfDrop = try SymmetryDescriptorCompiler.compile(presetID: .halfDrop, tileSize: size)
        let brick = try SymmetryDescriptorCompiler.compile(presetID: .brick, tileSize: size)
        let mirrorX = try SymmetryDescriptorCompiler.compile(presetID: .mirrorX, tileSize: size)
        let mirrorY = try SymmetryDescriptorCompiler.compile(presetID: .mirrorY, tileSize: size)
        let mirrorXY = try SymmetryDescriptorCompiler.compile(presetID: .mirrorXY, tileSize: size)
        let rotational = try SymmetryDescriptorCompiler.compile(presetID: .rotational, tileSize: size)

        #expect(grid.domain.periodic?.phase == nil)
        #expect(halfDrop.domain.periodic?.phase == PeriodicPhaseProgram(indexAxis: .x, offsetAxis: .y, fractions: [0, 0.5]))
        #expect(brick.domain.periodic?.phase == PeriodicPhaseProgram(indexAxis: .y, offsetAxis: .x, fractions: [0, 0.5]))
        #expect(mirrorX.domain.periodic?.alternatingReflections == [.x])
        #expect(mirrorY.domain.periodic?.alternatingReflections == [.y])
        #expect(mirrorXY.domain.periodic?.alternatingReflections == [.x, .y])
        #expect(rotational.images.map(\.ordinal) == [0, 1])
        #expect(rotational.images[1].localToCanonical == Affine2D(xAxis: SIMD2(-1, 0), yAxis: SIMD2(0, -1), translation: size.simd))
        #expect(rotational.domain.periodic?.coincidentImagePolicy == .halfTurnInvariantCoverage)
    }

    @Test
    func validationReturnsTypedDimensionFailures() {
        let cases: [(PatternSize, SymmetryDescriptorError)] = [
            (PatternSize(width: .infinity, height: 64), .nonFiniteDimension(.width)),
            (PatternSize(width: 64, height: .infinity), .nonFiniteDimension(.height)),
            (PatternSize(width: 64.5, height: 64), .nonIntegerDimension(.width)),
            (PatternSize(width: 64, height: 64.5), .nonIntegerDimension(.height)),
            (PatternSize(width: 63, height: 64), .dimensionOutOfRange(.width, value: 63)),
            (PatternSize(width: 64, height: 4_097), .dimensionOutOfRange(.height, value: 4_097)),
        ]

        for (size, expected) in cases {
            #expect(throws: expected) {
                try SymmetryDescriptorCompiler.compile(presetID: .grid, tileSize: size)
            }
        }
    }
}
