import Foundation

public struct BrushSensorNormalizationDefinition:
    Codable, Equatable, Sendable
{
    public let fullScaleWorldVelocity: Float
    public let minimumVelocityDeltaTime: TimeInterval
    public let fullScaleStrokeAge: TimeInterval
    public let fullScaleStrokeDistanceInDiameters: Float

    public init(
        fullScaleWorldVelocity: Float,
        minimumVelocityDeltaTime: TimeInterval,
        fullScaleStrokeAge: TimeInterval,
        fullScaleStrokeDistanceInDiameters: Float
    ) {
        self.fullScaleWorldVelocity = fullScaleWorldVelocity
        self.minimumVelocityDeltaTime = minimumVelocityDeltaTime
        self.fullScaleStrokeAge = fullScaleStrokeAge
        self.fullScaleStrokeDistanceInDiameters =
            fullScaleStrokeDistanceInDiameters
    }
}

public enum BrushDynamicOutput:
    String, CaseIterable, Codable, Hashable, Sendable
{
    case size, flow, opacity, spacing, rotation, scatter, hardness, grain
    case offsetX, offsetY, hue, saturation, brightness, secondaryColorMix

    /// Stable serialized/random namespace. Never derive this from collection
    /// order: term randomness reserves four counters for every output.
    var stageCRandomID: UInt64 {
        switch self {
        case .size: 0
        case .flow: 1
        case .opacity: 2
        case .spacing: 3
        case .rotation: 4
        case .scatter: 5
        case .hardness: 6
        case .grain: 7
        case .offsetX: 8
        case .offsetY: 9
        case .hue: 10
        case .saturation: 11
        case .brightness: 12
        case .secondaryColorMix: 13
        }
    }
}

public enum BrushResponseOperation: String, Codable, Equatable, Sendable {
    case replace, multiply, add, minimum, maximum
}

public struct BrushResponseTermDefinition: Codable, Equatable, Sendable {
    public let input: BrushDynamicsInput
    public let response: BrushResponseDefinition
    public let inputInverted: Bool
    public let missingInputValue: Float
    public let responseScale: Float
    public let responseOffset: Float
    public let responseLowerClamp: Float
    public let responseUpperClamp: Float
    public let jitter: Float
    public let operation: BrushResponseOperation

    public init(
        input: BrushDynamicsInput,
        response: BrushResponseDefinition,
        inputInverted: Bool,
        missingInputValue: Float,
        responseScale: Float,
        responseOffset: Float,
        responseLowerClamp: Float,
        responseUpperClamp: Float,
        jitter: Float,
        operation: BrushResponseOperation
    ) {
        self.input = input
        self.response = response
        self.inputInverted = inputInverted
        self.missingInputValue = missingInputValue
        self.responseScale = responseScale
        self.responseOffset = responseOffset
        self.responseLowerClamp = responseLowerClamp
        self.responseUpperClamp = responseUpperClamp
        self.jitter = jitter
        self.operation = operation
    }
}

public struct BrushOutputProgramDefinition: Codable, Equatable, Sendable {
    public let baseValue: Float
    public let terms: [BrushResponseTermDefinition]

    public init(baseValue: Float, terms: [BrushResponseTermDefinition]) {
        self.baseValue = baseValue
        self.terms = terms
    }
}

public struct BrushSensorProgramDefinition: Codable, Equatable, Sendable {
    public let outputs: [BrushDynamicOutput: BrushOutputProgramDefinition]

