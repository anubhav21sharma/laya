import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("BrushTextureFactory")
struct BrushTextureFactoryTests {
    @Test
    @MainActor
    func stageFourTexturesKeepFrozenDimensionsMipChainsAndBaseBytes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let factory = BrushTextureFactory(device: device)

        let expected: [(BrushTextureIdentity, UInt64)] = [
            (.hardRoundShape, 11_819_887_087_282_399_793),
            (.softRoundShape, 18_200_779_059_462_012_717),
            (.chiselShape, 9_915_464_843_798_455_077),
            (.opaqueGrain, 13_884_619_858_318_455_589),
            (.paperGrain, 1_884_076_443_172_119_784),
            (.noiseGrain, 17_572_042_397_809_171_039),
        ]

        for (identity, expectedFingerprint) in expected {
            let texture = try factory.makeTexture(identity: identity)
            #expect(identity.sourceDimension == 64)
            #expect(texture.width == 64)
            #expect(texture.height == 64)
            #expect(texture.mipmapLevelCount == 7)
            #expect(fingerprint(bytes(texture)) == expectedFingerprint)
        }
    }

    @Test
    @MainActor
    func professionalPackUsesDistinctDimensionAwareDeterministicAssets() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstFactory = BrushTextureFactory(device: device)
        let secondFactory = BrushTextureFactory(device: device)
        let expected: [(BrushTextureIdentity, BrushTextureKind, Int, Int, Int)] = [
            (.technicalNibShape, .shape, 128, 8, 21_845),
            (.graphiteTipShape, .shape, 128, 8, 21_845),
            (.charcoalTipShape, .shape, 128, 8, 21_845),
            (.markerChiselShape, .shape, 128, 8, 21_845),
            (.graphiteGrain, .grain, 256, 9, 87_381),
            (.charcoalGrain, .grain, 256, 9, 87_381),
        ]
        var fingerprints: Set<UInt64> = []

        for (identity, kind, dimension, mipCount, residentBytes) in expected {
            let first = try firstFactory.makeTexture(identity: identity)
            let second = try secondFactory.makeTexture(identity: identity)
            let base = bytes(first)

            #expect(identity.kind == kind)
            #expect(identity.sourceDimension == dimension)
            #expect(first.width == dimension)
            #expect(first.height == dimension)
            #expect(first.mipmapLevelCount == mipCount)
            #expect(mipByteCount(first) == residentBytes)
            #expect(base.contains(where: { $0 > 0 }))
            #expect(base.contains(where: { $0 < 255 }))
            #expect(Set(base).count > 2)
            #expect(fingerprints.insert(fingerprint(base)).inserted)

            for level in 0..<first.mipmapLevelCount {
                #expect(bytes(first, level: level) == bytes(second, level: level))
            }
        }
    }

    @Test
    @MainActor
    func resolverPreservesProfessionalIdentityAndSourceDimensions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resolver = BrushTextureResolver(device: device)

        let nib = try resolver.resolve(
            shape: .asset(BrushTextureIdentity.technicalNibShape.rawValue)
        )
        let grain = try resolver.resolve(
            grain: .asset(BrushTextureIdentity.charcoalGrain.rawValue)
        )

        #expect(nib.isExact)
        #expect(nib.resolvedIdentity == .technicalNibShape)
        #expect(nib.texture.width == 128)
        #expect(nib.texture.mipmapLevelCount == 8)
        #expect(grain.isExact)
        #expect(grain.resolvedIdentity == .charcoalGrain)
        #expect(grain.texture.width == 256)
        #expect(grain.texture.mipmapLevelCount == 9)
    }

    @Test
    @MainActor
    func proceduralPackUsesR8AndCompleteDeterministicMipChains() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let firstFactory = BrushTextureFactory(device: device)
        let secondFactory = BrushTextureFactory(device: device)

        for identity in BrushTextureIdentity.allCases {
            let first = try firstFactory.makeTexture(identity: identity)
            let second = try secondFactory.makeTexture(identity: identity)

            #expect(first.pixelFormat == .r8Unorm)
            #expect(first.width == identity.sourceDimension)
            #expect(first.height == identity.sourceDimension)
            #expect(first.mipmapLevelCount == mipCount(for: identity.sourceDimension))
            #expect(first.mipmapLevelCount == second.mipmapLevelCount)
            #expect(first.label == identity.rawValue)

            for level in 0..<first.mipmapLevelCount {
                #expect(bytes(first, level: level) == bytes(second, level: level))
            }
            #expect(first.width >> (first.mipmapLevelCount - 1) == 1)
            #expect(first.height >> (first.mipmapLevelCount - 1) == 1)
        }
    }

    @Test
    @MainActor
    func everyMipIsTheRoundedBoxAverageOfItsParent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let factory = BrushTextureFactory(device: device)

        for identity in BrushTextureIdentity.allCases {
            let texture = try factory.makeTexture(identity: identity)
            for level in 1..<texture.mipmapLevelCount {
                let parentWidth = max(1, texture.width >> (level - 1))
                let parentHeight = max(1, texture.height >> (level - 1))
                let width = max(1, texture.width >> level)
                let height = max(1, texture.height >> level)
                let parent = bytes(texture, level: level - 1)
                let child = bytes(texture, level: level)

                #expect(child == boxAverage(
                    parent,
                    width: parentWidth,
                    height: parentHeight,
                    outputWidth: width,
                    outputHeight: height
                ))
            }
        }
    }

    @Test
    @MainActor
    func shapeAndGrainPackHasDistinctCoverageSemantics() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let factory = BrushTextureFactory(device: device)
        let hard = bytes(try factory.makeTexture(identity: .hardRoundShape))
        let soft = bytes(try factory.makeTexture(identity: .softRoundShape))
        let chisel = bytes(try factory.makeTexture(identity: .chiselShape))
        let opaque = bytes(try factory.makeTexture(identity: .opaqueGrain))
        let paper = bytes(try factory.makeTexture(identity: .paperGrain))
        let noise = bytes(try factory.makeTexture(identity: .noiseGrain))
        let size = BrushTextureIdentity.hardRoundShape.sourceDimension
        let center = (size / 2) * size + size / 2

        #expect(hard[center] == 255)
        #expect(hard[0] == 0)
        #expect(soft[center] > soft[size / 2])
        #expect(chisel != hard)
        #expect(chisel != soft)
        #expect(chisel != Array(chisel.reversed()))
        #expect(opaque.allSatisfy { $0 == 255 })
        #expect(paper != opaque)
        #expect(noise != opaque)
        #expect(paper != noise)
    }
}

