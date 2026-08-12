import CShaderTypes
import Foundation
import Metal
@testable import MetalRenderer
import PatternEngine
import Testing

@Suite("Deposition encoder", .serialized)
@MainActor
struct DepositionEncoderTests {
    @Test
    func zeroRecordsReserveNoBuffersAndNeedNoCommandBuffer() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let prepared = try context.encoder.preflight(
            records: [],
            binding: context.binding,
            material: context.material,
            target: context.target
        )

        let outcome = try context.encoder.encode(
            prepared,
            into: context.target,
            optionalCommandBuffer: nil
        )

        #expect(prepared.instanceCount == 0)
        #expect(prepared.uploadCount == 0)
        #expect(context.pool.unavailableSlotCount == 0)
        #expect(outcome == DepositionEncodingOutcome(
            instanceCount: 0,
            uploadCount: 0,
            textureLevelRange: nil
        ))
    }

    @Test
    func chunkCountsAreExactAtEveryCapacityBoundary() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let cases = [
            (recordCount: 1, uploads: 1),
            (recordCount: 2, uploads: 1),
            (recordCount: 3, uploads: 2),
            (recordCount: 4, uploads: 2),
            (recordCount: 5, uploads: 3),
            (recordCount: 6, uploads: 3),
        ]

        for item in cases {
            let prepared = try context.encoder.preflight(
                records: records(count: item.recordCount),
                binding: context.binding,
                material: context.material,
                target: context.target
            )
            #expect(prepared.instanceCount == item.recordCount)
            #expect(prepared.uploadCount == item.uploads)
            #expect(context.pool.unavailableSlotCount == item.uploads)
            context.encoder.abandon(prepared)
            #expect(context.pool.unavailableSlotCount == 0)
        }
    }

    @Test
    func recordsRemainInInputOrderAcrossPackedChunks() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let prepared = try context.encoder.preflight(
            records: records(count: 5),
            binding: context.binding,
            material: context.material,
            target: context.target
        )

        var packedIdentities: [UInt64] = []
        for chunk in prepared.chunks {
            let pointer = chunk.lease.buffer.contents().assumingMemoryBound(
                to: PatternDepositionStampInstance.self
            )
            for index in 0..<chunk.count {
                let packed = pointer[index].identity
                packedIdentities.append(
                    UInt64(packed.x) | (UInt64(packed.y) << 32)
                )
            }
        }

        #expect(packedIdentities == [0, 1, 2, 3, 4])
        context.encoder.abandon(prepared)
    }

    @Test
    func componentOrderProducesContiguousBindingRunsWithoutGlobalGrouping()
        throws
    {
        guard var context = try makeContext(capacity: 8) else { return }
        let primary = DepositionComponentBinding(
            ordinal: 0,
            pipeline: context.binding,
            material: context.material
        )
        let secondary = DepositionComponentBinding(
            ordinal: 1,
            pipeline: context.binding,
            material: context.material
        )
        let prepared = try context.encoder.preflight(
            records: records(componentOrdinals: [0, 0, 1, 1, 0]),
            primary: primary,
            secondary: secondary,
            target: context.target
        )

        #expect(prepared.bindingRunCount == 3)
        #expect(prepared.componentOrdinals == [0, 0, 1, 1, 0])
        context.encoder.abandon(prepared)
    }

    @Test
    func unavailableComponentBindingFailsBeforeLeaseReservation() throws {
        guard var context = try makeContext(capacity: 8) else { return }
        let primary = DepositionComponentBinding(
            ordinal: 0,
            pipeline: context.binding,
            material: context.material
        )

        #expect(
            throws: DepositionEncodingError.componentBindingUnavailable(1)
        ) {
            _ = try context.encoder.preflight(
                records: records(componentOrdinals: [0, 1]),
                primary: primary,
                secondary: nil,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func failedMultiLeasePreflightReturnsEveryLeaseItAcquired() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let held = try #require(context.pool.acquire(count: 2))

        #expect(
            throws: DepositionEncodingError.uploadBuffersUnavailable(
                required: 2
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 3),
                binding: context.binding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 2)

        for lease in held {
            context.pool.abandon(lease)
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func chunkArithmeticRejectsOverflowBeforeReservation() {
        #expect(
            throws: DepositionEncodingError.integerOverflow
        ) {
            _ = try DepositionEncoder.requiredChunkCount(
                recordCount: Int.max,
                capacity: 2
            )
        }
    }

    @Test
    func abandoningPreparationIsIdempotent() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let prepared = try context.encoder.preflight(
            records: records(count: 5),
            binding: context.binding,
            material: context.material,
            target: context.target
        )

        context.encoder.abandon(prepared)
        context.encoder.abandon(prepared)

        #expect(context.pool.unavailableSlotCount == 0)
        #expect(context.pool.acquire(count: 3)?.count == 3)
    }

    @Test
    func targetMismatchFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let mismatched = try texture(
            device: context.device,
            pixelFormat: .bgra8Unorm,
            width: 8,
            height: 8,
            usage: [.renderTarget]
        )

        #expect(
            throws: DepositionEncodingError.targetPixelFormatMismatch(
                expected: MTLPixelFormat.rgba16Float.rawValue,
                actual: MTLPixelFormat.bgra8Unorm.rawValue
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: context.binding,
                material: context.material,
                target: mismatched
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func bgraPipelineFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let invalidKey = DepositionPipelineKey(
            brush: context.binding.key.brush,
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue: MTLPixelFormat.bgra8Unorm.rawValue,
            sampleCount: 1
        )
        let invalid = DepositionPipelineBinding(
            key: invalidKey,
            state: context.binding.state
        )

        #expect(
            throws: DepositionEncodingError.invalidPipelinePixelFormat(
                MTLPixelFormat.bgra8Unorm.rawValue
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: invalid,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func incompleteMaterialFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(
            capacity: 2,
            usesPrimaryGrain: true
        ) else { return }

        #expect(
            throws: DepositionEncodingError.missingTexture(
                .primaryGrain
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: context.binding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func analyticSecondaryShapePreflightsWithoutTextureBinding() throws {
        guard var context = try makeContext(
            capacity: 2,
            secondaryShape: .softRound
        ) else { return }

        let prepared = try context.encoder.preflight(
            records: records(count: 1),
            binding: context.binding,
            material: context.material,
            target: context.target
        )

        #expect(context.material.textures[.secondaryShape] == nil)
        context.encoder.abandon(prepared)
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func texturedSecondaryShapeFailsMaterialConstructionWithoutItsTexture() {
        #expect(
            throws: DepositionPreparationError.missingRequiredResource(
                "shape.secondary"
            )
        ) {
            _ = try DepositionMaterialBinding(
                uniformTemplate: materialTemplate(
                    secondaryShape: .asset("shape.secondary")
                ),
                textures: [:]
            )
        }
    }

    @Test
    func nonfiniteInstanceFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        var invalid = instance(identity: 7)
        invalid.tipFrame1.x = .nan
        let record = ProjectedDepositionRecord(
            identity: 7,
            instance: invalid,
            radialPage: nil
        )

        #expect(
            throws: DepositionEncodingError.invalidInstance(
                identity: 7,
                reason: .nonfiniteField("tipFrame1")
            )
        ) {
            _ = try context.encoder.preflight(
                records: [record],
                binding: context.binding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func unsupportedInstanceABIFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        var invalid = instance(identity: 7)
        invalid.metadata.w = UInt32(DepositionABI.version + 1)
        let record = ProjectedDepositionRecord(
            identity: 7,
            instance: invalid,
            radialPage: nil
        )

        #expect(
            throws: DepositionEncodingError.invalidInstance(
                identity: 7,
                reason: .unsupportedABI(DepositionABI.version + 1)
            )
        ) {
            _ = try context.encoder.preflight(
                records: [record],
                binding: context.binding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func realMetalEncodingDrawsPreparedRecordsAndReleasesOnCompletion()
        async throws
    {
        guard var context = try makeContext(capacity: 2) else { return }
        let binding = try await productionBinding(
            device: context.device,
            key: context.binding.key
        )
        clear(context.target)
        let prepared = try context.encoder.preflight(
            records: records(count: 3),
            binding: binding,
            material: context.material,
            target: context.target
        )
        let queue = try #require(context.device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())

        let outcome = try context.encoder.encode(
            prepared,
            into: context.target,
            commandBuffer: commandBuffer
        )
        await commitAndWait(commandBuffer)

        #expect(commandBuffer.status == .completed)
        #expect(outcome.instanceCount == 3)
        #expect(outcome.uploadCount == 2)
        #expect(outcome.textureLevelRange == nil)
        let written = pixel(context.target, x: 4, y: 4)
        #expect(written.x > 0 || written.y > 0 || written.z > 0 || written.w > 0)

        let reusable = try #require(context.pool.acquire(count: 3))
        for lease in reusable {
            context.pool.abandon(lease)
        }
    }

    @Test
    func realMetalEncodingBindsPrimaryGrainAtItsFrozenTextureSlot()
        async throws
    {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = try DabInstanceBufferPool(device: device, capacity: 1)
        let key = DepositionPipelineKey(
            brush: BrushPipelineKey(
                backend: .deposition,
                accumulation: .flow,
                edgeTreatment: .none,
                functionConstants: BrushFunctionConstants(
                    usesSecondaryShape: false,
                    usesGrain: true,
                    usesSecondaryGrain: false
                )
            ),
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue:
                DocumentColorPipeline.workingPixelFormat.rawValue,
            sampleCount: 1
        )
        let binding = DepositionPipelineBinding(
            key: key,
            state: try primaryGrainSlotPipeline(device: device)
        )
        let grain = try texture(
            device: device,
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            usage: [.shaderRead]
        )
        grain.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: [UInt8(255), 0, 0, 255],
            bytesPerRow: 4
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: materialTemplate(
                primaryGrain: .asset("grain.test")
            ),
            textures: ["grain.test": grain]
        )
        let target = try texture(
            device: device,
            pixelFormat: DocumentColorPipeline.workingPixelFormat,
            width: 8,
            height: 8,
            usage: [.renderTarget]
        )
        clear(target)
        var encoder = DepositionEncoder(
            instancePool: pool,
            frameUniforms: frameUniforms(side: 8)
        )
        let prepared = try encoder.preflight(
            records: records(count: 3),
            binding: binding,
            material: material,
            target: target
        )
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )

        let outcome = try encoder.encode(
            prepared,
            into: target,
            commandBuffer: commandBuffer
        )
        await commitAndWait(commandBuffer)

        #expect(commandBuffer.status == .completed)
        #expect(outcome.instanceCount == 3)
        #expect(outcome.uploadCount == 3)
        #expect(pixel(target, x: 4, y: 4) == SIMD4(1, 0, 0, 1))
    }

    @Test
    func missingCommandBufferReleasesEveryPreparedLease() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let prepared = try context.encoder.preflight(
            records: records(count: 3),
            binding: context.binding,
            material: context.material,
            target: context.target
        )

        #expect(throws: DepositionEncodingError.commandBufferUnavailable) {
            _ = try context.encoder.encode(
                prepared,
                into: context.target,
                optionalCommandBuffer: nil
            )
        }

        #expect(context.pool.unavailableSlotCount == 0)
        #expect(context.pool.acquire(count: 3)?.count == 3)
    }

    @Test
    func forcedRenderEncoderFailureReleasesEveryPreparedLease() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pool = try DabInstanceBufferPool(device: device, capacity: 2)
        guard let base = try makeContext(capacity: 2) else { return }
        var encoder = DepositionEncoder(
            instancePool: pool,
            frameUniforms: frameUniforms(side: 8),
            makeRenderEncoder: { _, _ in nil }
        )
        let prepared = try encoder.preflight(
            records: records(count: 3),
            binding: base.binding,
            material: base.material,
            target: base.target
        )
        let commandBuffer = try #require(
            device.makeCommandQueue()?.makeCommandBuffer()
        )

        #expect(throws: DepositionEncodingError.renderEncoderUnavailable) {
            _ = try encoder.encode(
                prepared,
                into: base.target,
                commandBuffer: commandBuffer
            )
        }

        #expect(pool.unavailableSlotCount == 0)
        #expect(pool.acquire(count: 3)?.count == 3)
    }

    @Test
    func changingTargetAfterPreflightReleasesEveryLease() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let replacement = try texture(
            device: context.device,
            pixelFormat: DocumentColorPipeline.workingPixelFormat,
            width: 8,
            height: 8,
            usage: [.renderTarget]
        )
        let prepared = try context.encoder.preflight(
            records: records(count: 3),
            binding: context.binding,
            material: context.material,
            target: context.target
        )
        let commandBuffer = try #require(
            context.device.makeCommandQueue()?.makeCommandBuffer()
        )

        #expect(throws: DepositionEncodingError.targetChangedAfterPreflight) {
            _ = try context.encoder.encode(
                prepared,
                into: replacement,
                commandBuffer: commandBuffer
            )
        }

        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func materialMipRangeIsReportedWithoutAllocatingDuringEncode() throws {
        guard var context = try makeContext(
            capacity: 2,
            usesPrimaryGrain: true
        ) else { return }
        let grain = try texture(
            device: context.device,
            pixelFormat: .r8Unorm,
            width: 8,
            height: 8,
            mipmapped: true,
            usage: [.shaderRead]
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: materialTemplate(
                primaryGrain: .asset("grain.test")
            ),
            textures: ["grain.test": grain]
        )
        let prepared = try context.encoder.preflight(
            records: records(count: 1),
            binding: context.binding,
            material: material,
            target: context.target
        )

        #expect(prepared.textureLevelRange == 0...3)
        context.encoder.abandon(prepared)
    }

    @Test
    func texturedTipReportsProjectedMipRangeFromFrozenInstanceFootprint()
        throws
    {
        guard var context = try makeContext(capacity: 2) else { return }
        let shape = try texture(
            device: context.device,
            pixelFormat: .r8Unorm,
            width: 256,
            height: 128,
            mipmapped: true,
            usage: [.shaderRead]
        )
        let assetSupport = try BrushTipAssetSupportCompiler.compile(
            baseLevel: Data([255]),
            width: 1,
            height: 1
        )
        let tip = CompiledBrushTipSupport(
            semanticTipHash: "tip",
            source: .texture(resourceID: "shape.test"),
            definition: .analyticEllipse,
            assetSupport: assetSupport,
            sourceWidth: 256,
            sourceHeight: 128,
            mipLevelCount: shape.mipmapLevelCount
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: materialTemplate(
                primaryShape: .asset("shape.test")
            ),
            textures: ["shape.test": shape],
            tipSupports: [tip]
        )

        let prepared = try context.encoder.preflight(
            records: records(count: 1),
            binding: context.binding,
            material: material,
            target: context.target
        )

        #expect(prepared.selectedTipLevelOfDetailRange == 7...7)
        context.encoder.abandon(prepared)
    }

    @Test
    func rotatedSecondaryAssetReportsItsTransformedAnisotropicMipLevel()
        throws
    {
        guard var context = try makeContext(
            capacity: 2,
            secondaryShape: .softRound
        ) else { return }
        let shape = try texture(
            device: context.device,
            pixelFormat: .r8Unorm,
            width: 256,
            height: 128,
            mipmapped: true,
            usage: [.shaderRead]
        )
        let assetSupport = try BrushTipAssetSupportCompiler.compile(
            baseLevel: Data([255]),
            width: 1,
            height: 1
        )
        let primary = CompiledBrushTipSupport(
            semanticTipHash: "primary",
            source: .analyticEllipse,
            definition: .analyticEllipse,
            assetSupport: nil,
            sourceWidth: nil,
            sourceHeight: nil,
            mipLevelCount: 0
        )
        let secondary = CompiledBrushTipSupport(
            semanticTipHash: "secondary",
            source: .texture(resourceID: "shape.secondary"),
            definition: .analyticEllipse,
            assetSupport: assetSupport,
            sourceWidth: 256,
            sourceHeight: 128,
            mipLevelCount: shape.mipmapLevelCount
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: materialTemplate(
                secondaryShape: .asset("shape.secondary"),
                secondaryRotation: .pi / 2
            ),
            textures: ["shape.secondary": shape],
            tipSupports: [primary, secondary]
        )
        var rotated = instance(identity: 0)
        rotated.tipFrame0 = SIMD4(4, 0, 0, 1)
        let record = ProjectedDepositionRecord(
            identity: 0,
            instance: rotated,
            radialPage: nil
        )

        let prepared = try context.encoder.preflight(
            records: [record],
            binding: context.binding,
            material: material,
            target: context.target
        )

        #expect(prepared.selectedTipLevelOfDetailRange == 7...7)
        context.encoder.abandon(prepared)
    }

    @Test
    func warmPoolReusesItsFixedBuffersWithoutGrowth() throws {
        guard var context = try makeContext(capacity: 1) else { return }
        let first = try context.encoder.preflight(
            records: records(count: 3),
            binding: context.binding,
            material: context.material,
            target: context.target
        )
        let firstBuffers = first.chunks.map {
            ObjectIdentifier($0.lease.buffer as AnyObject)
        }
        context.encoder.abandon(first)

        let second = try context.encoder.preflight(
            records: records(count: 3),
            binding: context.binding,
            material: context.material,
            target: context.target
        )
        let secondBuffers = second.chunks.map {
            ObjectIdentifier($0.lease.buffer as AnyObject)
        }

        #expect(Set(firstBuffers) == Set(secondBuffers))
        context.encoder.abandon(second)
    }

    @Test
    func invalidPipelinePixelFormatFailsBeforeAnyLeaseIsReserved() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let invalidKey = DepositionPipelineKey(
            brush: context.binding.key.brush,
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue: MTLPixelFormat.invalid.rawValue,
            sampleCount: 1
        )
        let invalidBinding = DepositionPipelineBinding(
            key: invalidKey,
            state: context.binding.state
        )

        #expect(
            throws: DepositionEncodingError.invalidPipelinePixelFormat(
                MTLPixelFormat.invalid.rawValue
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: invalidBinding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func droppingUnconsumedPreparationReturnsEveryLease() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        var prepared: PreparedDepositionEncoding? = try context.encoder
            .preflight(
                records: records(count: 3),
                binding: context.binding,
                material: context.material,
                target: context.target
            )
        #expect(context.pool.unavailableSlotCount == 2)

        prepared = nil

        #expect(prepared == nil)
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func recordAndUploadLimitsFailWithoutReservingBuffers() throws {
        guard let base = try makeContext(capacity: 1) else { return }
        var recordLimited = DepositionEncoder(
            instancePool: base.pool,
            frameUniforms: frameUniforms(side: 8),
            maximumRecordCount: 2
        )

        #expect(
            throws: DepositionEncodingError.recordLimitExceeded(
                actual: 3,
                maximum: 2
            )
        ) {
            _ = try recordLimited.preflight(
                records: records(count: 3),
                binding: base.binding,
                material: base.material,
                target: base.target
            )
        }
        #expect(base.pool.unavailableSlotCount == 0)

        var uploadLimited = DepositionEncoder(
            instancePool: base.pool,
            frameUniforms: frameUniforms(side: 8),
            maximumUploadCount: 2
        )
        #expect(
            throws: DepositionEncodingError.uploadLimitExceeded(
                actual: 3,
                maximum: 2
            )
        ) {
            _ = try uploadLimited.preflight(
                records: records(count: 3),
                binding: base.binding,
                material: base.material,
                target: base.target
            )
        }
        #expect(base.pool.unavailableSlotCount == 0)
    }

    @Test
    func unsupportedPipelineABIFailsWithoutReservingBuffers() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let unsupported = DepositionPipelineKey(
            brush: context.binding.key.brush,
            abiVersion: DepositionABI.version + 1,
            colorPixelFormatRawValue: context.binding.key
                .colorPixelFormatRawValue,
            sampleCount: context.binding.key.sampleCount
        )
        let binding = DepositionPipelineBinding(
            key: unsupported,
            state: context.binding.state
        )

        #expect(
            throws: DepositionEncodingError.unsupportedPipelineABI(
                DepositionABI.version + 1
            )
        ) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: binding,
                material: context.material,
                target: context.target
            )
        }
        #expect(context.pool.unavailableSlotCount == 0)
    }

    @Test
    func failedPreflightDoesNotAlterTargetBytes() throws {
        guard var context = try makeContext(capacity: 2) else { return }
        let nonRenderTarget = try texture(
            device: context.device,
            pixelFormat: DocumentColorPipeline.workingPixelFormat,
            width: 8,
            height: 8,
            usage: [.shaderRead]
        )
        let sentinel = [SIMD4<Float16>](
            repeating: SIMD4(0.25, 0.125, 0.0625, 0.5),
            count: 8 * 8
        )
        sentinel.withUnsafeBytes { bytes in
            nonRenderTarget.replace(
                region: MTLRegionMake2D(0, 0, 8, 8),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 8 * MemoryLayout<SIMD4<Float16>>.stride
            )
        }

        #expect(throws: DepositionEncodingError.targetIsNotRenderTarget) {
            _ = try context.encoder.preflight(
                records: records(count: 1),
                binding: context.binding,
                material: context.material,
                target: nonRenderTarget
            )
        }

        var actual = [SIMD4<Float16>](repeating: .zero, count: sentinel.count)
        actual.withUnsafeMutableBytes { bytes in
            nonRenderTarget.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 8 * MemoryLayout<SIMD4<Float16>>.stride,
                from: MTLRegionMake2D(0, 0, 8, 8),
                mipmapLevel: 0
            )
        }
        #expect(actual == sentinel)
        #expect(context.pool.unavailableSlotCount == 0)
    }

    private func makeContext(
        capacity: Int,
        usesPrimaryGrain: Bool = false,
        secondaryShape: BrushShapeDescriptor? = nil
    ) throws -> EncoderTestContext? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let pool = try DabInstanceBufferPool(
            device: device,
            capacity: capacity
        )
        let key = DepositionPipelineKey(
            brush: BrushPipelineKey(
                backend: .deposition,
                accumulation: .flow,
                edgeTreatment: .none,
                functionConstants: BrushFunctionConstants(
                    usesSecondaryShape: secondaryShape != nil,
                    usesGrain: usesPrimaryGrain,
                    usesSecondaryGrain: false
                )
            ),
            abiVersion: DepositionABI.version,
            colorPixelFormatRawValue:
                DocumentColorPipeline.workingPixelFormat.rawValue,
            sampleCount: 1
        )
        let binding = DepositionPipelineBinding(
            key: key,
            state: try minimalPipeline(device: device)
        )
        let material = try DepositionMaterialBinding(
            uniformTemplate: materialTemplate(
                secondaryShape: secondaryShape
            ),
            textures: [:]
        )
        let target = try texture(
            device: device,
            pixelFormat: DocumentColorPipeline.workingPixelFormat,
            width: 8,
            height: 8,
            usage: [.renderTarget]
        )
        return EncoderTestContext(
            device: device,
            pool: pool,
            binding: binding,
            material: material,
            target: target,
            encoder: DepositionEncoder(
                instancePool: pool,
                frameUniforms: frameUniforms(side: 8)
            )
        )
    }

    private func records(count: Int) -> [ProjectedDepositionRecord] {
        (0..<count).map { index in
            ProjectedDepositionRecord(
                identity: UInt64(index),
                instance: instance(identity: UInt64(index)),
                radialPage: nil
            )
        }
    }

    private func records(
        componentOrdinals: [UInt8]
    ) -> [ProjectedDepositionRecord] {
        componentOrdinals.enumerated().map { index, componentOrdinal in
            ProjectedDepositionRecord(
                identity: UInt64(index),
                componentOrdinal: componentOrdinal,
                instance: instance(identity: UInt64(index)),
                radialPage: nil
            )
        }
    }

    private func instance(
        identity: UInt64
    ) -> PatternDepositionStampInstance {
        let zeroClip = PatternClipHalfPlane(
            normal: .zero,
            offset: 0,
            padding: 0
        )
        return PatternDepositionStampInstance(
            tipFrame0: SIMD4(1, 0, 0, 1),
            tipFrame1: SIMD4(4, 4, 1, 0),
            primaryGrainFrame0: .zero,
            primaryGrainFrame1: .zero,
            secondaryGrainFrame0: .zero,
            secondaryGrainFrame1: .zero,
            premultipliedColor: SIMD4(0, 0, 0, 1),
            coverageInputs: SIMD4(1, 1, 1, 1),
            clip0: zeroClip,
            clip1: zeroClip,
            clip2: zeroClip,
            clip3: zeroClip,
            identity: SIMD4(
                UInt32(truncatingIfNeeded: identity),
                UInt32(truncatingIfNeeded: identity >> 32),
                0,
                0
            ),
            metadata: SIMD4(
                0,
                0,
                0,
                UInt32(DepositionABI.version)
            ),
            reserved0: .zero,
            reserved1: .zero
        )
    }

    private func minimalPipeline(
        device: any MTLDevice
    ) throws -> any MTLRenderPipelineState {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 vertex_main(uint id [[vertex_id]]) {
            const float2 p[3] = {
                float2(-1, -1), float2(3, -1), float2(-1, 3)
            };
            return float4(p[id], 0, 1);
        }
        fragment float4 fragment_main() { return float4(1); }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(
            name: "fragment_main"
        )
        descriptor.colorAttachments[0].pixelFormat =
            DocumentColorPipeline.workingPixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func primaryGrainSlotPipeline(
        device: any MTLDevice
    ) throws -> any MTLRenderPipelineState {
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 vertex_main(uint id [[vertex_id]]) {
            const float2 p[6] = {
                float2(-1, -1), float2(1, -1), float2(-1, 1),
                float2(-1, 1), float2(1, -1), float2(1, 1)
            };
            return float4(p[id], 0, 1);
        }
        fragment float4 fragment_main(
            texture2d<float, access::read> grain [[texture(2)]]
        ) {
            return grain.read(uint2(0));
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(
            name: "fragment_main"
        )
        descriptor.colorAttachments[0].pixelFormat =
            DocumentColorPipeline.workingPixelFormat
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private func texture(
        device: any MTLDevice,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        mipmapped: Bool = false,
        usage: MTLTextureUsage
    ) throws -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: mipmapped
        )
        descriptor.storageMode = .shared
        descriptor.usage = usage
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func frameUniforms(side: Float) -> PatternGridFrameUniforms {
        PatternGridFrameUniforms(
            drawableSize: SIMD2(repeating: side),
            worldCenter: .zero,
            tileSize: SIMD2(repeating: side),
            zoom: 1,
            gridLineWidth: 0,
            showGridLines: 0,
            liveVisible: 1,
            tilingKind: 0,
            diagnosticMode: 0,
            compositeMode: 0,
            symmetryFamily: 0,
            repeatSize: SIMD2(repeating: side),
            latticeXAxis: SIMD2(1, 0),
            latticeYAxis: SIMD2(0, 1),
            latticeTranslation: .zero,
            guideKind: 0,
            showCanvasBoundary: 0
        )
    }

    private func materialTemplate(
        primaryShape: BrushShapeDescriptor = .hardRound,
        secondaryShape: BrushShapeDescriptor? = nil,
        secondaryScale: Float = 1,
        secondaryRotation: Float = 0,
        primaryGrain: BrushGrainDescriptor? = nil
    ) -> BrushUniformTemplate {
        BrushUniformTemplate(
            placement: BrushPlacementDefinition(
                baseSpacingFraction: 0.1,
                maximumSpacingFraction: 0.2,
                baseFlow: 1,
                strokeOpacity: 1,
                baseScatterFraction: 0,
                baseRotation: 0,
                baseJitterFraction: 0,
                baseOffset: .zero
            ),
            coverage: BrushCoverageDefinition(
                shapes: [
                    BrushShapeLayerDefinition(
                        shape: primaryShape,
                        combination: .replace,
                        scale: 1,
                        rotation: 0,
                        offset: .zero
                    ),
                ] + (secondaryShape.map {
                    [
                        BrushShapeLayerDefinition(
                            shape: $0,
                            combination: .multiply,
                            scale: secondaryScale,
                            rotation: secondaryRotation,
                            offset: .zero
                        ),
                    ]
                } ?? []),
                grains: primaryGrain.map {
                    [
                        BrushGrainLayerDefinition(
                            grain: $0,
                            coordinateMode: .canonical,
                            transform: .identity,
                            grainMovementFraction: 0,
                            grainFollowsBrushRotation: false,
                            strength: 1
                        ),
                    ]
                } ?? [],
                baseHardness: 1,
                aspectRatio: 1,
                tipThreshold: 0,
                antialiasing: true
            ),
            color: BrushColorBehaviorDefinition(
                baseAdjustment: .identity,
                perStampJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                ),
                perStrokeJitter: BrushColorJitter(
                    hue: 0,
                    saturation: 0,
                    brightness: 0,
                    secondaryColorMix: 0
                )
            ),
            material: BrushMaterialDefinition(
                accumulation: .flow,
                interaction: .none,
                edgeTreatment: .none,
                strength: 0,
                wetness: 0,
                bleedRadius: 0,
                softenPasses: 0,
                accumulationLimit: 1,
                interactionParameters: nil
            )
        )
    }

    private func productionBinding(
        device: any MTLDevice,
        key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MetalRenderer/Shaders.metal"
            ),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CShaderTypes/include/ShaderTypes.h"
            ),
            encoding: .utf8
        )
        let library = try await device.makeLibrary(
            source: shader.replacingOccurrences(
                of: "#include \"ShaderTypes.h\"",
                with: header
            ),
            options: nil
        )
        return try await DepositionPipelineLibrary(
            device: device,
            library: library
        ).prepare(for: key)
    }

    private func commitAndWait(
        _ commandBuffer: any MTLCommandBuffer
    ) async {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
    }

    private func clear(_ texture: any MTLTexture) {
        let pixels = [SIMD4<Float16>](
            repeating: .zero,
            count: texture.width * texture.height
        )
        pixels.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: texture.width
                    * MemoryLayout<SIMD4<Float16>>.stride
            )
        }
    }

    private func pixel(
        _ texture: any MTLTexture,
        x: Int,
        y: Int
    ) -> SIMD4<Float16> {
        var pixel = SIMD4<Float16>.zero
        texture.getBytes(
            &pixel,
            bytesPerRow: MemoryLayout<SIMD4<Float16>>.stride,
            from: MTLRegionMake2D(x, y, 1, 1),
            mipmapLevel: 0
        )
        return pixel
    }
}

@MainActor
private struct EncoderTestContext {
    let device: any MTLDevice
    let pool: DabInstanceBufferPool
    let binding: DepositionPipelineBinding
    let material: DepositionMaterialBinding
    let target: any MTLTexture
    var encoder: DepositionEncoder
}