    public init(
        outputs: [BrushDynamicOutput: BrushOutputProgramDefinition]
    ) {
        self.outputs = outputs
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var outputs: [BrushDynamicOutput: BrushOutputProgramDefinition] = [:]
        outputs.reserveCapacity(BrushDynamicOutput.allCases.count)
        while !container.isAtEnd {
            let output = try container.decode(BrushDynamicOutput.self)
            guard outputs[output] == nil else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Duplicate sensor output"
                )
            }
            outputs[output] = try container.decode(
                BrushOutputProgramDefinition.self
            )
        }
        self.outputs = outputs
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for output in BrushDynamicOutput.allCases {
            guard let definition = outputs[output] else { continue }
            try container.encode(output)
            try container.encode(definition)
        }
    }

    /// Lifts each exact schema-2 single-mapping field into the ordered sensor
    /// program without changing its response, clamp, jitter, or missing-input
    /// behavior. Schema 3 may replace this duplicated wire shape; schema 2 has
    /// one current evaluator.
    public init(singleMappingDynamics dynamics: BrushDynamicsDefinition) {
        outputs = [
            .size: Self.output(dynamics.size, as: .size),
            .flow: Self.output(dynamics.flow, as: .flow),
            .opacity: Self.output(dynamics.opacity, as: .opacity),
            .spacing: Self.output(dynamics.spacing, as: .spacing),
            .rotation: Self.output(dynamics.rotation, as: .rotation),
            .scatter: Self.output(dynamics.scatter, as: .scatter),
            .hardness: Self.output(dynamics.hardness, as: .hardness),
            .grain: Self.output(dynamics.grain, as: .grain),
            .offsetX: Self.output(dynamics.offsetX, as: .offsetX),
            .offsetY: Self.output(dynamics.offsetY, as: .offsetY),
            .hue: Self.output(dynamics.hue, as: .hue),
            .saturation: Self.output(dynamics.saturation, as: .saturation),
            .brightness: Self.output(dynamics.brightness, as: .brightness),
            .secondaryColorMix: Self.output(
                dynamics.secondaryColorMix,
                as: .secondaryColorMix
            ),
        ]
    }

    private static func output(
        _ mapping: BrushMappingDefinition,
        as output: BrushDynamicOutput
    ) -> BrushOutputProgramDefinition {
        let baseValue: Float = switch output {
        case .size, .spacing, .grain: 1
        case .flow, .opacity, .rotation, .scatter, .hardness, .offsetX,
             .offsetY, .hue, .saturation, .brightness, .secondaryColorMix: 0
        }
        return BrushOutputProgramDefinition(
            baseValue: baseValue,
            terms: [BrushResponseTermDefinition(
                input: mapping.input,
                response: mapping.response,
                inputInverted: mapping.inverted,
                missingInputValue: mapping.missingInputValue,
                responseScale: mapping.scale,
                responseOffset: mapping.offset,
                responseLowerClamp: mapping.lowerClamp,
                responseUpperClamp: mapping.upperClamp,
                jitter: mapping.jitter,
                operation: .replace
            )]
        )
    }
}

public enum BrushStabilizationDefinition: Codable, Equatable, Sendable {
    case none
    case weightedWindow(distance: Float)
    case delayed(distance: Float)

    private enum CodingKeys: String, CodingKey { case kind, distance }
    private enum Kind: String, Codable { case none, weightedWindow, delayed }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .weightedWindow:
            self = .weightedWindow(
                distance: try container.decode(Float.self, forKey: .distance)
            )
        case .delayed:
            self = .delayed(
                distance: try container.decode(Float.self, forKey: .distance)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .weightedWindow(distance):
            try container.encode(Kind.weightedWindow, forKey: .kind)
            try container.encode(distance, forKey: .distance)
        case let .delayed(distance):
            try container.encode(Kind.delayed, forKey: .kind)
            try container.encode(distance, forKey: .distance)
        }
    }
}

public struct BrushDirectionDefinition: Codable, Equatable, Sendable {
    public let maximumAngularStep: Float
    public let stationaryDirection: Float

    public init(maximumAngularStep: Float, stationaryDirection: Float) {
        self.maximumAngularStep = maximumAngularStep
        self.stationaryDirection = stationaryDirection
    }
}

public enum BrushEmissionMode: String, Codable, Equatable, Sendable {
    case distance, time, distanceAndTime
}

public struct BrushEmissionDefinition: Codable, Equatable, Sendable {
    public let mode: BrushEmissionMode
    public let timeInterval: TimeInterval?

    public init(mode: BrushEmissionMode, timeInterval: TimeInterval?) {
        self.mode = mode
        self.timeInterval = timeInterval
    }
}

extension BrushTipSupportDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, minX, maxX, minY, maxY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .analyticEllipse:
            self = .analyticEllipse
        case .analyticRectangle:
            self = .analyticRectangle
        case .normalizedBounds:
            self = try .normalizedBounds(
                minX: container.decode(Float.self, forKey: .minX),
                maxX: container.decode(Float.self, forKey: .maxX),
                minY: container.decode(Float.self, forKey: .minY),
                maxY: container.decode(Float.self, forKey: .maxY)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if let bounds {
            try container.encode(bounds.minX, forKey: .minX)
            try container.encode(bounds.maxX, forKey: .maxX)
            try container.encode(bounds.minY, forKey: .minY)
            try container.encode(bounds.maxY, forKey: .maxY)
        }
    }
}

extension BrushTipSupportDefinition.Kind: Codable {}