@Suite("BrushTextureResolver")
struct BrushTextureResolverTests {
    @Test
    @MainActor
    func validationPackCanBePreloadedBeforeStrokeResolution() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resolver = BrushTextureResolver(device: device)

        try resolver.preloadValidationPack()
        let cachedCount = resolver.cachedTextureCount
        _ = try resolver.resolve(shape: .chisel)
        _ = try resolver.resolve(grain: .noise)

        #expect(cachedCount == BrushTextureIdentity.allCases.count)
        #expect(resolver.cachedTextureCount == cachedCount)
    }

    @Test
    @MainActor
    func exactAssetsAreCachedWithGuardedIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resolver = BrushTextureResolver(device: device)

        let first = try resolver.resolve(shape: .softRound)
        let second = try resolver.resolve(
            shape: .asset("builtin.shape.soft-round")
        )

        #expect(first.isExact)
        #expect(!first.usedFallback)
        #expect(first.requestedIdentity == "builtin.shape.soft-round")
        #expect(first.resolvedIdentity == .softRoundShape)
        #expect(ObjectIdentifier(first.texture as AnyObject)
            == ObjectIdentifier(second.texture as AnyObject))
        #expect(resolver.cachedTextureCount == 1)
    }

    @Test
    @MainActor
    func supportedRecipeAssetCanBeUnavailableAndFallbackRetainsIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let requestedIdentity = BrushTextureIdentity.softRoundShape.rawValue
        let recipe = try BrushRecipe(
            id: BrushRecipeID("test.asset.available-catalog-miss"),
            shape: .asset(requestedIdentity)
        )
        var diagnostics: [BrushAssetFallbackDiagnostic] = []
        let availableIdentities = Set(BrushTextureIdentity.allCases)
            .subtracting([.softRoundShape])
        let resolver = BrushTextureResolver(
            device: device,
            availableIdentities: availableIdentities
        ) {
            diagnostics.append($0)
        }

        let first = try resolver.resolve(shape: recipe.shape)
        let second = try resolver.resolve(shape: recipe.shape)

        #expect(first.requestedIdentity == requestedIdentity)
        #expect(first.resolvedIdentity == .hardRoundShape)
        #expect(first.usedFallback)
        #expect(!first.isExact)
        #expect(ObjectIdentifier(first.texture as AnyObject)
            == ObjectIdentifier(second.texture as AnyObject))
        #expect(diagnostics == [
            BrushAssetFallbackDiagnostic(
                kind: .shape,
                requestedIdentity: requestedIdentity,
                fallbackIdentity: .hardRoundShape
            ),
        ])
    }

    @Test
    @MainActor
    func missingAssetUsesTypedFallbackAndDiagnosesIdentityOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var diagnostics: [BrushAssetFallbackDiagnostic] = []
        let resolver = BrushTextureResolver(device: device) {
            diagnostics.append($0)
        }

        let first = try resolver.resolve(
            shape: .asset("missing.shape.tip")
        )
        let second = try resolver.resolve(
            shape: .asset("missing.shape.tip")
        )
        _ = try resolver.resolve(
            grain: .asset("missing.shape.tip")
        )

        #expect(first.usedFallback)
        #expect(!first.isExact)
        #expect(first.requestedIdentity == "missing.shape.tip")
        #expect(first.resolvedIdentity == .hardRoundShape)
        #expect(ObjectIdentifier(first.texture as AnyObject)
            == ObjectIdentifier(second.texture as AnyObject))
        #expect(resolver.reportedFallbackCount == 1)
        #expect(diagnostics == [
            BrushAssetFallbackDiagnostic(
                kind: .shape,
                requestedIdentity: "missing.shape.tip",
                fallbackIdentity: .hardRoundShape
            ),
        ])
    }

    @Test
    @MainActor
    func namedAssetCannotSilentlyPassAsFallback() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resolver = BrushTextureResolver(device: device)

        let named = try resolver.resolve(
            grain: .asset("builtin.grain.paper")
        )
        let missing = try resolver.resolve(
            grain: .asset("builtin.grain.not-present")
        )

        #expect(named.isExact)
        #expect(named.resolvedIdentity == .paperGrain)
        #expect(!named.usedFallback)
        #expect(missing.usedFallback)
        #expect(missing.resolvedIdentity == .opaqueGrain)
        #expect(named.requestedIdentity != missing.resolvedIdentity.rawValue)
        #expect(bytes(named.texture) != bytes(missing.texture))
    }

    @Test
    @MainActor
    func shapeAndGrainFallbacksRemainTypeCorrect() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resolver = BrushTextureResolver(device: device)

        let wrongShape = try resolver.resolve(
            shape: .asset("builtin.grain.paper")
        )
        let wrongGrain = try resolver.resolve(
            grain: .asset("builtin.shape.chisel")
        )

        #expect(wrongShape.resolvedIdentity == .hardRoundShape)
        #expect(wrongShape.usedFallback)
        #expect(wrongGrain.resolvedIdentity == .opaqueGrain)
        #expect(wrongGrain.usedFallback)
    }
}

