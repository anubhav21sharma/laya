import CShaderTypes
import Foundation
import Metal
import PatternEngine

enum DocumentPaintSurfaceMetalBackendFailurePoint:
    Hashable, Sendable
{
    case metadataAllocation
    case commandBuffer
    case reductionBuffer
    case importBuffer
    case encoder
    case precommit
    case gpu
    case complete
    case discard
}

final class DocumentPaintSurfaceMetalBackendFailureInjection:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var remaining: [DocumentPaintSurfaceMetalBackendFailurePoint: Int]

    init(
        failingOnceAt point: DocumentPaintSurfaceMetalBackendFailurePoint
    ) {
        remaining = [point: 1]
    }

    init(
        failures: [DocumentPaintSurfaceMetalBackendFailurePoint: Int]
    ) {
        remaining = failures
    }

    func consume(
        _ point: DocumentPaintSurfaceMetalBackendFailurePoint
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let count = remaining[point], count > 0 else { return false }
        if count == 1 {
            remaining.removeValue(forKey: point)
        } else {
            remaining[point] = count - 1
        }
        return true
    }
}

enum DocumentPaintSurfaceMetalBackendError:
    Error, Equatable, Sendable
{
    case invalidShaderABI
    case invalidOperation
    case unsupportedRestore
    case resourceDeviceMismatch
    case invalidTexture
    case textureAlias
    case metadataAllocationFailed
    case commandBufferUnavailable
    case reductionBufferAllocationFailed
    case importBufferAllocationFailed
    case encoderUnavailable
    case precommitFailed
    case gpuCommandFailed
    case commandNotTerminal(Int)
    case outcomeMismatch(
        requested: RasterRevisionOperationOutcome,
        actual: RasterRevisionOperationOutcome
    )
    case completionFailed
    case discardFailed
    case foreignToken
    case tokenAlreadyConsumed
    case tokenSequenceOverflow
}

struct DocumentPaintSurfaceMetalBackendDebugSnapshot:
    Equatable, Sendable
{
    let commandBufferCount: Int
    let reductionBufferCount: Int
    let importBufferCount: Int
    let encoderCount: Int
    let committedCommandBufferCount: Int
    let activeTokenCount: Int
    let activeCommandBufferCount: Int
    let activeRetainedTextureCount: Int
    let activeReductionBufferCount: Int
    let activeImportBufferCount: Int
}

