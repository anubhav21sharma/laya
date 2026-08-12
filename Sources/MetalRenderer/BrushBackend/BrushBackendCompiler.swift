import PatternEngine

public enum BrushBackendCompilationError: Error, Equatable, Sendable {
    case registry(BrushBackendRegistryError)
    case retiredNativeIdentifier(String)
    case unsupportedRequiredSemantic(String)
    case unsupportedInteraction(BrushInteractionMode)
    case unsupportedEdgeTreatment(BrushEdgeTreatment)
    case missingDeclaredCapability(BrushBackendCapabilities)
    case missingImplementedCapability(BrushBackendCapabilities)
    case backendUnavailable(
        kind: BrushBackendKind,
        encoderFamily: BrushBackendEncoderFamily
    )
}

public struct BrushBackendCompiler: Sendable {
    public let registry: BrushBackendRegistry

    public init(registry: BrushBackendRegistry) {
        self.registry = registry
    }

    public func compile(
        program: BrushProgram,
        forActivation: Bool
    ) throws -> CompiledBrushBackendContract {
        let registration: BrushBackendRegistration
        do {
            registration = try registry.registration(
                for: program.requestedBackend,
                schemaVersion: program.definition.schemaVersion
            )
        } catch let error as BrushBackendRegistryError {
            throw BrushBackendCompilationError.registry(error)
        }

        let definition = program.definition
        if Self.retiredNativeIdentifiers.contains(definition.id.rawValue) {
            throw BrushBackendCompilationError.retiredNativeIdentifier(
                definition.id.rawValue
            )
        }
        if let semantic = definition.compatibility.requiredSemanticKeys.first {
            throw BrushBackendCompilationError.unsupportedRequiredSemantic(
                semantic
            )
        }

        if program.requestedBackend == .deposition {
            for component in definition.components {
                guard component.material.interaction == .none else {
                    throw BrushBackendCompilationError.unsupportedInteraction(
                        component.material.interaction
                    )
                }
                guard component.material.edgeTreatment != .wetConcentration
                else {
                    throw BrushBackendCompilationError
                        .unsupportedEdgeTreatment(
                            component.material.edgeTreatment
                        )
                }
            }
        }

        if definition.components.contains(where: {
            Self.secondaryColorMixMayBeNonzero($0)
        }) {
            let capability = BrushBackendCapabilities.secondaryColorSource
            guard registration.declaredCapabilities.contains(capability),
                  registration.implementedCapabilities.contains(capability)
            else {
                throw BrushBackendCompilationError
                    .missingImplementedCapability(capability)
            }
        }

        let contract: CompiledBrushBackendContract
        switch program.requestedBackend {
        case .deposition:
            contract = .deposition(
                CompiledDepositionBackendContract(
                    registration: registration
                )
            )
        case .canvasInteraction:
            let required = BrushBackendCapabilities.destinationSampling
            guard registration.declaredCapabilities.contains(required) else {
                throw BrushBackendCompilationError
                    .missingDeclaredCapability(required)
            }
            contract = .canvasInteraction(
                CompiledCanvasInteractionBackendContract(
                    registration: registration
                )
            )
        }

        if forActivation, registration.activation != .available {
            throw BrushBackendCompilationError.backendUnavailable(
                kind: program.requestedBackend,
                encoderFamily: registration.encoderFamily
            )
        }
        return contract
    }

    private static let retiredNativeIdentifiers: Set<String> = [
        "builtin.bounded-wash",
    ]

    private struct Interval {
        let lower: Double
        let upper: Double
    }

    private static func secondaryColorMixMayBeNonzero(
        _ component: BrushComponentDefinition
    ) -> Bool {
        guard let output = component.sensorProgram.outputs[
            .secondaryColorMix
        ] else {
            return true
        }
        var interval = Interval(
            lower: Double(output.baseValue),
            upper: Double(output.baseValue)
        )
        for term in output.terms {
            let termInterval = Interval(
                lower: Double(term.responseLowerClamp),
                upper: Double(term.responseUpperClamp)
            )
            interval = applying(
                term.operation,
                accumulator: interval,
                term: termInterval
            )
        }
        let contractedUpper = min(1, max(0, interval.upper))
        let jitterUpper = Double(
            component.color.perStampJitter.secondaryColorMix
                + component.color.perStrokeJitter.secondaryColorMix
        )
        return contractedUpper + jitterUpper > 0
    }

    private static func applying(
        _ operation: BrushResponseOperation,
        accumulator: Interval,
        term: Interval
    ) -> Interval {
        switch operation {
        case .replace:
            return term
        case .add:
            return Interval(
                lower: accumulator.lower + term.lower,
                upper: accumulator.upper + term.upper
            )
        case .multiply:
            let products = (
                accumulator.lower * term.lower,
                accumulator.lower * term.upper,
                accumulator.upper * term.lower,
                accumulator.upper * term.upper
            )
            return Interval(
                lower: min(
                    products.0,
                    products.1,
                    products.2,
                    products.3
                ),
                upper: max(
                    products.0,
                    products.1,
                    products.2,
                    products.3
                )
            )
        case .minimum:
            return Interval(
                lower: min(accumulator.lower, term.lower),
                upper: min(accumulator.upper, term.upper)
            )
        case .maximum:
            return Interval(
                lower: max(accumulator.lower, term.lower),
                upper: max(accumulator.upper, term.upper)
            )
        }
    }
}