private func bytes(
    _ texture: any MTLTexture,
    level: Int = 0
) -> [UInt8] {
    let width = max(1, texture.width >> level)
    let height = max(1, texture.height >> level)
    var result = [UInt8](repeating: 0, count: width * height)
    result.withUnsafeMutableBytes { buffer in
        texture.getBytes(
            buffer.baseAddress!,
            bytesPerRow: width,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: level
        )
    }
    return result
}

private func boxAverage(
    _ input: [UInt8],
    width: Int,
    height: Int,
    outputWidth: Int,
    outputHeight: Int
) -> [UInt8] {
    var output = [UInt8](
        repeating: 0,
        count: outputWidth * outputHeight
    )
    for y in 0..<outputHeight {
        for x in 0..<outputWidth {
            let x0 = min(width - 1, x * 2)
            let x1 = min(width - 1, x0 + 1)
            let y0 = min(height - 1, y * 2)
            let y1 = min(height - 1, y0 + 1)
            let sum = Int(input[y0 * width + x0])
                + Int(input[y0 * width + x1])
                + Int(input[y1 * width + x0])
                + Int(input[y1 * width + x1])
            output[y * outputWidth + x] = UInt8((sum + 2) / 4)
        }
    }
    return output
}

private func fingerprint(_ values: [UInt8]) -> UInt64 {
    values.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { result, value in
        (result ^ UInt64(value)) &* 0x0000_0100_0000_01B3
    }
}

private func mipCount(for dimension: Int) -> Int {
    var dimension = dimension
    var count = 1
    while dimension > 1 {
        dimension /= 2
        count += 1
    }
    return count
}

private func mipByteCount(_ texture: any MTLTexture) -> Int {
    (0..<texture.mipmapLevelCount).reduce(0) { partial, level in
        let width = max(1, texture.width >> level)
        let height = max(1, texture.height >> level)
        return partial + width * height
    }
}
