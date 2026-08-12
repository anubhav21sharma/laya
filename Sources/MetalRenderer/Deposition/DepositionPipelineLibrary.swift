import CShaderTypes
import Metal
import PatternEngine

public struct DepositionPipelineKey: Hashable, Sendable {
    public let brush: BrushPipelineKey
    public let abiVersion: UInt16
    public let colorPixelFormatRawValue: UInt
    public let sampleCount: Int

    public init(
        brush: BrushPipelineKey,
        abiVersion: UInt16,
        colorPixelFormatRawValue: UInt,
        sampleCount: Int
    ) {
        self.brush = brush
        self.abiVersion = abiVersion
        self.colorPixelFormatRawValue = colorPixelFormatRawValue
        self.sampleCount = sampleCount
    }
}

public enum DepositionPipelineLibraryError: Error, Equatable, Sendable {
    case unsupportedABI(UInt16)
    case unsupportedBackend(BrushBackendKind)
    case unsupportedEdgeTreatment(BrushEdgeTreatment)
    case invalidPixelFormat(UInt)
    case invalidSampleCount(Int)
    case shaderLibraryUnavailable
    case shaderFunctionUnavailable(String)
    case pipelineCreationFailed(String)
    case notPrepared(DepositionPipelineKey)
}

@MainActor
public final class DepositionPipelineBinding {
    public let key: DepositionPipelineKey
    public let state: any MTLRenderPipelineState

    package init(
        key: DepositionPipelineKey,
        state: any MTLRenderPipelineState
    ) {
        self.key = key
        self.state = state
    }
}

@MainActor
package protocol DepositionPipelinePreparing: AnyObject {
    func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding
}

@MainActor
public final class DepositionPipelineLibrary: DepositionPipelinePreparing {
    var debugPreparedPipelineCount: Int {
        prepared.count
    }
    package private(set) var debugPrepareCallCount = 0

    private let device: any MTLDevice
    private let library: (any MTLLibrary)?
    private var prepared: [DepositionPipelineKey: DepositionPipelineBinding]
    private var inFlight:
        [DepositionPipelineKey: Task<DepositionPipelineBinding, Error>]

    public convenience init(device: any MTLDevice) {
        self.init(device: device, library: device.makeDefaultLibrary())
    }

    public init(
        device: any MTLDevice,
        library: (any MTLLibrary)?
    ) {
        self.device = device
        self.library = library
        prepared = [:]
        inFlight = [:]
    }

