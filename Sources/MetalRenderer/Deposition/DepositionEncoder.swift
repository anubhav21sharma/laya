import CShaderTypes
import Metal
import PatternEngine

package struct DepositionEncodingOutcome: Equatable, Sendable {
    let instanceCount: Int
    let uploadCount: Int
    let textureLevelRange: ClosedRange<Int>?
    let selectedTipLevelOfDetailRange: ClosedRange<Float>?

    init(
        instanceCount: Int,
        uploadCount: Int,
        textureLevelRange: ClosedRange<Int>?,
        selectedTipLevelOfDetailRange: ClosedRange<Float>? = nil
    ) {
        self.instanceCount = instanceCount
        self.uploadCount = uploadCount
        self.textureLevelRange = textureLevelRange
        self.selectedTipLevelOfDetailRange = selectedTipLevelOfDetailRange
    }
}

enum DepositionInstanceValidationError: Error, Equatable, Sendable {
    case nonfiniteField(String)
    case invalidRadius
    case tooManyClipPlanes(Int)
    case unsupportedABI(UInt16)
}

enum DepositionEncodingError: Error, Equatable, Sendable {
    case integerOverflow
    case invalidCapacity(Int)
    case recordLimitExceeded(actual: Int, maximum: Int)
    case uploadLimitExceeded(actual: Int, maximum: Int)
    case uploadBuffersUnavailable(required: Int)
    case unsupportedPipelineABI(UInt16)
    case unsupportedPipelineBackend(BrushBackendKind)
    case invalidPipelinePixelFormat(UInt)
    case targetPixelFormatMismatch(expected: UInt, actual: UInt)
    case targetSampleCountMismatch(expected: Int, actual: Int)
    case targetIsNotRenderTarget
    case targetChangedAfterPreflight
    case missingTexture(DepositionTextureSlot)
    case invalidComponentBindingOrdinal(expected: UInt8, actual: UInt8)
    case componentBindingUnavailable(UInt8)
    case invalidMaterialUniform(String)
    case invalidInstance(
        identity: UInt64,
        reason: DepositionInstanceValidationError
    )
    case commandBufferUnavailable
    case componentCoverageTextureUnavailable
    case renderEncoderUnavailable
    case preparationAlreadyFinalized
    case foreignPreparation
}

@MainActor
struct DepositionComponentBinding {
    let ordinal: UInt8
    let pipeline: DepositionPipelineBinding
    let material: DepositionMaterialBinding

    init(
        ordinal: UInt8,
        pipeline: DepositionPipelineBinding,
        material: DepositionMaterialBinding
    ) {
        self.ordinal = ordinal
        self.pipeline = pipeline
        self.material = material
    }
}

@MainActor
package final class PreparedDepositionEncoding {
    struct Chunk {
        let lease: DabInstanceBufferPool.Lease
        let count: Int
        let recordRange: Range<Int>
    }

    let instanceCount: Int
    let uploadCount: Int
    let textureLevelRange: ClosedRange<Int>?
    let selectedTipLevelOfDetailRange: ClosedRange<Float>?
    let bindingRunCount: Int
    private(set) var chunks: [Chunk]

    var componentOrdinals: [UInt8] {
        records.map(\.componentOrdinal)
    }

    fileprivate let primary: DepositionComponentBinding
    fileprivate let secondary: DepositionComponentBinding?
    fileprivate let records: [ProjectedDepositionRecord]
    fileprivate let pool: DabInstanceBufferPool
    fileprivate let poolIdentity: ObjectIdentifier
    fileprivate let targetIdentity: ObjectIdentifier?
    fileprivate var isFinalized = false

    fileprivate init(
        instanceCount: Int,
        chunks: [Chunk],
        textureLevelRange: ClosedRange<Int>?,
        selectedTipLevelOfDetailRange: ClosedRange<Float>?,
        primary: DepositionComponentBinding,
        secondary: DepositionComponentBinding?,
        records: [ProjectedDepositionRecord],
        pool: DabInstanceBufferPool,
        targetIdentity: ObjectIdentifier?
    ) {
        self.instanceCount = instanceCount
        uploadCount = chunks.count
        self.chunks = chunks
        self.textureLevelRange = textureLevelRange
        self.selectedTipLevelOfDetailRange = selectedTipLevelOfDetailRange
        bindingRunCount = Self.bindingRunCount(records)
        self.primary = primary
        self.secondary = secondary
        self.records = records
        self.pool = pool
        poolIdentity = ObjectIdentifier(pool)
        self.targetIdentity = targetIdentity
    }

    private static func bindingRunCount(
        _ records: [ProjectedDepositionRecord]
    ) -> Int {
        var count = 0
        var previous: UInt8?
        for record in records where record.componentOrdinal != previous {
            count += 1
            previous = record.componentOrdinal
        }
        return count
    }

    isolated deinit {
        guard !isFinalized else { return }
        for chunk in chunks {
            pool.abandon(chunk.lease)
        }
    }

    fileprivate func takeChunks() throws -> [Chunk] {
        guard !isFinalized else {
            throw DepositionEncodingError.preparationAlreadyFinalized
        }
        isFinalized = true
        let result = chunks
        chunks.removeAll(keepingCapacity: false)
        return result
    }

    fileprivate func takeChunksForAbandon() -> [Chunk]? {
        guard !isFinalized else { return nil }
        isFinalized = true
        let result = chunks
        chunks.removeAll(keepingCapacity: false)
        return result
    }
}

