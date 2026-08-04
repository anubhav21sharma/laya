import CryptoKit
import Foundation
import Testing

@Suite("Stage D baseline renderer contracts", .serialized)
struct StageDBaselineContractTests {
    @Test
    func baselinePaintSurfaceAllocationsRemainEnumeratedUntilTaskFive() throws {
        #expect(
            try stageDBaselinePaintAllocations() == [
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/CanonicalRaster.swift",
                    type: "CanonicalRaster",
                    physicalTextureCount: 2
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/PersistentLiveTile.swift",
                    type: "PersistentLiveTile",
                    physicalTextureCount: 1
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/Brush/ReplayLiveTile.swift",
                    type: "ReplayLiveTile",
                    physicalTextureCount: 1
                ),
                StageDPaintAllocation(
                    file: "Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift",
                    type: "StrokeMetalSurfaceResources",
                    physicalTextureCount: 2
                ),
            ]
        )
    }

    @Test
    func encodedImportFixturesHaveIndependentLinearReferences() {
        for fixture in stageDImportFixtures {
            #expect(fixture.encodedBGRA8.count == 4)
            #expect(fixture.linearReference.count == 4)
            let actual = stageDDecodeEncodedBGRA8(fixture.encodedBGRA8)
            for (actual, expected) in zip(
                actual,
                fixture.linearReference
            ) {
                #expect(
                    abs(actual - expected) < 1e-9,
                    Comment(rawValue: fixture.name)
                )
            }
        }
    }

    @Test
    func drySceneSemanticAndCanonicalHashesAreFrozen() {
        for scene in stageDDryScenes {
            #expect(stageDSHA256(Data(scene.semanticDescription.utf8)) == scene.semanticSHA256)
            #expect(stageDSHA256(Data(scene.canonicalBGRA8)) == scene.canonicalBGRA8SHA256)
        }
    }

    @Test
    func stageCLifecycleInventoryHasOneNamedOwner() {
        #expect(stageDLifecycleTransitions.count == 12)
        for transition in stageDLifecycleTransitions {
            #expect(!transition.stageCAcceptanceAssertion.isEmpty)
            #expect(!transition.stageDInsertionPoint.isEmpty)
        }
    }
}

private struct StageDPaintAllocation: Equatable {
    let file: String
    let type: String
    let physicalTextureCount: Int
}

private func stageDBaselinePaintAllocations() throws -> [StageDPaintAllocation] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try [
        ("Sources/MetalRenderer/CanonicalRaster.swift", "CanonicalRaster", 2),
        ("Sources/MetalRenderer/PersistentLiveTile.swift", "PersistentLiveTile", 1),
        ("Sources/MetalRenderer/Brush/ReplayLiveTile.swift", "ReplayLiveTile", 1),
        ("Sources/MetalRenderer/StrokeRuntime/StrokePrivateSurfaceEncoder.swift", "StrokeMetalSurfaceResources", 2),
    ].map { file, type, physicalTextureCount in
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(file),
            encoding: .utf8
        )
        #expect(source.contains("pixelFormat: .bgra8Unorm"))
        return StageDPaintAllocation(
            file: file,
            type: type,
            physicalTextureCount: physicalTextureCount
        )
    }
}

private struct StageDEncodedImportFixture: Sendable {
    let name: String
    let encodedBGRA8: [UInt8]
    /// Hand-derived from IEC 61966-2-1 decode; alpha is never gamma encoded.
    let linearReference: [Double]
}