    public func prepare(
        for key: DepositionPipelineKey
    ) async throws -> DepositionPipelineBinding {
        try validate(key)
        debugPrepareCallCount += 1
        if let binding = prepared[key] {
            return binding
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task { @MainActor [self] in
            do {
                let state = try await makePipelineState(for: key)
                let candidate = DepositionPipelineBinding(
                    key: key,
                    state: state
                )
                let binding = prepared[key] ?? candidate
                prepared[key] = binding
                inFlight[key] = nil
                return binding
            } catch {
                inFlight[key] = nil
                throw error
            }
        }
        inFlight[key] = task
        return try await task.value
    }

    public func preparedBinding(
        for key: DepositionPipelineKey
    ) throws -> DepositionPipelineBinding {
        guard let binding = prepared[key] else {
            throw DepositionPipelineLibraryError.notPrepared(key)
        }
        return binding
    }

    func prepareImmediately(
        for key: DepositionPipelineKey
    ) throws -> DepositionPipelineBinding {
        try validate(key)
        if let binding = prepared[key] {
            return binding
        }
        let binding = DepositionPipelineBinding(
            key: key,
            state: try makePipelineStateImmediately(for: key)
        )
        prepared[key] = binding
        return binding
    }

    private func makePipelineState(
        for key: DepositionPipelineKey
    ) async throws -> any MTLRenderPipelineState {
        let descriptor = try makePipelineDescriptor(for: key)
        return try await withCheckedThrowingContinuation { continuation in
            device.makeRenderPipelineState(descriptor: descriptor) {
                state,
                error in
                if let state {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(
                        throwing:
                            DepositionPipelineLibraryError
                            .pipelineCreationFailed(
                                error?.localizedDescription
                                    ?? "Metal returned no pipeline state."
                            )
                    )
                }
            }
        }
    }

    private func makePipelineStateImmediately(
        for key: DepositionPipelineKey
    ) throws -> any MTLRenderPipelineState {
        do {
            return try device.makeRenderPipelineState(
                descriptor: makePipelineDescriptor(for: key)
            )
        } catch {
            throw DepositionPipelineLibraryError.pipelineCreationFailed(
                error.localizedDescription
            )
        }
    }

    private func makePipelineDescriptor(
        for key: DepositionPipelineKey
    ) throws -> MTLRenderPipelineDescriptor {
        try validate(key)
        guard let library else {
            throw DepositionPipelineLibraryError.shaderLibraryUnavailable
        }

        let vertex: any MTLFunction
        let fragment: any MTLFunction
        do {
            vertex = try makeSpecializedFunction(
                library: library,
                name: "patternProjectedDepositionVertex",
                key: key.brush
            )
            fragment = try makeSpecializedFunction(
                library: library,
                name: "patternDepositionFragment",
                key: key.brush
            )
        } catch {
            throw DepositionPipelineLibraryError.pipelineCreationFailed(
                error.localizedDescription
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Specialized Brush Deposition"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.rasterSampleCount = key.sampleCount
        guard let attachment = descriptor.colorAttachments[0] else {
            throw DepositionPipelineLibraryError.pipelineCreationFailed(
                "Metal did not provide color attachment zero."
            )
        }
        attachment.pixelFormat = DocumentColorPipeline.workingPixelFormat
        configureBlend(attachment, accumulation: key.brush.accumulation)
        guard let componentCoverage = descriptor.colorAttachments[1] else {
            throw DepositionPipelineLibraryError.pipelineCreationFailed(
                "Metal did not provide component-coverage attachment one."
            )
        }
        componentCoverage.pixelFormat = DepositionComponentCoverage.pixelFormat
        componentCoverage.isBlendingEnabled = false
        return descriptor
    }

    private func validate(_ key: DepositionPipelineKey) throws {
        guard key.abiVersion == DepositionABI.version else {
            throw DepositionPipelineLibraryError.unsupportedABI(
                key.abiVersion
            )
        }
        guard key.brush.backend == .deposition else {
            throw DepositionPipelineLibraryError.unsupportedBackend(
                key.brush.backend
            )
        }
        guard key.sampleCount > 0 else {
            throw DepositionPipelineLibraryError.invalidSampleCount(
                key.sampleCount
            )
        }
        guard key.colorPixelFormatRawValue
                == DocumentColorPipeline.workingPixelFormat.rawValue
        else {
            throw DepositionPipelineLibraryError.invalidPixelFormat(
                key.colorPixelFormatRawValue
            )
        }
    }

    private func makeSpecializedFunction(
        library: any MTLLibrary,
        name: String,
        key: BrushPipelineKey
    ) throws -> any MTLFunction {
        try library.makeFunction(
            name: name,
            constantValues: functionConstants(for: key)
        )
    }

    private func functionConstants(
        for key: BrushPipelineKey
    ) throws -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var secondaryShape = key.functionConstants.usesSecondaryShape
        var primaryGrain = key.functionConstants.usesGrain
        var secondaryGrain = key.functionConstants.usesSecondaryGrain
        var accumulation = accumulationWire(key.accumulation)
        guard var edge = Self.supportedEdgeWires[key.edgeTreatment] else {
            throw DepositionPipelineLibraryError.unsupportedEdgeTreatment(
                key.edgeTreatment
            )
        }
        values.setConstantValue(
            &secondaryShape,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryShape)
        )
        values.setConstantValue(
            &primaryGrain,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantPrimaryGrain)
        )
        values.setConstantValue(
            &secondaryGrain,
            type: .bool,
            index: Int(PatternDepositionFunctionConstantSecondaryGrain)
        )
        values.setConstantValue(
            &accumulation,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantAccumulation)
        )
        values.setConstantValue(
            &edge,
            type: .uint,
            index: Int(PatternDepositionFunctionConstantEdgeTreatment)
        )
        return values
    }

    private func accumulationWire(
        _ mode: BrushAccumulationMode
    ) -> UInt32 {
        switch mode {
        case .opaque:
            PatternDepositionAccumulationOpaque
        case .flow:
            PatternDepositionAccumulationFlow
        case .uniformGlaze:
            PatternDepositionAccumulationUniformGlaze
        case .intenseGlaze:
            PatternDepositionAccumulationIntenseGlaze
        case .destinationOut:
            PatternDepositionAccumulationDestinationOut
        }
    }

    private static let supportedEdgeWires: [BrushEdgeTreatment: UInt32] = [
        .none: PatternDepositionEdgeNone,
        .dryBreakup: PatternDepositionEdgeDryBreakup,
        .markerOverlap: PatternDepositionEdgeMarkerOverlap,
    ]

    private func configureBlend(
        _ attachment: MTLRenderPipelineColorAttachmentDescriptor,
        accumulation: BrushAccumulationMode
    ) {
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        if accumulation == .uniformGlaze {
            attachment.rgbBlendOperation = .max
            attachment.alphaBlendOperation = .max
            attachment.destinationRGBBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }
    }
}