@MainActor
package struct DepositionEncoder {
    private let instancePool: DabInstanceBufferPool
    private var frameUniforms: PatternGridFrameUniforms
    private let maximumRecordCount: Int
    private let maximumUploadCount: Int
    private let makeRenderEncoder:
        (any MTLCommandBuffer, MTLRenderPassDescriptor)
            -> (any MTLRenderCommandEncoder)?

    package init(
        instancePool: DabInstanceBufferPool,
        frameUniforms: PatternGridFrameUniforms,
        maximumRecordCount: Int = GridCanvasContract.pendingCapacity,
        maximumUploadCount: Int = GridCanvasContract.inFlightBufferCount,
        makeRenderEncoder:
            @escaping (
                any MTLCommandBuffer,
                MTLRenderPassDescriptor
            ) -> (any MTLRenderCommandEncoder)? = {
                commandBuffer,
                descriptor in
                commandBuffer.makeRenderCommandEncoder(
                    descriptor: descriptor
                )
            }
    ) {
        precondition(maximumRecordCount > 0)
        precondition(maximumUploadCount > 0)
        self.instancePool = instancePool
        self.frameUniforms = frameUniforms
        self.maximumRecordCount = maximumRecordCount
        self.maximumUploadCount = maximumUploadCount
        self.makeRenderEncoder = makeRenderEncoder
    }

    mutating func updateFrameUniforms(
        _ frameUniforms: PatternGridFrameUniforms
    ) {
        self.frameUniforms = frameUniforms
    }

    package mutating func preflight(
        records: [ProjectedDepositionRecord],
        binding: DepositionPipelineBinding,
        material: DepositionMaterialBinding
    ) throws -> PreparedDepositionEncoding {
        try preflight(
            records: records,
            primary: DepositionComponentBinding(
                ordinal: 0,
                pipeline: binding,
                material: material
            ),
            secondary: nil,
            target: nil
        )
    }

    package mutating func preflight(
        records: [ProjectedDepositionRecord],
        binding: DepositionPipelineBinding,
        material: DepositionMaterialBinding,
        target: (any MTLTexture)?
    ) throws -> PreparedDepositionEncoding {
        try preflight(
            records: records,
            primary: DepositionComponentBinding(
                ordinal: 0,
                pipeline: binding,
                material: material
            ),
            secondary: nil,
            target: target
        )
    }

    mutating func preflight(
        records: [ProjectedDepositionRecord],
        primary: DepositionComponentBinding,
        secondary: DepositionComponentBinding?,
        target: (any MTLTexture)?
    ) throws -> PreparedDepositionEncoding {
        guard primary.ordinal == 0 else {
            throw DepositionEncodingError.invalidComponentBindingOrdinal(
                expected: 0,
                actual: primary.ordinal
            )
        }
        if let secondary, secondary.ordinal != 1 {
            throw DepositionEncodingError.invalidComponentBindingOrdinal(
                expected: 1,
                actual: secondary.ordinal
            )
        }
        try validate(primary)
        if let secondary { try validate(secondary) }
        if let target {
            try validateTarget(target, for: primary.pipeline.key)
            if let secondary {
                try validateTarget(target, for: secondary.pipeline.key)
            }
        }
        guard records.count <= maximumRecordCount else {
            throw DepositionEncodingError.recordLimitExceeded(
                actual: records.count,
                maximum: maximumRecordCount
            )
        }
        for record in records {
            try validate(record)
            _ = try componentBinding(
                ordinal: record.componentOrdinal,
                primary: primary,
                secondary: secondary
            )
        }

        let textureLevels = textureLevelRange(
            primary: primary,
            secondary: secondary
        )
        let selectedTipLevels = selectedTipLevelOfDetailRange(
            records: records,
            primary: primary,
            secondary: secondary
        )

        let uploadCount = try Self.requiredChunkCount(
            recordCount: records.count,
            capacity: instancePool.capacity
        )
        let allowedUploadCount = min(
            maximumUploadCount,
            instancePool.maximumLeaseCount
        )
        guard uploadCount <= allowedUploadCount else {
            throw DepositionEncodingError.uploadLimitExceeded(
                actual: uploadCount,
                maximum: allowedUploadCount
            )
        }
        guard let leases = instancePool.acquire(count: uploadCount) else {
            throw DepositionEncodingError.uploadBuffersUnavailable(
                required: uploadCount
            )
        }

        var chunks: [PreparedDepositionEncoding.Chunk] = []
        chunks.reserveCapacity(uploadCount)
        var cursor = records.startIndex
        for lease in leases {
            let end = min(cursor + lease.capacity, records.endIndex)
            let range = cursor..<end
            instancePool.write(records[range], into: lease)
            chunks.append(
                PreparedDepositionEncoding.Chunk(
                    lease: lease,
                    count: range.count,
                    recordRange: range
                )
            )
            cursor = end
        }
        precondition(cursor == records.endIndex)

        return PreparedDepositionEncoding(
            instanceCount: records.count,
            chunks: chunks,
            textureLevelRange: textureLevels,
            selectedTipLevelOfDetailRange: selectedTipLevels,
            primary: primary,
            secondary: secondary,
            records: records,
            pool: instancePool,
            targetIdentity: target.map {
                ObjectIdentifier($0 as AnyObject)
            }
        )
    }

    package mutating func encode(
        _ prepared: PreparedDepositionEncoding,
        into target: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws -> DepositionEncodingOutcome {
        try encode(
            prepared,
            into: target,
            optionalCommandBuffer: commandBuffer
        )
    }

    mutating func encode(
        _ prepared: PreparedDepositionEncoding,
        into target: any MTLTexture,
        optionalCommandBuffer: (any MTLCommandBuffer)?
    ) throws -> DepositionEncodingOutcome {
        guard prepared.poolIdentity == ObjectIdentifier(instancePool) else {
            throw DepositionEncodingError.foreignPreparation
        }
        let chunks = try prepared.takeChunks()
        do {
            try validateTarget(target, for: prepared.primary.pipeline.key)
            if let secondary = prepared.secondary {
                try validateTarget(target, for: secondary.pipeline.key)
            }
            if let expected = prepared.targetIdentity,
               expected != ObjectIdentifier(target as AnyObject)
            {
                throw DepositionEncodingError.targetChangedAfterPreflight
            }
            guard !chunks.isEmpty else {
                return outcome(for: prepared)
            }
            guard let commandBuffer = optionalCommandBuffer else {
                throw DepositionEncodingError.commandBufferUnavailable
            }

            let pass = MTLRenderPassDescriptor()
            guard let color = pass.colorAttachments[0] else {
                throw DepositionEncodingError.renderEncoderUnavailable
            }
            guard let componentCoverage = commandBuffer.commandQueue.device
                .makeTexture(
                    descriptor: DepositionComponentCoverage.textureDescriptor(
                        width: target.width,
                        height: target.height
                    )
                ),
                let coverageAttachment = pass.colorAttachments[1]
            else {
                throw DepositionEncodingError
                    .componentCoverageTextureUnavailable
            }
            color.texture = target
            color.loadAction = .load
            color.storeAction = .store
            coverageAttachment.texture = componentCoverage
            coverageAttachment.loadAction = .clear
            coverageAttachment.storeAction = .dontCare
            coverageAttachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
            guard let encoder = makeRenderEncoder(commandBuffer, pass) else {
                throw DepositionEncodingError.renderEncoderUnavailable
            }
            encoder.label = "Brush Deposition"
            var frame = frameUniforms
            encoder.setVertexBytes(
                &frame,
                length: MemoryLayout<PatternGridFrameUniforms>.stride,
                index: Int(PatternBufferIndexGridFrameUniforms)
            )
            var boundOrdinal: UInt8?
            for chunk in chunks {
                var runStart = chunk.recordRange.lowerBound
                while runStart < chunk.recordRange.upperBound {
                    let ordinal = prepared.records[runStart]
                        .componentOrdinal
                    var runEnd = runStart + 1
                    while runEnd < chunk.recordRange.upperBound,
                          prepared.records[runEnd].componentOrdinal
                            == ordinal
                    {
                        runEnd += 1
                    }
                    let binding = try componentBinding(
                        ordinal: ordinal,
                        primary: prepared.primary,
                        secondary: prepared.secondary
                    )
                    if boundOrdinal != ordinal {
                        bind(binding, to: encoder)
                        boundOrdinal = ordinal
                    }
                    encoder.setVertexBuffer(
                        chunk.lease.buffer,
                        offset: (runStart - chunk.recordRange.lowerBound)
                            * MemoryLayout<
                                PatternDepositionStampInstance
                            >.stride,
                        index: Int(PatternBufferIndexDabInstances)
                    )
                    encoder.drawPrimitives(
                        type: .triangle,
                        vertexStart: 0,
                        vertexCount: 6,
                        instanceCount: runEnd - runStart
                    )
                    runStart = runEnd
                }
            }
            encoder.endEncoding()

            let submissions = chunks.map {
                instancePool.submit($0.lease, on: commandBuffer)
            }
            let pool = instancePool
            commandBuffer.addCompletedHandler { completed in
                guard completed.status != .completed else { return }
                Task { @MainActor [pool] in
                    pool.reclaimTerminalFailure(submissions)
                }
            }
            return outcome(for: prepared)
        } catch {
            for chunk in chunks {
                instancePool.abandon(chunk.lease)
            }
            throw error
        }
    }

    mutating func abandon(_ prepared: PreparedDepositionEncoding) {
        guard prepared.poolIdentity == ObjectIdentifier(instancePool),
              let chunks = prepared.takeChunksForAbandon()
        else {
            return
        }
        for chunk in chunks {
            instancePool.abandon(chunk.lease)
        }
    }

    static func requiredChunkCount(
        recordCount: Int,
        capacity: Int
    ) throws -> Int {
        guard recordCount >= 0, capacity > 0 else {
            throw DepositionEncodingError.invalidCapacity(capacity)
        }
        guard recordCount > 0 else { return 0 }
        let (adjusted, overflow) = recordCount.addingReportingOverflow(
            capacity - 1
        )
        guard !overflow else {
            throw DepositionEncodingError.integerOverflow
        }
        return adjusted / capacity
    }

    private func outcome(
        for prepared: PreparedDepositionEncoding
    ) -> DepositionEncodingOutcome {
        DepositionEncodingOutcome(
            instanceCount: prepared.instanceCount,
            uploadCount: prepared.uploadCount,
            textureLevelRange: prepared.textureLevelRange,
            selectedTipLevelOfDetailRange:
                prepared.selectedTipLevelOfDetailRange
        )
    }

    private func validatePipeline(
        _ binding: DepositionPipelineBinding
    ) throws {
        let key = binding.key
        guard key.abiVersion == DepositionABI.version else {
            throw DepositionEncodingError.unsupportedPipelineABI(
                key.abiVersion
            )
        }
        guard key.brush.backend == .deposition else {
            throw DepositionEncodingError.unsupportedPipelineBackend(
                key.brush.backend
            )
        }
        guard key.colorPixelFormatRawValue
                == DocumentColorPipeline.workingPixelFormat.rawValue
        else {
            throw DepositionEncodingError.invalidPipelinePixelFormat(
                key.colorPixelFormatRawValue
            )
        }
    }

    private func validate(
        _ component: DepositionComponentBinding
    ) throws {
        try validatePipeline(component.pipeline)
        try validateMaterial(
            component.material,
            for: component.pipeline.key.brush
        )
    }

    private func componentBinding(
        ordinal: UInt8,
        primary: DepositionComponentBinding,
        secondary: DepositionComponentBinding?
    ) throws -> DepositionComponentBinding {
        if ordinal == primary.ordinal { return primary }
        if let secondary, ordinal == secondary.ordinal {
            return secondary
        }
        throw DepositionEncodingError.componentBindingUnavailable(ordinal)
    }

    private func bind(
        _ component: DepositionComponentBinding,
        to encoder: any MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(component.pipeline.state)
        var materialUniforms = component.material.uniforms
        materialUniforms.edgeParameters.y = Float(component.ordinal)
        encoder.setFragmentBytes(
            &materialUniforms,
            length: MemoryLayout<
                PatternDepositionMaterialUniforms
            >.stride,
            index: Int(PatternBufferIndexBrushMaterial)
        )
        for slot in DepositionTextureSlot.allCases {
            encoder.setFragmentTexture(
                component.material.textures[slot],
                index: slot.rawValue
            )
        }
    }

    private func validateTarget(
        _ target: any MTLTexture,
        for key: DepositionPipelineKey
    ) throws {
        guard target.pixelFormat.rawValue == key.colorPixelFormatRawValue else {
            throw DepositionEncodingError.targetPixelFormatMismatch(
                expected: key.colorPixelFormatRawValue,
                actual: target.pixelFormat.rawValue
            )
        }
        guard target.sampleCount == key.sampleCount else {
            throw DepositionEncodingError.targetSampleCountMismatch(
                expected: key.sampleCount,
                actual: target.sampleCount
            )
        }
        guard target.usage.contains(.renderTarget) else {
            throw DepositionEncodingError.targetIsNotRenderTarget
        }
    }

    private func validateMaterial(
        _ material: DepositionMaterialBinding,
        for key: BrushPipelineKey
    ) throws {
        let required: [(Bool, DepositionTextureSlot)] = [
            (
                material.uniforms.options.z
                    == PatternDepositionShapeKindTexture,
                .primaryShape
            ),
            (
                key.functionConstants.usesSecondaryShape
                    && material.uniforms.options.w
                        == PatternDepositionShapeKindTexture,
                .secondaryShape
            ),
            (key.functionConstants.usesGrain, .primaryGrain),
            (key.functionConstants.usesSecondaryGrain, .secondaryGrain),
        ]
        for (isRequired, slot) in required
        where isRequired && material.textures[slot] == nil {
            throw DepositionEncodingError.missingTexture(slot)
        }
        for (name, value) in [
            (
                "coverageParameters",
                material.uniforms.coverageParameters
            ),
            (
                "secondaryShapeTransform",
                material.uniforms.secondaryShapeTransform
            ),
            ("edgeParameters", material.uniforms.edgeParameters),
        ] where !Self.isFinite(value) {
            throw DepositionEncodingError.invalidMaterialUniform(name)
        }
    }

    private func validate(_ record: ProjectedDepositionRecord) throws {
        let instance = record.instance
        for (name, value) in [
            ("tipFrame0", instance.tipFrame0),
            ("tipFrame1", instance.tipFrame1),
            ("primaryGrainFrame0", instance.primaryGrainFrame0),
            ("primaryGrainFrame1", instance.primaryGrainFrame1),
            ("secondaryGrainFrame0", instance.secondaryGrainFrame0),
            ("secondaryGrainFrame1", instance.secondaryGrainFrame1),
            ("premultipliedColor", instance.premultipliedColor),
            ("coverageInputs", instance.coverageInputs),
            ("reserved0", instance.reserved0),
            ("reserved1", instance.reserved1),
        ] where !Self.isFinite(value) {
            throw invalid(
                record,
                reason: .nonfiniteField(name)
            )
        }
        for (name, clip) in [
            ("clip0", instance.clip0),
            ("clip1", instance.clip1),
            ("clip2", instance.clip2),
            ("clip3", instance.clip3),
        ] where !Self.isFinite(clip) {
            throw invalid(
                record,
                reason: .nonfiniteField(name)
            )
        }
        guard instance.tipFrame1.z > 0 else {
            throw invalid(record, reason: .invalidRadius)
        }
        guard instance.metadata.x
            <= UInt32(DepositionStampPacker.maximumClipPlaneCount)
        else {
            throw invalid(
                record,
                reason: .tooManyClipPlanes(Int(instance.metadata.x))
            )
        }
        guard instance.metadata.w == UInt32(DepositionABI.version) else {
            throw invalid(
                record,
                reason: .unsupportedABI(
                    UInt16(truncatingIfNeeded: instance.metadata.w)
                )
            )
        }
    }

    private func invalid(
        _ record: ProjectedDepositionRecord,
        reason: DepositionInstanceValidationError
    ) -> DepositionEncodingError {
        .invalidInstance(identity: record.identity, reason: reason)
    }

    private func textureLevelRange(
        primary: DepositionComponentBinding,
        secondary: DepositionComponentBinding?
    ) -> ClosedRange<Int>? {
        var maximum: Int?
        func absorb(_ material: DepositionMaterialBinding) {
            for slot in material.textures.boundSlots {
                guard let levels = material.textures[slot]?.mipmapLevelCount
                else { continue }
                maximum = max(maximum ?? 0, levels)
            }
        }
        absorb(primary.material)
        if let secondary { absorb(secondary.material) }
        guard let maximum, maximum > 0 else { return nil }
        return 0...(maximum - 1)
    }

    private func selectedTipLevelOfDetailRange(
        records: [ProjectedDepositionRecord],
        primary: DepositionComponentBinding,
        secondary: DepositionComponentBinding?
    ) -> ClosedRange<Float>? {
        guard !records.isEmpty else { return nil }
        var minimum = Float.infinity
        var maximum = -Float.infinity
        for record in records {
            let material: DepositionMaterialBinding
            if record.componentOrdinal == primary.ordinal {
                material = primary.material
            } else if let secondary,
                      record.componentOrdinal == secondary.ordinal
            {
                material = secondary.material
            } else { continue }
            let instance = record.instance
            let primaryXAxis = SIMD2(
                instance.tipFrame0.x,
                instance.tipFrame0.y
            )
            let primaryYAxis = SIMD2(
                instance.tipFrame0.z,
                instance.tipFrame0.w
            )
            for (index, support) in material.tipSupports.enumerated() {
                let xAxis: SIMD2<Float>
                let yAxis: SIMD2<Float>
                if index == 0 {
                    xAxis = primaryXAxis
                    yAxis = primaryYAxis
                } else {
                    let transform = material.uniforms.secondaryShapeTransform
                    let cosine = cos(transform.y)
                    let sine = sin(transform.y)
                    xAxis = transform.x * (
                        cosine * primaryXAxis + sine * primaryYAxis
                    )
                    yAxis = transform.x * (
                        -sine * primaryXAxis + cosine * primaryYAxis
                    )
                }
                guard let lod = support.levelOfDetail(
                    projectedWidth: 2 * hypot(xAxis.x, xAxis.y),
                    projectedHeight: 2 * hypot(yAxis.x, yAxis.y)
                ) else {
                    continue
                }
                minimum = min(minimum, lod)
                maximum = max(maximum, lod)
            }
        }
        guard minimum.isFinite, maximum.isFinite else { return nil }
        return minimum...maximum
    }

    private static func isFinite(_ value: SIMD4<Float>) -> Bool {
        value.x.isFinite
            && value.y.isFinite
            && value.z.isFinite
            && value.w.isFinite
    }

    private static func isFinite(_ value: PatternClipHalfPlane) -> Bool {
        value.normal.x.isFinite
            && value.normal.y.isFinite
            && value.offset.isFinite
            && value.padding.isFinite
    }
}