final class DocumentPaintSurfaceMetalBackend:
    DocumentPaintSurfaceMutationBackend, @unchecked Sendable
{
    private struct EvidenceMetadata: Sendable {
        let coordinate: PaintTileCoordinate
        let logicalBounds: PixelRect
        let reductionOffset: Int
    }

    private struct RetainedResources: @unchecked Sendable {
        let textures: [any MTLTexture]
        let reduction: (any MTLBuffer)?
        let importSource: (any MTLBuffer)?
    }

    private final class ActiveEncoding: @unchecked Sendable {
        let commandBuffer: (any MTLCommandBuffer)?
        let evidence: [EvidenceMetadata]
        let resources: RetainedResources
        let injectsGPUFailure: Bool

        init(
            commandBuffer: (any MTLCommandBuffer)?,
            evidence: [EvidenceMetadata],
            resources: RetainedResources,
            injectsGPUFailure: Bool
        ) {
            self.commandBuffer = commandBuffer
            self.evidence = evidence
            self.resources = resources
            self.injectsGPUFailure = injectsGPUFailure
        }
    }

    private struct Counters {
        var commandBuffers = 0
        var reductionBuffers = 0
        var importBuffers = 0
        var encoders = 0
        var commits = 0
    }

    private let identity = UUID()
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipelines: DocumentPaintSurfaceMutationPipelineBinding
    private let failureInjection:
        DocumentPaintSurfaceMetalBackendFailureInjection?
    private let lock = NSLock()
    private var active: [DocumentPaintSurfaceMutationBackendEncoding:
        ActiveEncoding] = [:]
    private var nextSequence: UInt64 = 1
    private var counters = Counters()

    @MainActor
    init(
        device: any MTLDevice,
        commandQueue: any MTLCommandQueue,
        pipelines: DocumentPaintSurfaceMutationPipelineBinding,
        failureInjection:
            DocumentPaintSurfaceMetalBackendFailureInjection? = nil
    ) throws {
        guard ShaderABI.isValid else {
            throw DocumentPaintSurfaceMetalBackendError.invalidShaderABI
        }
        guard Self.sameDevice(device, commandQueue.device),
              Self.sameDevice(device, pipelines.stroke.device),
              Self.sameDevice(device, pipelines.resize.device),
              Self.sameDevice(device, pipelines.encodedImport.device)
        else {
            throw DocumentPaintSurfaceMetalBackendError
                .resourceDeviceMismatch
        }
        self.device = device
        self.commandQueue = commandQueue
        self.pipelines = pipelines
        self.failureInjection = failureInjection
    }

    var debugSnapshot: DocumentPaintSurfaceMetalBackendDebugSnapshot {
        withLock {
            DocumentPaintSurfaceMetalBackendDebugSnapshot(
                commandBufferCount: counters.commandBuffers,
                reductionBufferCount: counters.reductionBuffers,
                importBufferCount: counters.importBuffers,
                encoderCount: counters.encoders,
                committedCommandBufferCount: counters.commits,
                activeTokenCount: active.count,
                activeCommandBufferCount: active.values.reduce(0) {
                    $0 + ($1.commandBuffer == nil ? 0 : 1)
                },
                activeRetainedTextureCount: active.values.reduce(0) {
                    $0 + $1.resources.textures.count
                },
                activeReductionBufferCount: active.values.reduce(0) {
                    $0 + ($1.resources.reduction == nil ? 0 : 1)
                },
                activeImportBufferCount: active.values.reduce(0) {
                    $0 + ($1.resources.importSource == nil ? 0 : 1)
                }
            )
        }
    }

    func preflight(_ operation: DocumentPaintSurfaceBackendOperation) throws {
        switch operation {
        case .clear:
            return
        case let .restore(payload):
            try validateRestore(payload)
        case let .stroke(payload):
            try validateStroke(payload)
        case let .resize(payload):
            try validateResize(payload)
        case let .encodedImport(payload):
            try validateEncodedImport(payload)
        }
    }

    func encode(
        _ operation: DocumentPaintSurfaceBackendOperation
    ) throws -> DocumentPaintSurfaceMutationBackendEncoding {
        try preflight(operation)
        if case .clear = operation {
            return try makeTerminalEncoding()
        }
        if case .restore = operation {
            throw DocumentPaintSurfaceMetalBackendError.unsupportedRestore
        }
        switch operation {
        case let .resize(payload) where payload.destinations.isEmpty:
            return try makeTerminalEncoding()
        case let .encodedImport(payload) where payload.destinations.isEmpty:
            return try makeTerminalEncoding()
        default:
            break
        }
        if failureInjection?.consume(.metadataAllocation) == true {
            throw DocumentPaintSurfaceMetalBackendError
                .metadataAllocationFailed
        }

        if failureInjection?.consume(.commandBuffer) == true {
            throw DocumentPaintSurfaceMetalBackendError
                .commandBufferUnavailable
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw DocumentPaintSurfaceMetalBackendError
                .commandBufferUnavailable
        }
        increment { $0.commandBuffers += 1 }

        let destinationCount = Self.destinations(for: operation).count
        let reductionLength: Int
        let (computedLength, reductionOverflow) = destinationCount
            .multipliedReportingOverflow(
                by: MemoryLayout<PatternDocumentPaintMutationReduction>.stride
            )
        guard !reductionOverflow else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        reductionLength = computedLength
        if failureInjection?.consume(.reductionBuffer) == true {
            throw DocumentPaintSurfaceMetalBackendError
                .reductionBufferAllocationFailed
        }
        guard let reduction = device.makeBuffer(
            length: reductionLength,
            options: .storageModeShared
        ) else {
            throw DocumentPaintSurfaceMetalBackendError
                .reductionBufferAllocationFailed
        }
        memset(reduction.contents(), 0, reductionLength)
        increment { $0.reductionBuffers += 1 }

        let importSource: (any MTLBuffer)?
        if case let .encodedImport(payload) = operation {
            if failureInjection?.consume(.importBuffer) == true {
                throw DocumentPaintSurfaceMetalBackendError
                    .importBufferAllocationFailed
            }
            importSource = payload.encodedPremultipliedBGRA8.withUnsafeBytes {
                bytes in
                guard let baseAddress = bytes.baseAddress else { return nil }
                return device.makeBuffer(
                    bytes: baseAddress,
                    length: bytes.count,
                    options: .storageModeShared
                )
            }
            guard importSource != nil else {
                throw DocumentPaintSurfaceMetalBackendError
                    .importBufferAllocationFailed
            }
            increment { $0.importBuffers += 1 }
        } else {
            importSource = nil
        }

        if failureInjection?.consume(.encoder) == true {
            throw DocumentPaintSurfaceMetalBackendError.encoderUnavailable
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw DocumentPaintSurfaceMetalBackendError.encoderUnavailable
        }
        increment { $0.encoders += 1 }
        let encoded: (
            evidence: [EvidenceMetadata],
            retainedTextures: [any MTLTexture]
        )
        do {
            encoded = try encode(
                operation,
                encoder: encoder,
                reduction: reduction,
                importSource: importSource
            )
            encoder.endEncoding()
        } catch {
            encoder.endEncoding()
            throw error
        }

        if failureInjection?.consume(.precommit) == true {
            throw DocumentPaintSurfaceMetalBackendError.precommitFailed
        }
        let token = try makeToken()
        let record = ActiveEncoding(
            commandBuffer: commandBuffer,
            evidence: encoded.evidence,
            resources: RetainedResources(
                textures: encoded.retainedTextures,
                reduction: reduction,
                importSource: importSource
            ),
            injectsGPUFailure: failureInjection?.consume(.gpu) == true
        )
        commandBuffer.commit()
        increment { $0.commits += 1 }
        register(token, record: record)
        return token
    }

    func complete(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding,
        as outcome: RasterRevisionOperationOutcome
    ) throws -> [DocumentPaintSurfaceMutationEvidence] {
        try withLock {
            let record = try activeRecord(for: encoding)
            record.commandBuffer?.waitUntilCompleted()
            if record.commandBuffer != nil,
               failureInjection?.consume(.complete) == true
            {
                throw DocumentPaintSurfaceMetalBackendError.completionFailed
            }
            guard outcome == .succeeded else {
                consume(encoding)
                return []
            }
            if record.injectsGPUFailure {
                throw DocumentPaintSurfaceMetalBackendError.gpuCommandFailed
            }
            let actual = try actualOutcome(for: record)
            guard actual == outcome else {
                throw DocumentPaintSurfaceMetalBackendError.outcomeMismatch(
                    requested: outcome,
                    actual: actual
                )
            }
            let evidence = actual == .succeeded
                ? Self.evidence(from: record)
                : []
            consume(encoding)
            return evidence
        }
    }

    func discardAndWaitUntilTerminal(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) throws {
        try withLock {
            let record = try activeRecord(for: encoding)
            record.commandBuffer?.waitUntilCompleted()
            if record.commandBuffer != nil,
               failureInjection?.consume(.discard) == true
            {
                throw DocumentPaintSurfaceMetalBackendError.discardFailed
            }
            consume(encoding)
        }
    }

    private func encode(
        _ operation: DocumentPaintSurfaceBackendOperation,
        encoder: any MTLComputeCommandEncoder,
        reduction: any MTLBuffer,
        importSource: (any MTLBuffer)?
    ) throws -> (
        evidence: [EvidenceMetadata],
        retainedTextures: [any MTLTexture]
    ) {
        switch operation {
        case .clear, .restore:
            preconditionFailure("Non-GPU operation reached mutation encoder")
        case let .stroke(payload):
            return encodeStroke(
                payload,
                encoder: encoder,
                reduction: reduction
            )
        case let .resize(payload):
            return try encodeResize(
                payload,
                encoder: encoder,
                reduction: reduction
            )
        case let .encodedImport(payload):
            guard let importSource else {
                preconditionFailure("Validated import lost source buffer")
            }
            return encodeImport(
                payload,
                encoder: encoder,
                reduction: reduction,
                importSource: importSource
            )
        }
    }

    private func encodeStroke(
        _ payload: DocumentPaintSurfaceStrokeBackendPayload,
        encoder: any MTLComputeCommandEncoder,
        reduction: any MTLBuffer
    ) -> (
        evidence: [EvidenceMetadata],
        retainedTextures: [any MTLTexture]
    ) {
        encoder.setComputePipelineState(pipelines.stroke)
        var evidence: [EvidenceMetadata] = []
        var retained: [any MTLTexture] = []
        evidence.reserveCapacity(payload.destinations.count)
        retained.reserveCapacity(payload.destinations.count * 3)
        for index in payload.destinations.indices {
            let base = payload.baseSources[index]
            let authoritative = payload.authoritativeSources[index]
            let destination = payload.destinations[index]
            var uniforms = Self.uniforms(
                for: destination,
                composite: payload.compositeParameters
            )
            let baseTexture = Self.texture(from: base)
            let authoritativeTexture = Self.texture(from: authoritative)
            if baseTexture == nil {
                uniforms.flags |= PatternDocumentPaintFlagBaseKnownClear
            }
            if authoritativeTexture == nil {
                uniforms.flags |=
                    PatternDocumentPaintFlagAuthoritativeKnownClear
            }
            set(
                uniforms,
                reduction: reduction,
                reductionOffset: index * 8,
                encoder: encoder
            )
            encoder.setTexture(
                baseTexture,
                index: Int(PatternTextureIndexDocumentPaintBase)
            )
            encoder.setTexture(
                authoritativeTexture,
                index: Int(PatternTextureIndexDocumentPaintAuthoritative)
            )
            encoder.setTexture(
                destination.texture,
                index: Int(PatternTextureIndexDocumentPaintDestination)
            )
            dispatch(encoder)
            evidence.append(EvidenceMetadata(
                coordinate: destination.coordinate,
                logicalBounds: destination.logicalBounds,
                reductionOffset: index * 8
            ))
            if let baseTexture { retained.append(baseTexture) }
            if let authoritativeTexture { retained.append(authoritativeTexture) }
            retained.append(destination.texture)
        }
        return (evidence, retained)
    }

    private func encodeResize(
        _ payload: DocumentPaintSurfaceResizeBackendPayload,
        encoder: any MTLComputeCommandEncoder,
        reduction: any MTLBuffer
    ) throws -> (
        evidence: [EvidenceMetadata],
        retainedTextures: [any MTLTexture]
    ) {
        encoder.setComputePipelineState(pipelines.resize)
        let targetRadial = try Self.radialUniforms(for: payload)
        let sources = Dictionary(
            uniqueKeysWithValues: payload.sources.map { ($0.coordinate, $0) }
        )
        let destinations = Dictionary(
            uniqueKeysWithValues: payload.destinations.map {
                ($0.coordinate, $0)
            }
        )
        var evidence: [EvidenceMetadata] = []
        var retained: [any MTLTexture] = []
        evidence.reserveCapacity(payload.mappings.count)
        retained.reserveCapacity(payload.mappings.count * 2)
        for (index, mapping) in payload.mappings.enumerated() {
            let source = sources[mapping.sourceCoordinate]!
            let destination = destinations[mapping.destinationCoordinate]!
            var uniforms = Self.uniforms(for: destination)
            uniforms.sourceOrigin = SIMD2(
                UInt32(mapping.sourceOrigin.x),
                UInt32(mapping.sourceOrigin.y)
            )
            uniforms.destinationOrigin = SIMD2(
                UInt32(mapping.destinationOrigin.x),
                UInt32(mapping.destinationOrigin.y)
            )
            uniforms.copyExtent = SIMD2(
                UInt32(mapping.extent.width),
                UInt32(mapping.extent.height)
            )
            if let logicalPage = mapping.logicalPage {
                uniforms.logicalPage = SIMD2(
                    Int32(logicalPage.x),
                    Int32(logicalPage.y)
                )
            }
            if mapping.masksToTargetOrbit {
                uniforms.flags |= PatternDocumentPaintFlagRadialTargetMask
            }
            set(
                uniforms,
                reduction: reduction,
                reductionOffset: index * 8,
                encoder: encoder
            )
            encoder.setTexture(
                source.texture,
                index: Int(PatternTextureIndexDocumentPaintBase)
            )
            encoder.setTexture(
                destination.texture,
                index: Int(PatternTextureIndexDocumentPaintDestination)
            )
            if var targetRadial {
                encoder.setBytes(
                    &targetRadial,
                    length: MemoryLayout<PatternRadialFrameUniforms>.stride,
                    index: Int(PatternBufferIndexRadialFrameUniforms)
                )
            }
            dispatch(encoder)
            evidence.append(EvidenceMetadata(
                coordinate: destination.coordinate,
                logicalBounds: destination.logicalBounds,
                reductionOffset: index * 8
            ))
            retained.append(source.texture)
            retained.append(destination.texture)
        }
        return (evidence, retained)
    }

    private func encodeImport(
        _ payload: DocumentPaintSurfaceEncodedImportBackendPayload,
        encoder: any MTLComputeCommandEncoder,
        reduction: any MTLBuffer,
        importSource: any MTLBuffer
    ) -> (
        evidence: [EvidenceMetadata],
        retainedTextures: [any MTLTexture]
    ) {
        encoder.setComputePipelineState(pipelines.encodedImport)
        var evidence: [EvidenceMetadata] = []
        var retained: [any MTLTexture] = []
        evidence.reserveCapacity(payload.destinations.count)
        retained.reserveCapacity(payload.destinations.count)
        for index in payload.destinations.indices {
            let region = payload.tileRegions[index]
            let destination = payload.destinations[index]
            var uniforms = Self.uniforms(for: destination)
            uniforms.sourceBytesPerRow = UInt32(payload.bytesPerRow)
            uniforms.sourceByteOffset = UInt32(region.sourceByteOffset)
            set(
                uniforms,
                reduction: reduction,
                reductionOffset: index * 8,
                encoder: encoder
            )
            encoder.setBuffer(
                importSource,
                offset: 0,
                index: Int(PatternBufferIndexDocumentPaintMutationSourceBytes)
            )
            encoder.setTexture(
                destination.texture,
                index: Int(PatternTextureIndexDocumentPaintDestination)
            )
            dispatch(encoder)
            evidence.append(EvidenceMetadata(
                coordinate: destination.coordinate,
                logicalBounds: destination.logicalBounds,
                reductionOffset: index * 8
            ))
            retained.append(destination.texture)
        }
        return (evidence, retained)
    }

    private func validateStroke(
        _ payload: DocumentPaintSurfaceStrokeBackendPayload
    ) throws {
        guard payload.compositeParameters.isValid,
              !payload.destinations.isEmpty,
              payload.baseSources.count == payload.destinations.count,
              payload.authoritativeSources.count == payload.destinations.count
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        let coordinates = payload.destinations.map(\.coordinate)
        guard coordinates == coordinates.sorted(),
              Set(coordinates).count == coordinates.count,
              payload.baseSources.map(\.coordinate) == coordinates,
              payload.authoritativeSources.map(\.coordinate) == coordinates
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        try validateDestinations(
            payload.destinations,
            geometry: payload.geometry
        )
        for source in payload.baseSources + payload.authoritativeSources {
            try validate(source: source, geometry: payload.geometry)
        }
        try validateNoAliases(
            read: (payload.baseSources + payload.authoritativeSources)
                .compactMap(Self.texture(from:)),
            write: payload.destinations.map(\.texture)
        )
    }

    private func validateResize(
        _ payload: DocumentPaintSurfaceResizeBackendPayload
    ) throws {
        guard payload.clearsDestinationsBeforeCopy,
              payload.sources.count == payload.mappings.count,
              payload.destinations.count == payload.mappings.count
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        _ = try Self.radialUniforms(for: payload)
        let sourceCoordinates = payload.sources.map(\.coordinate)
        let destinationCoordinates = payload.destinations.map(\.coordinate)
        guard sourceCoordinates == sourceCoordinates.sorted(),
              Set(sourceCoordinates).count == sourceCoordinates.count,
              destinationCoordinates == destinationCoordinates.sorted(),
              Set(destinationCoordinates).count
                == destinationCoordinates.count,
              payload.mappings.map(\.sourceCoordinate).sorted()
                == sourceCoordinates,
              payload.mappings.map(\.destinationCoordinate).sorted()
                == destinationCoordinates
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        try validateSources(payload.sources, geometry: payload.sourceGeometry)
        try validateDestinations(
            payload.destinations,
            geometry: payload.candidateGeometry
        )
        let sources = Dictionary(
            uniqueKeysWithValues: payload.sources.map { ($0.coordinate, $0) }
        )
        let destinations = Dictionary(
            uniqueKeysWithValues: payload.destinations.map {
                ($0.coordinate, $0)
            }
        )
        for mapping in payload.mappings {
            guard let source = sources[mapping.sourceCoordinate],
                  let destination = destinations[mapping.destinationCoordinate],
                  mapping.logicalPage.map({
                    Int32(exactly: $0.x) != nil
                        && Int32(exactly: $0.y) != nil
                  }) ?? true,
                  Self.regionFits(
                    origin: mapping.sourceOrigin,
                    extent: mapping.extent,
                    width: source.logicalBounds.width,
                    height: source.logicalBounds.height
                  ),
                  Self.regionFits(
                    origin: mapping.destinationOrigin,
                    extent: mapping.extent,
                    width: destination.logicalBounds.width,
                    height: destination.logicalBounds.height
                  )
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
        }
        try validateNoAliases(
            read: payload.sources.map(\.texture),
            write: payload.destinations.map(\.texture)
        )
    }

    private func validateEncodedImport(
        _ payload: DocumentPaintSurfaceEncodedImportBackendPayload
    ) throws {
        let (minimumBytesPerRow, rowByteOverflow) = payload.width
            .multipliedReportingOverflow(by: 4)
        guard !rowByteOverflow,
              payload.candidateGeometry.radialLayout == nil,
              payload.conversion
                == .encodedPremultipliedSRGBBGRA8ToLinearPremultipliedRGBA16Float,
              payload.clearsDestinationsBeforeConversion,
              payload.width == payload.candidateGeometry.documentPixelSize.width,
              payload.height == payload.candidateGeometry.documentPixelSize.height,
              payload.bytesPerRow >= minimumBytesPerRow,
              payload.destinations.count == payload.tileRegions.count
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        let (requiredBytes, overflow) = payload.bytesPerRow
            .multipliedReportingOverflow(by: payload.height)
        let coordinates = payload.destinations.map(\.coordinate)
        guard !overflow,
              payload.encodedPremultipliedBGRA8.count >= requiredBytes,
              coordinates == coordinates.sorted(),
              Set(coordinates).count == coordinates.count,
              coordinates == payload.tileRegions.map(\.coordinate)
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        if payload.destinations.isEmpty,
           Self.encodedImportContainsNonzeroAlpha(payload)
        {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        try validateDestinations(
            payload.destinations,
            geometry: payload.candidateGeometry
        )
        for (destination, region) in zip(
            payload.destinations,
            payload.tileRegions
        ) {
            guard region.destinationOrigin == .zero,
                  region.extent.width == destination.logicalBounds.width,
                  region.extent.height == destination.logicalBounds.height,
                  Self.regionFits(
                    origin: region.sourceOrigin,
                    extent: region.extent,
                    width: payload.width,
                    height: payload.height
                  ),
                  let expectedOffset = Self.sourceByteOffset(
                    origin: region.sourceOrigin,
                    bytesPerRow: payload.bytesPerRow
                  ),
                  region.sourceByteOffset == expectedOffset,
                  UInt32(exactly: region.sourceByteOffset) != nil,
                  UInt32(exactly: payload.bytesPerRow) != nil
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
        }
    }

    private func validateRestore(
        _ payload: DocumentPaintSurfaceRestoreBackendPayload
    ) throws {
        let coordinates = payload.destinations.map(\.coordinate)
        guard coordinates == coordinates.sorted(),
              Set(coordinates).count == coordinates.count
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        var textureIDs: Set<ObjectIdentifier> = []
        for destination in payload.destinations {
            let (expectedMinX, xOverflow) = destination.coordinate.x
                .multipliedReportingOverflow(by: PaintTileDescriptor.side)
            let (expectedMinY, yOverflow) = destination.coordinate.y
                .multipliedReportingOverflow(by: PaintTileDescriptor.side)
            guard destination.coordinate.x >= 0,
                  destination.coordinate.y >= 0,
                  !xOverflow,
                  !yOverflow,
                  destination.logicalBounds.minX == expectedMinX,
                  destination.logicalBounds.minY == expectedMinY,
                  (1...PaintTileDescriptor.side).contains(
                    destination.logicalBounds.width
                  ),
                  (1...PaintTileDescriptor.side).contains(
                    destination.logicalBounds.height
                  )
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
            guard Self.sameDevice(device, destination.texture.device) else {
                throw DocumentPaintSurfaceMetalBackendError
                    .resourceDeviceMismatch
            }
            guard destination.texture.pixelFormat
                    == PaintTileDescriptor.pixelFormat,
                  destination.texture.width == PaintTileDescriptor.side,
                  destination.texture.height == PaintTileDescriptor.side,
                  destination.texture.usage.contains(.shaderWrite)
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidTexture
            }
            guard textureIDs.insert(ObjectIdentifier(
                destination.texture as AnyObject
            )).inserted else {
                throw DocumentPaintSurfaceMetalBackendError.textureAlias
            }
        }
    }

    private func validateSources(
        _ sources: [DocumentPaintSurfaceMutationSource],
        geometry: DocumentPaintGeometry
    ) throws {
        for source in sources {
            try validate(
                coordinate: source.coordinate,
                logicalBounds: source.logicalBounds,
                texture: source.texture,
                geometry: geometry,
                requiresWrite: false
            )
        }
    }

    private func validateDestinations(
        _ destinations: [DocumentPaintSurfaceMutationDestination],
        geometry: DocumentPaintGeometry
    ) throws {
        for destination in destinations {
            try validate(
                coordinate: destination.coordinate,
                logicalBounds: destination.logicalBounds,
                texture: destination.texture,
                geometry: geometry,
                requiresWrite: true
            )
        }
    }

    private func validate(
        source: DocumentPaintSurfaceReadSource,
        geometry: DocumentPaintGeometry
    ) throws {
        let descriptor = try Self.descriptor(
            coordinate: source.coordinate,
            geometry: geometry
        )
        guard source.logicalBounds == descriptor.logicalBounds else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        if case let .texture(source) = source {
            try validate(
                coordinate: source.coordinate,
                logicalBounds: source.logicalBounds,
                texture: source.texture,
                geometry: geometry,
                requiresWrite: false
            )
        }
    }

    private func validate(
        coordinate: PaintTileCoordinate,
        logicalBounds: PixelRect,
        texture: any MTLTexture,
        geometry: DocumentPaintGeometry,
        requiresWrite: Bool
    ) throws {
        let descriptor = try Self.descriptor(
            coordinate: coordinate,
            geometry: geometry
        )
        guard descriptor.logicalBounds == logicalBounds else {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
        guard Self.sameDevice(device, texture.device) else {
            throw DocumentPaintSurfaceMetalBackendError
                .resourceDeviceMismatch
        }
        let requiredUsage: MTLTextureUsage = requiresWrite
            ? .shaderWrite
            : .shaderRead
        guard texture.pixelFormat == PaintTileDescriptor.pixelFormat,
              texture.width == PaintTileDescriptor.side,
              texture.height == PaintTileDescriptor.side,
              texture.usage.contains(requiredUsage)
        else {
            throw DocumentPaintSurfaceMetalBackendError.invalidTexture
        }
    }

    private func validateNoAliases(
        read: [any MTLTexture],
        write: [any MTLTexture]
    ) throws {
        var readIDs: Set<ObjectIdentifier> = []
        for texture in read {
            guard readIDs.insert(ObjectIdentifier(texture as AnyObject))
                .inserted
            else {
                throw DocumentPaintSurfaceMetalBackendError.textureAlias
            }
        }
        var writeIDs: Set<ObjectIdentifier> = []
        for texture in write {
            let id = ObjectIdentifier(texture as AnyObject)
            guard writeIDs.insert(id).inserted, !readIDs.contains(id) else {
                throw DocumentPaintSurfaceMetalBackendError.textureAlias
            }
        }
    }

    private func actualOutcome(
        for record: ActiveEncoding
    ) throws -> RasterRevisionOperationOutcome {
        guard let commandBuffer = record.commandBuffer else {
            return .succeeded
        }
        switch commandBuffer.status {
        case .completed:
            return .succeeded
        case .error:
            return .failed
        default:
            throw DocumentPaintSurfaceMetalBackendError.commandNotTerminal(
                Int(commandBuffer.status.rawValue)
            )
        }
    }

    private static func evidence(
        from record: ActiveEncoding
    ) -> [DocumentPaintSurfaceMutationEvidence] {
        guard let buffer = record.resources.reduction else { return [] }
        return record.evidence.map { metadata in
            let reduction = buffer.contents()
                .advanced(by: metadata.reductionOffset)
                .load(as: PatternDocumentPaintMutationReduction.self)
            return DocumentPaintSurfaceMutationEvidence(
                coordinate: metadata.coordinate,
                logicalBounds: metadata.logicalBounds,
                maximumAlpha: Float(bitPattern: reduction.maximumAlphaBits),
                invalid: reduction.invalid != 0
            )
        }
    }

    private func activeRecord(
        for encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) throws -> ActiveEncoding {
        guard encoding.ownerIdentity == identity else {
            throw DocumentPaintSurfaceMetalBackendError.foreignToken
        }
        guard let record = active[encoding] else {
            throw DocumentPaintSurfaceMetalBackendError.tokenAlreadyConsumed
        }
        return record
    }

    private func register(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding,
        record: ActiveEncoding
    ) {
        withLock {
            active[encoding] = record
        }
    }

    private func consume(
        _ encoding: DocumentPaintSurfaceMutationBackendEncoding
    ) {
        active.removeValue(forKey: encoding)
    }

    private func makeToken() throws
        -> DocumentPaintSurfaceMutationBackendEncoding
    {
        try withLock {
            guard nextSequence < UInt64.max else {
                throw DocumentPaintSurfaceMetalBackendError
                    .tokenSequenceOverflow
            }
            let token = DocumentPaintSurfaceMutationBackendEncoding(
                ownerIdentity: identity,
                sequence: nextSequence
            )
            nextSequence += 1
            return token
        }
    }

    private func makeTerminalEncoding() throws
        -> DocumentPaintSurfaceMutationBackendEncoding
    {
        let token = try makeToken()
        register(
            token,
            record: ActiveEncoding(
                commandBuffer: nil,
                evidence: [],
                resources: RetainedResources(
                    textures: [],
                    reduction: nil,
                    importSource: nil
                ),
                injectsGPUFailure: false
            )
        )
        return token
    }

    private func increment(_ body: (inout Counters) -> Void) {
        withLock { body(&counters) }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private static func destinations(
        for operation: DocumentPaintSurfaceBackendOperation
    ) -> [DocumentPaintSurfaceMutationDestination] {
        switch operation {
        case .clear, .restore:
            return []
        case let .stroke(payload):
            return payload.destinations
        case let .resize(payload):
            return payload.destinations
        case let .encodedImport(payload):
            return payload.destinations
        }
    }

    private static func texture(
        from source: DocumentPaintSurfaceReadSource
    ) -> (any MTLTexture)? {
        guard case let .texture(source) = source else { return nil }
        return source.texture
    }

    private static func descriptor(
        coordinate: PaintTileCoordinate,
        geometry: DocumentPaintGeometry
    ) throws -> PaintTileDescriptor {
        do {
            return try PaintTileDescriptor(
                coordinate: coordinate,
                logicalPixelSize: geometry.storagePixelSize
            )
        } catch {
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
    }

    private static func regionFits(
        origin: SIMD2<Int>,
        extent: PixelSize,
        width: Int,
        height: Int
    ) -> Bool {
        guard origin.x >= 0, origin.y >= 0,
              extent.width > 0, extent.height > 0
        else { return false }
        let (maximumX, xOverflow) = origin.x.addingReportingOverflow(
            extent.width
        )
        let (maximumY, yOverflow) = origin.y.addingReportingOverflow(
            extent.height
        )
        return !xOverflow && !yOverflow
            && maximumX <= width && maximumY <= height
    }

    private static func sourceByteOffset(
        origin: SIMD2<Int>,
        bytesPerRow: Int
    ) -> Int? {
        guard origin.x >= 0, origin.y >= 0, bytesPerRow >= 0 else {
            return nil
        }
        let (rowOffset, rowOverflow) = origin.y
            .multipliedReportingOverflow(by: bytesPerRow)
        let (columnOffset, columnOverflow) = origin.x
            .multipliedReportingOverflow(by: 4)
        let (offset, additionOverflow) = rowOffset
            .addingReportingOverflow(columnOffset)
        guard !rowOverflow, !columnOverflow, !additionOverflow else {
            return nil
        }
        return offset
    }

    private static func encodedImportContainsNonzeroAlpha(
        _ payload: DocumentPaintSurfaceEncodedImportBackendPayload
    ) -> Bool {
        payload.encodedPremultipliedBGRA8.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for y in 0..<payload.height {
                var alphaOffset = y * payload.bytesPerRow + 3
                for _ in 0..<payload.width {
                    if bytes[alphaOffset] != 0 { return true }
                    alphaOffset += 4
                }
            }
            return false
        }
    }

    private static func radialUniforms(
        for payload: DocumentPaintSurfaceResizeBackendPayload
    ) throws -> PatternRadialFrameUniforms? {
        switch (
            payload.candidateGeometry.radialLayout,
            payload.targetRadialConfiguration
        ) {
        case (nil, nil):
            guard payload.mappings.isEmpty
                || (payload.sourceGeometry.radialLayout == nil
                  && payload.mappings.allSatisfy({
                    $0.logicalPage == nil && !$0.masksToTargetOrbit
                  }))
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
            return nil
        case let (layout?, configuration?):
            guard payload.mappings.isEmpty
                || (payload.sourceGeometry.radialLayout != nil
                  && payload.mappings.allSatisfy({
                    $0.logicalPage != nil && $0.masksToTargetOrbit
                  }))
            else {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
            let compiled: CompiledRadialDomain
            do {
                let symmetry = try SymmetryDescriptorCompiler.compile(
                    finiteConfiguration: .radial(configuration),
                    canvasSize: payload.candidateGeometry.documentPixelSize
                )
                guard let radial = symmetry.domain.finite?.radial,
                      radial.layout == layout,
                      let normalized = radial.configuration,
                      let displayedSectorCount = UInt32(exactly:
                        radial.displayedSectorCount),
                      let atlasColumns = UInt32(exactly:
                        layout.atlasColumns)
                else {
                    throw DocumentPaintSurfaceMetalBackendError
                        .invalidOperation
                }
                compiled = radial
                let isDihedral = normalized.kind != .rotation
                return PatternRadialFrameUniforms(
                    canvasSize: SIMD2(
                        Float(compiled.canvasSize.width),
                        Float(compiled.canvasSize.height)
                    ),
                    center: normalized.center.simd,
                    referenceAngle: normalized.referenceAngleRadians,
                    sectorAngle: compiled.sectorAngleRadians,
                    displayedSectorCount: displayedSectorCount,
                    dihedral: isDihedral ? 1 : 0,
                    pageOrigin: SIMD2(
                        Float(layout.pageOrigin.x),
                        Float(layout.pageOrigin.y)
                    ),
                    pageTableSize: SIMD2(
                        Float(layout.pageTableSize.width),
                        Float(layout.pageTableSize.height)
                    ),
                    atlasColumns: atlasColumns,
                    pageSide: UInt32(RadialSectorLayout.pageSide),
                    atlasSize: SIMD2(
                        Float(layout.atlasPixelSize.width),
                        Float(layout.atlasPixelSize.height)
                    )
                )
            } catch let error as DocumentPaintSurfaceMetalBackendError {
                throw error
            } catch {
                throw DocumentPaintSurfaceMetalBackendError.invalidOperation
            }
        default:
            throw DocumentPaintSurfaceMetalBackendError.invalidOperation
        }
    }

    private static func uniforms(
        for destination: DocumentPaintSurfaceMutationDestination,
        composite: DocumentPaintStrokeCompositeParameters? = nil
    ) -> PatternDocumentPaintMutationUniforms {
        var uniforms = PatternDocumentPaintMutationUniforms()
        uniforms.logicalExtent = SIMD2(
            UInt32(destination.logicalBounds.width),
            UInt32(destination.logicalBounds.height)
        )
        uniforms.copyExtent = uniforms.logicalExtent
        if let composite {
            uniforms.parameters = SIMD4(
                composite.strokeOpacity,
                composite.accumulationLimit,
                composite.eraserStrength,
                0
            )
            uniforms.compositeMode = composite.mode.rawValue
        }
        return uniforms
    }

    private func set(
        _ value: PatternDocumentPaintMutationUniforms,
        reduction: any MTLBuffer,
        reductionOffset: Int,
        encoder: any MTLComputeCommandEncoder
    ) {
        var value = value
        encoder.setBytes(
            &value,
            length: MemoryLayout<PatternDocumentPaintMutationUniforms>.stride,
            index: Int(PatternBufferIndexDocumentPaintMutationUniforms)
        )
        encoder.setBuffer(
            reduction,
            offset: reductionOffset,
            index: Int(PatternBufferIndexDocumentPaintMutationReduction)
        )
    }

    private func dispatch(_ encoder: any MTLComputeCommandEncoder) {
        encoder.dispatchThreads(
            MTLSize(
                width: PaintTileDescriptor.side,
                height: PaintTileDescriptor.side,
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
    }

    private static func sameDevice(
        _ lhs: any MTLDevice,
        _ rhs: any MTLDevice
    ) -> Bool {
        ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }
}