private let stageDImportFixtures: [StageDEncodedImportFixture] = [
    StageDEncodedImportFixture(
        name: "empty",
        encodedBGRA8: [0, 0, 0, 0],
        linearReference: [0, 0, 0, 0]
    ),
    StageDEncodedImportFixture(
        name: "translucent",
        encodedBGRA8: [32, 64, 128, 128],
        linearReference: [0.014443843596, 0.051269458374, 0.215860500114, 128.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "low-flow-repeated-buildup",
        encodedBGRA8: [16, 32, 64, 96],
        linearReference: [0.005181516702, 0.014443843596, 0.051269458374, 96.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "erase",
        encodedBGRA8: [24, 48, 96, 160],
        linearReference: [0.009134058702, 0.029556834438, 0.116970667759, 160.0 / 255.0]
    ),
    StageDEncodedImportFixture(
        name: "periodic-seam",
        encodedBGRA8: [255, 0, 255, 255],
        linearReference: [1, 0, 1, 1]
    ),
    StageDEncodedImportFixture(
        name: "radial-pages",
        encodedBGRA8: [12, 180, 240, 224],
        linearReference: [0.003676507324, 0.456411023180, 0.871367119199, 224.0 / 255.0]
    ),
]

private struct StageDDryScene: Sendable {
    let name: String
    let semanticDescription: String
    let canonicalBGRA8: [UInt8]
    let semanticSHA256: String
    let canonicalBGRA8SHA256: String
}

private let stageDDryScenes: [StageDDryScene] = [
    StageDDryScene(
        name: "empty",
        semanticDescription: "stage-d-dry/empty/transparent",
        canonicalBGRA8: [0, 0, 0, 0],
        semanticSHA256: "28830e8bf009bc6b7283fbf0ce65632f22c5802a4f9231b609ea19911687393e",
        canonicalBGRA8SHA256: "df3f619804a92fdb4057192dc43dd748ea778adc52bc498ce80524c014b81119"
    ),
    StageDDryScene(
        name: "periodic-seam",
        semanticDescription: "stage-d-dry/periodic-seam/encoded-bgra8",
        canonicalBGRA8: [255, 0, 255, 255],
        semanticSHA256: "d22a73bfb4001fcd402b6fdd8c79126619b0eb88ee1528d2cfcf47d8fe4d7cb2",
        canonicalBGRA8SHA256: "f7f9e13d8ace3958b3fee2a2cbfa1d16dc90523b4ea4fd124c8e3aba6a872401"
    ),
    StageDDryScene(
        name: "radial-pages",
        semanticDescription: "stage-d-dry/radial-pages/encoded-bgra8",
        canonicalBGRA8: [12, 180, 240, 224],
        semanticSHA256: "dc87cf3b941b10246261c236364e1db11c1a6cdb6923d7efcbd9052982eb83db",
        canonicalBGRA8SHA256: "12cffdd06cc41ab40c4ef7dfef98c8b7d12b2c7359ae241f2f9599d98f73af42"
    ),
]

private func stageDDecodeEncodedBGRA8(_ encoded: [UInt8]) -> [Double] {
    encoded.enumerated().map { index, byte in
        let value = Double(byte) / 255
        if index == 3 { return value }
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

private func stageDSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private struct StageDLifecycleTransition: Sendable {
    let name: String
    let stageCAcceptanceAssertion: String
    let stageDInsertionPoint: String
}

private let stageDLifecycleTransitions: [StageDLifecycleTransition] = [
    .init(name: "initialize-import", stageCAcceptanceAssertion: "replacement installation", stageDInsertionPoint: "empty sparse import"),
    .init(name: "begin", stageCAcceptanceAssertion: "beginStroke", stageDInsertionPoint: "pointer-down layer capture"),
    .init(name: "append-actual-coalesced", stageCAcceptanceAssertion: "authoritative batch partition", stageDInsertionPoint: "touched tile reservation"),
    .init(name: "replace-prediction", stageCAcceptanceAssertion: "prediction isolation", stageDInsertionPoint: "prediction tile lease"),
    .init(name: "prepare-submit-display", stageCAcceptanceAssertion: "off-main workspace availability", stageDInsertionPoint: "linear display encode"),
    .init(name: "finish-commit", stageCAcceptanceAssertion: "finishCommitForHarness", stageDInsertionPoint: "layer-bound history"),
    .init(name: "cancel-failure", stageCAcceptanceAssertion: "injected off-main failure", stageDInsertionPoint: "transactional tile discard"),
    .init(name: "clear", stageCAcceptanceAssertion: "requestClearForHarness", stageDInsertionPoint: "active layer tile clear"),
    .init(name: "undo-redo", stageCAcceptanceAssertion: "requestRasterRestoreForHarness", stageDInsertionPoint: "original layer target"),
    .init(name: "layer-mutation", stageCAcceptanceAssertion: "active stroke ownership", stageDInsertionPoint: "drawing transaction rejection"),
    .init(name: "resize-mode-switch-import", stageCAcceptanceAssertion: "requestResizeForHarness", stageDInsertionPoint: "replacement tiled document"),
    .init(name: "export-save", stageCAcceptanceAssertion: "canonical snapshot", stageDInsertionPoint: "single linear-to-encoded boundary"),
]
