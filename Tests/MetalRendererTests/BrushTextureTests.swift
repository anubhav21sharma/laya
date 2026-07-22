import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("BrushTextureFactory")
struct BrushTextureFactoryTests {
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
            #expect(first.width == BrushTextureFactory.textureSize)
            #expect(first.height == BrushTextureFactory.textureSize)
            #expect(first.mipmapLevelCount == 7)
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
        let size = BrushTextureFactory.textureSize
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
